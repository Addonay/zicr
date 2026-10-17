//! Differential fuzzer: runs identical randomized call sequences through the
//! original C sokol_gfx.h (dummy backend, compiled only for this tool) and through
//! the Zig port, and fails on the first divergence in returned handles, logged
//! items, resource states, pass state or frame statistics.
//!
//! usage: sokol-gfx-diff-fuzz [--seed N] [--runs N] [--steps N]
const std = @import("std");
const gfx = @import("zicr").gpu.raw;
const c = @import("sokol_ref");

// ---------------------------------------------------------------- Zig to C conversion

/// Converts a Zig descriptor into the C struct with the same field names.
fn toC(comptime C: type, z: anytype) C {
    const Z = @TypeOf(z);
    switch (@typeInfo(C)) {
        .@"struct" => |info| {
            var res: C = std.mem.zeroes(C);
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (comptime std.mem.eql(u8, name, "logger") or std.mem.eql(u8, name, "allocator")) continue;
                if (comptime @hasField(Z, name)) {
                    @field(res, name) = toC(FieldType, @field(z, name));
                }
            }
            return res;
        },
        .array => |info| {
            var res: C = undefined;
            for (&res, z) |*dst, src| dst.* = toC(info.child, src);
            return res;
        },
        .int => return switch (@typeInfo(Z)) {
            .@"enum" => @intCast(@backingInt(z)),
            .bool => @intFromBool(z),
            else => @intCast(z),
        },
        .float, .bool => return z,
        .pointer => return if (@typeInfo(Z) == .optional) (if (z) |p| @ptrCast(@constCast(p)) else null) else @ptrCast(@constCast(z)),
        .optional => return if (z) |p| @ptrCast(@constCast(p)) else null,
        else => @compileError("unsupported conversion to " ++ @typeName(C)),
    }
}

// ---------------------------------------------------------------- log capture

const Entry = struct { level: u32, item: u32 };
const Log = struct {
    entries: [256]Entry = undefined,
    len: usize = 0,
    fn add(self: *Log, level: u32, item: u32) void {
        if (self.len < self.entries.len) {
            self.entries[self.len] = .{ .level = level, .item = item };
            self.len += 1;
        }
    }
    fn slice(self: *const Log) []const Entry {
        return self.entries[0..self.len];
    }
};
var zig_log: Log = .{};
var c_log: Log = .{};

fn zigLogger(_: ?[*:0]const u8, level: u32, item: u32, _: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    zig_log.add(level, item);
}
fn cLogger(_: [*c]const u8, level: u32, item: u32, _: [*c]const u8, _: u32, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    c_log.add(level, item);
}

// ---------------------------------------------------------------- fuzzer state

const Kind = enum { buffer, image, sampler, shader, pipeline, view };

const Fuzzer = struct {
    rng: std.Random,
    step: usize = 0,
    op: []const u8 = "",
    handles: [6][64]u32 = @splat(@splat(0)),
    num_handles: [6]usize = @splat(0),
    in_pass: bool = false,
    bytes: [4096]u8 = undefined,

    fn int(self: *Fuzzer, comptime T: type, choices: []const T) T {
        return choices[self.rng.uintLessThan(usize, choices.len)];
    }
    fn chance(self: *Fuzzer, percent: u32) bool {
        return self.rng.uintLessThan(u32, 100) < percent;
    }
    fn enumValue(self: *Fuzzer, comptime E: type, max_value: u32) E {
        return @fromBackingInt(@intCast(self.rng.uintAtMost(u32, max_value)));
    }

    fn track(self: *Fuzzer, kind: Kind, id: u32) void {
        if (id == 0) return;
        const k = @backingInt(kind);
        if (self.num_handles[k] < self.handles[k].len) {
            self.handles[k][self.num_handles[k]] = id;
            self.num_handles[k] += 1;
        } else {
            self.handles[k][self.rng.uintLessThan(usize, self.handles[k].len)] = id;
        }
    }
    /// A tracked handle (possibly stale), sometimes an invalid or bogus id.
    fn handle(self: *Fuzzer, kind: Kind) u32 {
        const k = @backingInt(kind);
        if (self.num_handles[k] == 0 or self.chance(5)) return if (self.chance(50)) 0 else 0x00ff0003;
        return self.handles[k][self.rng.uintLessThan(usize, self.num_handles[k])];
    }

    /// Like handle(), but never the invalid id (the reference asserts on view
    /// descriptors without any resource).
    fn nonzeroHandle(self: *Fuzzer, kind: Kind) u32 {
        const id = self.handle(kind);
        return if (id == 0) 0x00ff0003 else id;
    }

    fn range(self: *Fuzzer, size: usize) gfx.Range {
        return .{ .ptr = &self.bytes, .size = @min(size, self.bytes.len) };
    }

    // ------------------------------------------------------------ descriptors

    fn bufferDesc(self: *Fuzzer) gfx.BufferDesc {
        var desc: gfx.BufferDesc = .{ .size = self.int(usize, &.{ 0, 0, 4, 16, 64, 100, 256 }) };
        inline for (@typeInfo(gfx.BufferUsage).@"struct".field_names) |name| @field(desc.usage, name) = self.chance(15);
        if (self.chance(60)) desc.data = self.range(if (self.chance(85)) (if (desc.size == 0) 16 else desc.size) else 12);
        return desc;
    }

    fn imageDesc(self: *Fuzzer) gfx.ImageDesc {
        var desc: gfx.ImageDesc = .{
            .type = self.enumValue(gfx.ImageType, 4),
            .width = self.int(i32, &.{ 0, 1, 4, 16, 16, 17 }),
            .height = self.int(i32, &.{ 0, 1, 4, 16, 16, 9 }),
            .num_slices = self.int(i32, &.{ 0, 0, 1, 2, 6 }),
            .num_mipmaps = self.int(i32, &.{ 0, 0, 1, 2, 5 }),
            // PixelFormat.none reaches an unreachable branch in the reference as well
            .pixel_format = if (self.chance(40)) .default else @fromBackingInt(@intCast(self.rng.intRangeAtMost(u32, 2, 68))),
            .sample_count = self.int(i32, &.{ 0, 0, 1, 4 }),
        };
        inline for (@typeInfo(gfx.ImageUsage).@"struct".field_names) |name| @field(desc.usage, name) = self.chance(12);
        if (self.chance(50)) {
            const levels: usize = @intCast(@max(desc.num_mipmaps, 1));
            for (0..@min(levels, 16)) |i| desc.data.mip_levels[i] = self.range(self.int(usize, &.{ 64, 256, 1024, 4096, 37 }));
        }
        return desc;
    }

    fn samplerDesc(self: *Fuzzer) gfx.SamplerDesc {
        return .{
            .min_filter = self.enumValue(gfx.Filter, 2),
            .mag_filter = self.enumValue(gfx.Filter, 2),
            .mipmap_filter = self.enumValue(gfx.Filter, 2),
            .wrap_u = self.enumValue(gfx.Wrap, 4),
            .compare = self.enumValue(gfx.CompareFunc, 8),
            .max_anisotropy = self.int(u32, &.{ 0, 1, 4 }),
            .min_lod = self.int(f32, &.{ 0, 1 }),
            .max_lod = self.int(f32, &.{ 0, 1000 }),
        };
    }

    fn stage(self: *Fuzzer) gfx.ShaderStage {
        return self.enumValue(gfx.ShaderStage, 3);
    }

    fn shaderDesc(self: *Fuzzer) gfx.ShaderDesc {
        var desc: gfx.ShaderDesc = .{};
        if (self.chance(20)) desc.compute_func.source = "compute";
        if (self.chance(5)) desc.vertex_func.source = "vertex";
        for (desc.uniform_blocks[0..3]) |*ub| {
            if (!self.chance(40)) continue;
            ub.* = .{ .stage = self.stage(), .size = self.int(u32, &.{ 0, 16, 64 }) };
        }
        for (desc.views[0..4], 0..) |*view, i| {
            switch (self.rng.uintLessThan(u32, 5)) {
                0 => view.texture = .{ .stage = self.stage(), .image_type = self.enumValue(gfx.ImageType, 4), .sample_type = self.enumValue(gfx.ImageSampleType, 5), .multisampled = self.chance(10) },
                1 => view.storage_buffer = .{ .stage = self.stage(), .readonly = self.chance(50) },
                2 => view.storage_image = .{ .stage = self.stage(), .image_type = self.enumValue(gfx.ImageType, 4), .access_format = @fromBackingInt(@intCast(self.rng.intRangeAtMost(u32, 2, 30))) },
                else => {},
            }
            if (view.texture.stage != .none and self.chance(80)) {
                desc.samplers[i] = .{ .stage = view.texture.stage, .sampler_type = self.enumValue(gfx.SamplerType, 3) };
                desc.texture_sampler_pairs[i] = .{ .stage = view.texture.stage, .view_slot = @intCast(i), .sampler_slot = @intCast(i) };
                if (self.chance(10)) desc.texture_sampler_pairs[i].view_slot = self.int(u8, &.{ 0, 5, 40 });
            }
        }
        if (self.chance(10)) desc.samplers[5] = .{ .stage = self.stage() };
        for (desc.attrs[0..2]) |*attr| attr.base_type = self.enumValue(gfx.ShaderAttrBaseType, 3);
        return desc;
    }

    fn pipelineDesc(self: *Fuzzer) gfx.PipelineDesc {
        var desc: gfx.PipelineDesc = .{
            .compute = self.chance(20),
            .shader = .{ .id = self.handle(.shader) },
            .color_count = self.int(i32, &.{ 0, 0, 1, 2 }),
            .index_type = self.enumValue(gfx.IndexType, 3),
            .primitive_type = self.enumValue(gfx.PrimitiveType, 5),
            .sample_count = self.int(i32, &.{ 0, 1, 4 }),
        };
        desc.depth = .{
            .pixel_format = self.int(gfx.PixelFormat, &.{ .default, .none, .depth, .depth_stencil, .rgba8 }),
            .compare = self.enumValue(gfx.CompareFunc, 8),
            .write_enabled = self.chance(40),
        };
        const num_attrs = self.rng.uintAtMost(usize, 3);
        for (desc.layout.attrs[0..num_attrs], 0..) |*attr, i| {
            attr.* = .{ .format = self.enumValue(gfx.VertexFormat, 28), .buffer_index = self.int(i32, &.{ 0, 0, 1 }) };
            if (i == 1 and self.chance(10)) attr.format = .invalid;
        }
        desc.layout.buffers[0].stride = self.int(i32, &.{ 0, 0, 12, 16, 6 });
        desc.layout.buffers[1].step_func = self.enumValue(gfx.VertexStep, 2);
        for (desc.colors[0..2]) |*color| {
            color.pixel_format = self.int(gfx.PixelFormat, &.{ .default, .default, .rgba8, .r8, .depth });
            color.blend = .{ .enabled = self.chance(30), .op_rgb = self.enumValue(gfx.BlendOp, 5), .src_factor_rgb = self.enumValue(gfx.BlendFactor, 19), .dst_factor_alpha = self.enumValue(gfx.BlendFactor, 19) };
        }
        return desc;
    }

    fn viewDesc(self: *Fuzzer) gfx.ViewDesc {
        var desc: gfx.ViewDesc = .{};
        // NOTE: the reference asserts when more than one view kind is defined
        for (0..1) |_| {
            const mip = self.int(i32, &.{ 0, 0, 1, 7 });
            const slice = self.int(i32, &.{ 0, 0, 1, 6 });
            switch (self.rng.uintLessThan(u32, 6)) {
                0 => desc.texture = .{ .image = .{ .id = self.nonzeroHandle(.image) }, .mip_levels = .{ .base = mip, .count = self.int(i32, &.{ 0, 1, 3 }) }, .slices = .{ .base = slice, .count = self.int(i32, &.{ 0, 1 }) } },
                1 => desc.storage_buffer = .{ .buffer = .{ .id = self.nonzeroHandle(.buffer) }, .offset = self.int(i32, &.{ 0, 0, 256, 4 }) },
                2 => desc.storage_image = .{ .image = .{ .id = self.nonzeroHandle(.image) }, .mip_level = mip, .slice = slice },
                3 => desc.color_attachment = .{ .image = .{ .id = self.nonzeroHandle(.image) }, .mip_level = mip, .slice = slice },
                4 => desc.resolve_attachment = .{ .image = .{ .id = self.nonzeroHandle(.image) }, .mip_level = mip, .slice = slice },
                else => desc.depth_stencil_attachment = .{ .image = .{ .id = self.nonzeroHandle(.image) }, .mip_level = mip, .slice = slice },
            }
        }
        return desc;
    }

    fn passDesc(self: *Fuzzer) gfx.Pass {
        var pass: gfx.Pass = .{};
        switch (self.rng.uintLessThan(u32, 3)) {
            0 => pass.swapchain = .{
                .width = self.int(i32, &.{ 0, 16, 16 }),
                .height = self.int(i32, &.{ 0, 16, 16 }),
                .sample_count = self.int(i32, &.{ 0, 0, 1, 4 }),
                .color_format = self.int(gfx.PixelFormat, &.{ .default, .default, .rgba8, .bgra8 }),
                .depth_format = self.int(gfx.PixelFormat, &.{ .default, .none, .depth_stencil }),
                .invalid = self.chance(5),
            },
            1 => {
                pass.compute = true;
                if (self.chance(10)) pass.swapchain.width = 4;
            },
            else => {
                const n = self.rng.uintAtMost(usize, 2);
                for (pass.attachments.colors[0..n], 0..) |*view, i| {
                    view.* = .{ .id = self.handle(.view) };
                    if (self.chance(15)) pass.attachments.resolves[i] = .{ .id = self.handle(.view) };
                }
                if (self.chance(40)) pass.attachments.depth_stencil = .{ .id = self.handle(.view) };
                if (self.chance(5)) pass.attachments.colors[3] = .{ .id = self.handle(.view) };
            },
        }
        pass.action.colors[0].load_action = self.enumValue(gfx.LoadAction, 3);
        return pass;
    }

    fn bindings(self: *Fuzzer) gfx.Bindings {
        var bnd: gfx.Bindings = .{};
        for (bnd.vertex_buffers[0..2], bnd.vertex_buffer_offsets[0..2]) |*vb, *offset| {
            if (self.chance(70)) vb.* = .{ .id = self.handle(.buffer) };
            offset.* = self.int(i32, &.{ 0, 0, 4, -4 });
        }
        if (self.chance(30)) bnd.index_buffer = .{ .id = self.handle(.buffer) };
        for (bnd.views[0..4]) |*view| {
            if (self.chance(50)) view.* = .{ .id = self.handle(.view) };
        }
        for (bnd.samplers[0..4]) |*smp| {
            if (self.chance(50)) smp.* = .{ .id = self.handle(.sampler) };
        }
        return bnd;
    }

    // ------------------------------------------------------------ checking

    fn fail(self: *Fuzzer, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print("DIVERGENCE at step {d} ({s}): " ++ fmt ++ "\n", .{ self.step, self.op } ++ args);
        std.debug.print("  zig log:", .{});
        for (zig_log.slice()) |entry| std.debug.print(" {d}:{s}", .{ entry.level, @tagName(@as(gfx.LogItem, @fromBackingInt(@intCast(entry.item)))) });
        std.debug.print("\n  c log:  ", .{});
        for (c_log.slice()) |entry| std.debug.print(" {d}:{s}", .{ entry.level, @tagName(@as(gfx.LogItem, @fromBackingInt(@intCast(entry.item)))) });
        std.debug.print("\n", .{});
        std.process.exit(1);
    }

    fn checkLogs(self: *Fuzzer) void {
        const zl = zig_log.slice();
        const cl = c_log.slice();
        if (zl.len != cl.len) self.fail("log length {d} vs {d}", .{ zl.len, cl.len });
        for (zl, cl) |a, b| {
            if (a.level != b.level or a.item != b.item) self.fail("log item mismatch", .{});
        }
        zig_log.len = 0;
        c_log.len = 0;
    }

    fn checkId(self: *Fuzzer, zig_id: u32, c_id: u32) void {
        if (zig_id != c_id) self.fail("handle {x} vs {x}", .{ zig_id, c_id });
    }

    fn checkStates(self: *Fuzzer) void {
        inline for (.{
            .{ Kind.buffer, gfx.queryBufferState, c.sg_query_buffer_state, gfx.Buffer, c.sg_buffer },
            .{ Kind.image, gfx.queryImageState, c.sg_query_image_state, gfx.Image, c.sg_image },
            .{ Kind.sampler, gfx.querySamplerState, c.sg_query_sampler_state, gfx.Sampler, c.sg_sampler },
            .{ Kind.shader, gfx.queryShaderState, c.sg_query_shader_state, gfx.Shader, c.sg_shader },
            .{ Kind.pipeline, gfx.queryPipelineState, c.sg_query_pipeline_state, gfx.Pipeline, c.sg_pipeline },
            .{ Kind.view, gfx.queryViewState, c.sg_query_view_state, gfx.View, c.sg_view },
        }) |entry| {
            const k = @backingInt(entry[0]);
            for (self.handles[k][0..self.num_handles[k]]) |id| {
                const zs: u32 = @backingInt(entry[1](entry[3]{ .id = id }));
                const cs: u32 = @intCast(entry[2](entry[4]{ .id = id }));
                if (zs != cs) self.fail("{s} {x} state {d} vs {d}", .{ @tagName(entry[0]), id, zs, cs });
            }
        }
        const zp: u32 = @backingInt(gfx.queryPassState());
        const cp: u32 = @intCast(c.sg_query_pass_state());
        if (zp != cp) self.fail("pass state {d} vs {d}", .{ zp, cp });
    }

    /// Compares every common frame statistics counter.
    fn checkStats(self: *Fuzzer) void {
        const zs = gfx.queryStats();
        const cs = c.sg_query_stats();
        compareFields(self, "prev_frame", zs.prev_frame, cs.prev_frame);
        compareFields(self, "total", zs.total, cs.total);
    }

    fn compareFields(self: *Fuzzer, comptime path: []const u8, z: anytype, cv: anytype) void {
        const Z = @TypeOf(z);
        switch (@typeInfo(Z)) {
            .@"struct" => |info| inline for (info.field_names) |name| {
                // backend-specific counters are not comparable with the dummy backend
                if (comptime std.mem.eql(u8, name, "gl") or std.mem.eql(u8, name, "d3d11") or std.mem.eql(u8, name, "metal") or std.mem.eql(u8, name, "wgpu") or std.mem.eql(u8, name, "vk")) continue;
                compareFields(self, path ++ "." ++ name, @field(z, name), @field(cv, name));
            },
            else => if (z != cv) self.fail("stats {s}: {d} vs {d}", .{ path, z, cv }),
        }
    }

    // ------------------------------------------------------------ operations

    fn run(self: *Fuzzer, steps: usize) void {
        for (0..steps) |i| {
            self.step = i;
            self.doStep();
            self.checkLogs();
            if (i % 8 == 0) self.checkStates();
        }
        if (self.in_pass) {
            self.op = "end_pass (final)";
            gfx.endPass();
            c.sg_end_pass();
        }
        self.op = "commit (final)";
        gfx.commit();
        c.sg_commit();
        self.checkLogs();
        self.checkStates();
        self.checkStats();
    }

    fn doStep(self: *Fuzzer) void {
        const roll = self.rng.uintLessThan(u32, 100);
        if (roll < 8) {
            self.op = "make_buffer";
            const desc = self.bufferDesc();
            const z = gfx.makeBuffer(desc);
            self.checkId(z.id, c.sg_make_buffer(&toC(c.sg_buffer_desc, desc)).id);
            self.track(.buffer, z.id);
        } else if (roll < 16) {
            self.op = "make_image";
            const desc = self.imageDesc();
            const z = gfx.makeImage(desc);
            self.checkId(z.id, c.sg_make_image(&toC(c.sg_image_desc, desc)).id);
            self.track(.image, z.id);
        } else if (roll < 19) {
            self.op = "make_sampler";
            const desc = self.samplerDesc();
            const z = gfx.makeSampler(desc);
            self.checkId(z.id, c.sg_make_sampler(&toC(c.sg_sampler_desc, desc)).id);
            self.track(.sampler, z.id);
        } else if (roll < 24) {
            self.op = "make_shader";
            const desc = self.shaderDesc();
            const z = gfx.makeShader(desc);
            self.checkId(z.id, c.sg_make_shader(&toC(c.sg_shader_desc, desc)).id);
            self.track(.shader, z.id);
        } else if (roll < 30) {
            self.op = "make_pipeline";
            const desc = self.pipelineDesc();
            const z = gfx.makePipeline(desc);
            self.checkId(z.id, c.sg_make_pipeline(&toC(c.sg_pipeline_desc, desc)).id);
            self.track(.pipeline, z.id);
        } else if (roll < 38) {
            self.op = "make_view";
            const desc = self.viewDesc();
            const z = gfx.makeView(desc);
            self.checkId(z.id, c.sg_make_view(&toC(c.sg_view_desc, desc)).id);
            self.track(.view, z.id);
        } else if (roll < 44) {
            self.lifecycle();
        } else if (roll < 50) {
            if (self.in_pass) {
                self.op = "end_pass";
                gfx.endPass();
                c.sg_end_pass();
                self.in_pass = false;
            } else {
                self.op = "begin_pass";
                const pass = self.passDesc();
                gfx.beginPass(pass);
                c.sg_begin_pass(&toC(c.sg_pass, pass));
                self.in_pass = true;
            }
        } else if (roll < 53) {
            if (!self.in_pass) {
                self.op = "commit";
                gfx.commit();
                c.sg_commit();
                self.checkStats();
            }
        } else if (roll < 60) {
            self.op = "apply_pipeline";
            const id = self.handle(.pipeline);
            gfx.applyPipeline(.{ .id = id });
            c.sg_apply_pipeline(.{ .id = id });
        } else if (roll < 67) {
            self.op = "apply_bindings";
            const bnd = self.bindings();
            gfx.applyBindings(bnd);
            c.sg_apply_bindings(&toC(c.sg_bindings, bnd));
        } else if (roll < 71) {
            self.op = "apply_uniforms";
            const slot = self.rng.uintLessThan(usize, 4);
            const data = self.range(self.int(usize, &.{ 16, 64, 4 }));
            gfx.applyUniforms(slot, data);
            c.sg_apply_uniforms(@intCast(slot), &toC(c.sg_range, data));
        } else if (roll < 77) {
            const base = self.int(i32, &.{ 0, 0, 3, -1 });
            const count = self.int(i32, &.{ 3, 3, 0, -3 });
            const instances = self.int(i32, &.{ 1, 1, 2, 0 });
            if (self.chance(50)) {
                self.op = "draw";
                gfx.draw(base, count, instances);
                c.sg_draw(base, count, instances);
            } else {
                self.op = "draw_ex";
                const base_vertex = self.int(i32, &.{ 0, 0, 2 });
                const base_instance = self.int(i32, &.{ 0, 0, 1, -1 });
                gfx.drawEx(base, count, instances, base_vertex, base_instance);
                c.sg_draw_ex(base, count, instances, base_vertex, base_instance);
            }
        } else if (roll < 80) {
            self.op = "dispatch";
            const x = self.int(i32, &.{ 1, 1, 0, 70000 });
            gfx.dispatch(x, 1, 1);
            c.sg_dispatch(x, 1, 1);
        } else if (roll < 84) {
            self.op = "viewport/scissor";
            gfx.applyViewport(0, 0, 8, 8, true);
            c.sg_apply_viewport(0, 0, 8, 8, true);
            gfx.applyScissorRect(1, 1, 4, 4, false);
            c.sg_apply_scissor_rect(1, 1, 4, 4, false);
        } else {
            self.transfer();
        }
    }

    fn lifecycle(self: *Fuzzer) void {
        const kind: Kind = @fromBackingInt(@intCast(self.rng.uintLessThan(u32, 6)));
        const id = self.handle(kind);
        switch (self.rng.uintLessThan(u32, 6)) {
            0 => {
                self.op = "destroy";
                switch (kind) {
                    inline else => |k| {
                        @field(gfx, "destroy" ++ capitalized(@tagName(k)))(.{ .id = id });
                        @field(c, "sg_destroy_" ++ @tagName(k))(.{ .id = id });
                    },
                }
            },
            1 => {
                self.op = "uninit";
                switch (kind) {
                    inline else => |k| {
                        @field(gfx, "uninit" ++ capitalized(@tagName(k)))(.{ .id = id });
                        @field(c, "sg_uninit_" ++ @tagName(k))(.{ .id = id });
                    },
                }
            },
            2 => {
                self.op = "dealloc";
                switch (kind) {
                    inline else => |k| {
                        @field(gfx, "dealloc" ++ capitalized(@tagName(k)))(.{ .id = id });
                        @field(c, "sg_dealloc_" ++ @tagName(k))(.{ .id = id });
                    },
                }
            },
            3 => {
                self.op = "fail";
                switch (kind) {
                    inline else => |k| {
                        @field(gfx, "fail" ++ capitalized(@tagName(k)))(.{ .id = id });
                        @field(c, "sg_fail_" ++ @tagName(k))(.{ .id = id });
                    },
                }
            },
            4 => {
                self.op = "alloc";
                switch (kind) {
                    inline else => |k| {
                        const z = @field(gfx, "alloc" ++ capitalized(@tagName(k)))();
                        self.checkId(z.id, @field(c, "sg_alloc_" ++ @tagName(k))().id);
                        self.track(k, z.id);
                    },
                }
            },
            else => {
                self.op = "init";
                switch (kind) {
                    .buffer => {
                        const desc = self.bufferDesc();
                        gfx.initBuffer(.{ .id = id }, desc);
                        c.sg_init_buffer(.{ .id = id }, &toC(c.sg_buffer_desc, desc));
                    },
                    .image => {
                        const desc = self.imageDesc();
                        gfx.initImage(.{ .id = id }, desc);
                        c.sg_init_image(.{ .id = id }, &toC(c.sg_image_desc, desc));
                    },
                    .sampler => {
                        const desc = self.samplerDesc();
                        gfx.initSampler(.{ .id = id }, desc);
                        c.sg_init_sampler(.{ .id = id }, &toC(c.sg_sampler_desc, desc));
                    },
                    .shader => {
                        const desc = self.shaderDesc();
                        gfx.initShader(.{ .id = id }, desc);
                        c.sg_init_shader(.{ .id = id }, &toC(c.sg_shader_desc, desc));
                    },
                    .pipeline => {
                        const desc = self.pipelineDesc();
                        gfx.initPipeline(.{ .id = id }, desc);
                        c.sg_init_pipeline(.{ .id = id }, &toC(c.sg_pipeline_desc, desc));
                    },
                    .view => {
                        const desc = self.viewDesc();
                        gfx.initView(.{ .id = id }, desc);
                        c.sg_init_view(.{ .id = id }, &toC(c.sg_view_desc, desc));
                    },
                }
            },
        }
    }

    fn transfer(self: *Fuzzer) void {
        switch (self.rng.uintLessThan(u32, 7)) {
            0, 1 => {
                const desc: gfx.WriteBufferDesc = .{
                    .src = .{ .data = self.range(self.int(usize, &.{ 16, 64, 0 })), .offset = self.int(usize, &.{ 0, 0, 8 }) },
                    .dst = .{ .buffer = .{ .id = self.handle(.buffer) }, .offset = self.int(usize, &.{ 0, 0, 4, 2, 300 }) },
                    .size = self.int(usize, &.{ 0, 0, 8, 1000 }),
                };
                if (self.chance(50)) {
                    self.op = "write_buffer_transient";
                    gfx.writeBufferTransient(desc);
                    c.sg_write_buffer_transient(&toC(c.sg_write_buffer_desc, desc));
                } else {
                    self.op = "write_buffer_unsealed";
                    gfx.writeBufferUnsealed(desc);
                    c.sg_write_buffer_unsealed(&toC(c.sg_write_buffer_desc, desc));
                }
            },
            2, 3 => {
                const desc: gfx.WriteImageDesc = .{
                    .src = .{ .data = self.range(self.int(usize, &.{ 64, 1024, 4096, 0 })), .bytes_per_row = self.int(i32, &.{ 0, 0, 64, 3 }) },
                    .dst = .{ .image = .{ .id = self.handle(.image) }, .mip_level = self.int(i32, &.{ 0, 0, 1, 9 }), .x = self.int(i32, &.{ 0, 0, 2, 20 }) },
                    .size = .{ .width = self.int(i32, &.{ 0, 0, 2, 40 }) },
                };
                if (self.chance(50)) {
                    self.op = "write_image_transient";
                    gfx.writeImageTransient(desc);
                    c.sg_write_image_transient(&toC(c.sg_write_image_desc, desc));
                } else {
                    self.op = "write_image_unsealed";
                    gfx.writeImageUnsealed(desc);
                    c.sg_write_image_unsealed(&toC(c.sg_write_image_desc, desc));
                }
            },
            4 => {
                if (self.chance(50)) {
                    self.op = "seal_buffer";
                    const id = self.handle(.buffer);
                    gfx.sealBuffer(.{ .id = id });
                    c.sg_seal_buffer(.{ .id = id });
                } else {
                    self.op = "seal_image";
                    const id = self.handle(.image);
                    gfx.sealImage(.{ .id = id });
                    c.sg_seal_image(.{ .id = id });
                }
            },
            5 => {
                self.op = "copy_buffer_to_buffer";
                const desc: gfx.CopyBufferToBufferDesc = .{
                    .src = .{ .buffer = .{ .id = self.handle(.buffer) }, .offset = self.int(usize, &.{ 0, 0, 4, 2 }) },
                    .dst = .{ .buffer = .{ .id = self.handle(.buffer) }, .offset = self.int(usize, &.{ 0, 0, 8 }) },
                    .size = self.int(usize, &.{ 4, 16, 0, 512 }),
                };
                gfx.copyBufferToBuffer(desc);
                c.sg_copy_buffer_to_buffer(&toC(c.sg_copy_buffer_to_buffer_desc, desc));
            },
            else => {
                self.op = "copy_buffer_to_image";
                const desc: gfx.CopyBufferToImageDesc = .{
                    .src = .{ .buffer = .{ .id = self.handle(.buffer) }, .offset = self.int(usize, &.{ 0, 0, 4 }), .bytes_per_row = self.int(i32, &.{ 0, 0, 256, 64 }) },
                    .dst = .{ .image = .{ .id = self.handle(.image) }, .mip_level = self.int(i32, &.{ 0, 0, 1 }), .y = self.int(i32, &.{ 0, 0, 1 }) },
                    .size = .{ .height = self.int(i32, &.{ 0, 0, 1 }) },
                };
                gfx.copyBufferToImage(desc);
                c.sg_copy_buffer_to_image(&toC(c.sg_copy_buffer_to_image_desc, desc));
            },
        }
    }
};

fn capitalized(comptime name: []const u8) []const u8 {
    return [_]u8{std.ascii.toUpper(name[0])} ++ name[1..];
}

pub fn main(init: std.process.Init) !void {
    var seed: u64 = 1;
    var runs: usize = 200;
    var steps: usize = 400;
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |arg| {
        const value = args.next() orelse return error.MissingArgumentValue;
        if (std.mem.eql(u8, arg, "--seed")) seed = try std.fmt.parseInt(u64, value, 10) else if (std.mem.eql(u8, arg, "--runs")) runs = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, arg, "--steps")) steps = try std.fmt.parseInt(usize, value, 10) else return error.UnknownArgument;
    }

    for (0..runs) |run_index| {
        const run_seed = seed +% run_index;
        var prng = std.Random.DefaultPrng.init(run_seed);
        var fuzzer: Fuzzer = .{ .rng = prng.random() };
        for (&fuzzer.bytes, 0..) |*b, i| b.* = @truncate(i);
        // small pools so that exhaustion and slot reuse are exercised
        const desc: gfx.Desc = .{
            .buffer_pool_size = 8,
            .image_pool_size = 8,
            .sampler_pool_size = 4,
            .shader_pool_size = 4,
            .pipeline_pool_size = 6,
            .view_pool_size = 8,
            .max_commit_listeners = 4,
            .logger = .{ .func = zigLogger },
        };
        var c_desc = toC(c.sg_desc, desc);
        c_desc.logger.func = cLogger;
        try gfx.setup(init.gpa, .dummy, desc);
        c.sg_setup(&c_desc);
        fuzzer.op = "setup";
        fuzzer.checkLogs();
        fuzzer.run(steps);
        gfx.shutdown();
        c.sg_shutdown();
        zig_log.len = 0;
        c_log.len = 0;
    }
    std.debug.print("differential fuzz: {d} runs x {d} steps from seed {d}, no divergence\n", .{ runs, steps, seed });
}
