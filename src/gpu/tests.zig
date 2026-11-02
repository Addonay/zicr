const std = @import("std");
const gfx = @import("internal.zig");
const defaults = @import("defaults.zig");
const formats = @import("formats.zig");
const Pool = @import("pool.zig").Pool;

test "generational slots reject stale handles after reuse and reinitialization" {
    const core = @import("core.zig");
    var pool = try Pool(core.Buffer).init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    const first = pool.alloc().?;
    try std.testing.expectEqual(@as(u32, 0x10001), first);
    try std.testing.expectEqual(@as(?u32, null), pool.alloc());
    const res = pool.lookup(first).?;
    res.slot.state = .valid;
    core.resetToAllocState(res);
    try std.testing.expectEqual(@as(u32, 1), pool.lookup(first).?.slot.uninit_count);
    pool.free(res);
    try std.testing.expectEqual(@as(u32, 1), pool.numFree());
    const second = pool.alloc().?;
    try std.testing.expectEqual(@as(u32, 0x20001), second);
    try std.testing.expect(pool.lookup(first) == null);
    try std.testing.expect(pool.lookup(0xffff) == null);
}

test "pipeline default layout packs attributes independently by buffer" {
    var value: gfx.PipelineDesc = .{};
    value.layout.attrs[0] = .{ .format = .float3 };
    value.layout.attrs[1] = .{ .format = .ubyte4n };
    value.layout.attrs[2] = .{ .format = .float2, .buffer_index = 1 };
    const env: gfx.EnvironmentDefaults = .{ .color_format = .bgra8, .depth_format = .depth_stencil, .sample_count = 4 };
    const resolved = defaults.pipeline(value, env);
    try std.testing.expectEqual(@as(i32, 12), resolved.layout.attrs[1].offset);
    try std.testing.expectEqual(@as(i32, 16), resolved.layout.buffers[0].stride);
    try std.testing.expectEqual(@as(i32, 8), resolved.layout.buffers[1].stride);
    try std.testing.expectEqual(@as(i32, 4), resolved.sample_count);
    try std.testing.expectEqual(gfx.PixelFormat.bgra8, resolved.colors[0].pixel_format);
    value.layout.attrs[1].offset = 20;
    const explicit = defaults.pipeline(value, env);
    try std.testing.expectEqual(@as(i32, 20), explicit.layout.attrs[1].offset);
}

test "compressed texture pitches cover partial blocks and row alignment" {
    try std.testing.expectEqual(@as(i32, 8), formats.rowPitch(.bc1_rgba, 1, 1));
    try std.testing.expectEqual(@as(i32, 16), formats.rowPitch(.bc1_rgba, 5, 1));
    try std.testing.expectEqual(@as(i32, 256), formats.rowPitch(.rgba8, 3, 256));
    try std.testing.expectEqual(@as(i32, 32), formats.surfacePitch(.bc1_rgba, 5, 5, 1));
    try std.testing.expectEqual(@as(usize, 292), formats.imageCopySize(.rgba8, 16, 256, 1, 3, 2));
    try std.testing.expectEqual(@as(u32, 48), formats.uniformSize(.float3, 3, .std140));
    try std.testing.expectEqual(@as(u32, 36), formats.uniformSize(.float3, 3, .native));
    try std.testing.expectEqual(@as(u32, 16), formats.uniformAlignment(.float3, 1, .std140));
}

test "dummy lifecycle validates descriptors and preserves slot identity through uninit" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    try gfx.setup(std.testing.allocator, .dummy, .{ .buffer_pool_size = 1 });
    defer gfx.shutdown();
    try std.testing.expect(gfx.isValid());
    const handle = gfx.makeBuffer(.{ .size = 16, .usage = .{ .write_unsealed = true } });
    try std.testing.expectEqual(gfx.ResourceState.unsealed, gfx.queryBufferState(handle));
    try std.testing.expectEqual(@as(u32, 0), gfx.makeBuffer(.{}).id);
    gfx.uninitBuffer(handle);
    try std.testing.expectEqual(gfx.ResourceState.alloc, gfx.queryBufferState(handle));
    gfx.initBuffer(handle, .{ .size = 16, .usage = .{ .write_transient = true } });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryBufferState(handle));
    try std.testing.expectEqual(@as(u32, 1), gfx.queryBufferInfo(handle).slot.uninit_count);
    gfx.destroyBuffer(handle);
    try std.testing.expectEqual(gfx.ResourceState.invalid, gfx.queryBufferState(handle));
    const invalid = gfx.makeBuffer(.{});
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryBufferState(invalid));
    const stats = gfx.queryStats();
    try std.testing.expectEqual(@as(u32, 1), stats.total.buffers.alive);
    try std.testing.expectEqual(@as(u32, 2), stats.total.buffers.allocated);
}

test "setup reports missing GPU environments and unknown backends without creating state" {
    try std.testing.expectError(error.MissingVulkanLoader, gfx.setup(std.testing.allocator, .vulkan, .{}));
    try std.testing.expect(!gfx.isValid());
    try std.testing.expectError(error.MissingWgpuDevice, gfx.setup(std.testing.allocator, .wgpu, .{ .environment = .{ .defaults = .{ .color_format = .bgra8 } } }));
    try std.testing.expect(!gfx.isValid());
    try std.testing.expectError(error.BackendNotPorted, gfx.setup(std.testing.allocator, @fromBackingInt(@intCast(99)), .{}));
    try std.testing.expect(!gfx.isValid());
}

test "setup releases every completed allocation on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            try gfx.setup(allocator, .dummy, .{});
            gfx.shutdown();
        }
    }.run, .{});
}

test "image defaults and attachment resource lifecycle" {
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    const image = gfx.makeImage(.{ .width = 32, .height = 32, .usage = .{ .color_attachment = true } });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryImageState(image));
    const view = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryViewState(view));
    try std.testing.expectEqual(gfx.ViewType.colorattachment, gfx.queryViewType(view));
    try std.testing.expectEqual(image, gfx.queryViewImage(view));
    const shader = gfx.makeShader(.{});
    const pipeline = gfx.makePipeline(.{ .shader = shader });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryPipelineState(pipeline));
    const sampler = gfx.makeSampler(.{});
    try std.testing.expectEqual(gfx.Filter.nearest, gfx.querySamplerDesc(sampler).min_filter);
}

test "commit listener identity includes user data and slots are reusable" {
    try gfx.setup(std.testing.allocator, .dummy, .{ .max_commit_listeners = 1 });
    defer gfx.shutdown();
    var calls: u32 = 0;
    const listener: gfx.CommitListener = .{ .func = struct {
        fn call(user_data: ?*anyopaque) void {
            const counter: *u32 = @ptrCast(@alignCast(user_data.?));
            counter.* += 1;
        }
    }.call, .user_data = &calls };
    try std.testing.expect(gfx.addCommitListener(listener));
    try std.testing.expect(!gfx.addCommitListener(listener));
    gfx.commit();
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(gfx.removeCommitListener(listener));
    try std.testing.expect(!gfx.removeCommitListener(listener));
    gfx.commit();
    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(gfx.addCommitListener(listener));
    gfx.commit();
    try std.testing.expectEqual(@as(u32, 2), calls);
}

test "all exported native API functions compile" {
    @setEvalBranchQuota(100_000);
    const api = @import("api.zig");
    inline for (@typeInfo(api).@"struct".decl_names) |name| {
        _ = &@field(api, name);
    }
}

test "writes rotate transient slots once per frame and sealing changes state" {
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    const data = [_]u32{ 1, 2, 3, 4 };
    const dynamic = gfx.makeBuffer(.{ .size = @sizeOf(@TypeOf(data)), .usage = .{ .write_transient = true } });
    const write: gfx.WriteBufferDesc = .{ .src = .{ .data = gfx.Range.fromSlice(u32, &data) }, .dst = .{ .buffer = dynamic } };
    gfx.writeBufferTransient(write);
    try std.testing.expectEqual(@as(i32, 1), gfx.queryBufferInfo(dynamic).active_slot);
    gfx.writeBufferTransient(write);
    try std.testing.expectEqual(@as(i32, 1), gfx.queryBufferInfo(dynamic).active_slot);
    gfx.commit();
    gfx.writeBufferTransient(write);
    try std.testing.expectEqual(@as(i32, 0), gfx.queryBufferInfo(dynamic).active_slot);
    const immutable = gfx.makeBuffer(.{ .size = @sizeOf(@TypeOf(data)), .usage = .{ .write_unsealed = true } });
    gfx.writeBufferUnsealed(.{ .src = .{ .data = gfx.Range.fromSlice(u32, &data) }, .dst = .{ .buffer = immutable } });
    try std.testing.expectEqual(gfx.ResourceState.unsealed, gfx.queryBufferState(immutable));
    gfx.sealBuffer(immutable);
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryBufferState(immutable));
}

test "render commands trace in order and frame statistics advance at commit" {
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    var calls: u32 = 0;
    _ = gfx.installTraceHooks(.{ .user_data = &calls, .draw = struct {
        fn callback(base: i32, elements: i32, instances: i32, user_data: ?*anyopaque) void {
            std.debug.assert(base == 0 and elements == 3 and instances == 1);
            const count: *u32 = @ptrCast(@alignCast(user_data.?));
            count.* += 1;
        }
    }.callback });
    const shader = gfx.makeShader(.{});
    const pipeline = gfx.makePipeline(.{ .shader = shader });
    gfx.beginPass(.{ .swapchain = .{ .width = 640, .height = 480 } });
    try std.testing.expectEqual(gfx.PassState.render, gfx.queryPassState());
    gfx.applyPipeline(pipeline);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try std.testing.expectEqual(gfx.PassState.none, gfx.queryPassState());
    gfx.commit();
    const stats = gfx.queryStats();
    try std.testing.expectEqual(@as(u32, 1), stats.prev_frame.frame_index);
    try std.testing.expectEqual(@as(u32, 1), stats.prev_frame.num_draw);
    try std.testing.expectEqual(@as(u32, 1), stats.prev_frame.num_passes);
    try std.testing.expectEqual(@as(u32, 0), stats.cur_frame.num_draw);
    try std.testing.expectEqual(@as(u32, 1), calls);
}

test "shader validation rejects missing texture pairs and mismatched sampler kinds" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    desc.views[0].texture = .{ .stage = .fragment, .sample_type = .uint };
    desc.samplers[0] = .{ .stage = .fragment };
    const missing_pair = gfx.makeShader(desc);
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryShaderState(missing_pair));
    desc.texture_sampler_pairs[0] = .{ .stage = .fragment };
    const wrong_sampler = gfx.makeShader(desc);
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryShaderState(wrong_sampler));
    desc.samplers[0].sampler_type = .nonfiltering;
    const valid = gfx.makeShader(desc);
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryShaderState(valid));
    desc.uniform_blocks[0] = .{ .stage = .vertex };
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryShaderState(gfx.makeShader(desc)));
}

test "failed initialization and allocated slots expose empty common resource data" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    const allocated = gfx.allocBuffer();
    try std.testing.expectEqual(@as(i32, 0), gfx.queryBufferInfo(allocated).num_slots);
    gfx.initBuffer(allocated, .{ .size = 17 });
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryBufferState(allocated));
    try std.testing.expectEqual(@as(usize, 0), gfx.queryBufferSize(allocated));
    try std.testing.expectEqual(@as(i32, 0), gfx.queryBufferInfo(allocated).num_slots);
    gfx.uninitBuffer(allocated);
    gfx.initBuffer(allocated, .{ .size = 17, .usage = .{ .write_unsealed = true } });
    try std.testing.expectEqual(@as(i32, 1), gfx.queryBufferInfo(allocated).num_slots);
}

test "view ranges use source defaults and validate attachment mip levels" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    const image = gfx.makeImage(.{ .width = 32, .height = 32, .num_mipmaps = 3, .usage = .{ .write_unsealed = true } });
    const view = gfx.makeView(.{ .texture = .{ .image = image, .mip_levels = .{ .base = 1 } } });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryViewState(view));
    try std.testing.expectEqual(@as(i32, 2), gfx.queryViewDesc(view).texture.mip_levels.count);
    const attachment = gfx.makeImage(.{ .width = 32, .height = 32, .usage = .{ .color_attachment = true } });
    const invalid = gfx.makeView(.{ .color_attachment = .{ .image = attachment, .mip_level = 1 } });
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryViewState(invalid));
}

test "pipeline rejects unsupported attribute and invalid depth-only state" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    const shader = gfx.makeShader(.{});
    var desc: gfx.PipelineDesc = .{ .shader = shader };
    desc.depth = .{ .pixel_format = .none, .write_enabled = true };
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryPipelineState(gfx.makePipeline(desc)));
    desc.depth.write_enabled = false;
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryPipelineState(gfx.makePipeline(desc)));
    desc.layout.attrs[0].format = .int10_n2;
    try std.testing.expectEqual(gfx.ResourceState.failed, gfx.queryPipelineState(gfx.makePipeline(desc)));
}

test {
    _ = @import("backends/gl/tests.zig");
}

const LogEvents = struct {
    ids: [64]u32 = undefined,
    count: usize = 0,
    fn callback(_: ?[*:0]const u8, level: u32, item: u32, _: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, user_data: ?*anyopaque) void {
        const self: *LogEvents = @ptrCast(@alignCast(user_data.?));
        if (level == 1 and self.count < self.ids.len) {
            self.ids[self.count] = item;
            self.count += 1;
        }
    }
    fn contains(self: LogEvents, item: gfx.LogItem) bool {
        return std.mem.indexOfScalar(u32, self.ids[0..self.count], @backingInt(item)) != null;
    }
};

test "bindings reject wrong view kinds and sampling an active render attachment" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    var events: LogEvents = .{};
    try gfx.setup(std.testing.allocator, .dummy, .{ .logger = .{ .func = LogEvents.callback, .user_data = &events } });
    defer gfx.shutdown();
    const image = gfx.makeImage(.{ .width = 8, .height = 8, .usage = .{ .color_attachment = true } });
    const attachment = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    const texture = gfx.makeView(.{ .texture = .{ .image = image } });
    const sampler = gfx.makeSampler(.{});
    var shader_desc: gfx.ShaderDesc = .{};
    shader_desc.views[0].texture = .{ .stage = .fragment };
    shader_desc.samplers[0] = .{ .stage = .fragment };
    shader_desc.texture_sampler_pairs[0] = .{ .stage = .fragment };
    const shader = gfx.makeShader(shader_desc);
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none } });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryPipelineState(pipeline));
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = attachment;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = attachment;
    bindings.samplers[0] = sampler;
    gfx.applyBindings(bindings);
    try std.testing.expect(events.contains(.validate_abnd_expect_texview));
    gfx.endPass();
    events.count = 0;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    bindings.views[0] = texture;
    gfx.applyBindings(bindings);
    try std.testing.expect(events.contains(.validate_abnd_texture_binding_vs_color_attachment));
    try std.testing.expect(!events.contains(.validate_abnd_expect_texview));
    gfx.endPass();
}

test "missing transient writes are diagnosed at draw and recover after the next frame upload" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    var events: LogEvents = .{};
    try gfx.setup(std.testing.allocator, .dummy, .{ .logger = .{ .func = LogEvents.callback, .user_data = &events } });
    defer gfx.shutdown();
    const buffer = gfx.makeBuffer(.{ .size = 24, .usage = .{ .write_transient = true } });
    const shader = gfx.makeShader(.{});
    var pipeline_desc: gfx.PipelineDesc = .{ .shader = shader };
    pipeline_desc.layout.attrs[0] = .{ .format = .float2 };
    const pipeline = gfx.makePipeline(pipeline_desc);
    var bindings: gfx.Bindings = .{};
    bindings.vertex_buffers[0] = buffer;
    gfx.beginPass(.{ .swapchain = .{ .width = 8, .height = 8 } });
    gfx.applyPipeline(pipeline);
    gfx.applyBindings(bindings);
    try std.testing.expect(!events.contains(.validate_draw_write_buffer_transient_missing));
    gfx.draw(0, 3, 1);
    try std.testing.expect(events.contains(.validate_draw_write_buffer_transient_missing));
    gfx.endPass();
    gfx.commit();
    events.count = 0;
    const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
    gfx.writeBufferTransient(.{ .src = .{ .data = gfx.Range.fromSlice(f32, &positions) }, .dst = .{ .buffer = buffer } });
    gfx.beginPass(.{ .swapchain = .{ .width = 8, .height = 8 } });
    gfx.applyPipeline(pipeline);
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 1);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    gfx.endPass();
}

test "GL setup failure unwinds all pools and never leaves a dummy context behind" {
    // Windows supplies a built-in opengl32 loader, but this test has no GL
    // context. Other hosts require the application to supply the loader.
    const missing_loader = if (@import("builtin").os.tag == .windows) error.MissingOpenGlFunction else error.MissingGlProcAddress;
    try std.testing.expectError(missing_loader, gfx.setup(std.testing.allocator, .glcore, .{}));
    try std.testing.expect(!gfx.isValid());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn resolve(_: [:0]const u8, _: ?*anyopaque) ?*const anyopaque {
            return null;
        }
        fn run(allocator: std.mem.Allocator) !void {
            gfx.setup(allocator, .glcore, .{ .environment = .{ .gl = .{ .get_proc_address = resolve } } }) catch |err| {
                if (err != error.MissingOpenGlFunction) return err;
                try std.testing.expect(!gfx.isValid());
                return;
            };
            gfx.shutdown();
            return error.UnexpectedGlSetupSuccess;
        }
    }.run, .{});
}

test {
    _ = @import("backends/d3d11/tests.zig");
}

const MessageLog = struct {
    last: [128]u8 = @splat(0),
    fn callback(_: ?[*:0]const u8, level: u32, _: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, user_data: ?*anyopaque) void {
        const self: *MessageLog = @ptrCast(@alignCast(user_data.?));
        if (level != 1) return;
        const text = std.mem.span(message orelse return);
        const n = @min(text.len, self.last.len - 1);
        @memcpy(self.last[0..n], text[0..n]);
        self.last[n] = 0;
    }
};

test "debug builds pass the source log message text to the logger" {
    if (!@import("config.zig").debug) return error.SkipZigTest;
    var log: MessageLog = .{};
    try gfx.setup(std.testing.allocator, .dummy, .{ .logger = .{ .func = MessageLog.callback, .user_data = &log } });
    defer gfx.shutdown();
    _ = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true } });
    try std.testing.expect(std.mem.startsWith(u8, std.mem.sliceTo(&log.last, 0), "VALIDATE_BUFFERDESC_EXPECT_DATA: sg_buffer_desc: buffer content can never be initialized"));
}

test "begin pass validation diagnoses offscreen attachment mismatches and swapchain leftovers" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    var events: LogEvents = .{};
    try gfx.setup(std.testing.allocator, .dummy, .{ .logger = .{ .func = LogEvents.callback, .user_data = &events } });
    defer gfx.shutdown();
    const big = gfx.makeImage(.{ .width = 16, .height = 16, .usage = .{ .color_attachment = true } });
    const small = gfx.makeImage(.{ .width = 8, .height = 8, .usage = .{ .color_attachment = true } });
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = gfx.makeView(.{ .color_attachment = .{ .image = big } });
    pass.attachments.colors[2] = gfx.makeView(.{ .color_attachment = .{ .image = small } });
    pass.swapchain.width = 4;
    gfx.beginPass(pass);
    try std.testing.expect(events.contains(.validate_beginpass_colorattachmentviews_continuous));
    try std.testing.expect(events.contains(.validate_beginpass_colorattachmentview_sizes));
    try std.testing.expect(events.contains(.validate_beginpass_swapchain_expect_width_notset));
    try std.testing.expectEqual(gfx.PassState.render, gfx.queryPassState());
    gfx.endPass();
    try std.testing.expectEqual(gfx.PassState.none, gfx.queryPassState());
    events.count = 0;
    gfx.beginPass(.{ .swapchain = .{ .width = 8 } });
    try std.testing.expect(events.contains(.validate_beginpass_swapchain_expect_height));
    gfx.endPass();
}

test "apply pipeline and uniforms validate against the pass and shader" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    var events: LogEvents = .{};
    try gfx.setup(std.testing.allocator, .dummy, .{ .logger = .{ .func = LogEvents.callback, .user_data = &events } });
    defer gfx.shutdown();
    var shader_desc: gfx.ShaderDesc = .{};
    shader_desc.uniform_blocks[0] = .{ .stage = .vertex, .size = 16 };
    const shader = gfx.makeShader(shader_desc);
    const pipeline = gfx.makePipeline(.{ .shader = shader, .colors = .{ .{ .pixel_format = .r8 }, .{}, .{}, .{}, .{}, .{}, .{}, .{} } });
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryPipelineState(pipeline));
    gfx.beginPass(.{ .swapchain = .{ .width = 8, .height = 8 } });
    gfx.applyPipeline(pipeline);
    try std.testing.expect(events.contains(.validate_apip_swapchain_color_format));
    events.count = 0;
    // a rejected pipeline is not applied, so uniforms have no pipeline
    const value = [_]f32{ 1, 2 };
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &value));
    try std.testing.expect(events.contains(.validate_au_no_pipeline));
    gfx.endPass();
    events.count = 0;
    const matching = gfx.makePipeline(.{ .shader = shader });
    gfx.beginPass(.{ .swapchain = .{ .width = 8, .height = 8 } });
    gfx.applyPipeline(matching);
    try std.testing.expectEqual(@as(usize, 0), events.count);
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &value));
    try std.testing.expect(events.contains(.validate_au_size));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    events.count = 0;
    gfx.beginPass(.{ .compute = true });
    gfx.applyViewport(0, 0, 4, 4, true);
    try std.testing.expect(events.contains(.validate_avp_renderpass_expected));
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
}

test "copies are rejected inside passes and sealing requires the unsealed state" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("config.zig").debug) return error.SkipZigTest;
    var events: LogEvents = .{};
    try gfx.setup(std.testing.allocator, .dummy, .{ .logger = .{ .func = LogEvents.callback, .user_data = &events } });
    defer gfx.shutdown();
    const src = gfx.makeBuffer(.{ .size = 16, .usage = .{ .copy_src = true, .write_transient = true } });
    const dst = gfx.makeBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } });
    gfx.beginPass(.{ .swapchain = .{ .width = 8, .height = 8 } });
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dst }, .size = 32 });
    try std.testing.expect(events.contains(.validate_copybuffertobuffer_inside_pass));
    try std.testing.expect(events.contains(.validate_copybuffertobuffer_src_overflow));
    gfx.endPass();
    events.count = 0;
    gfx.sealBuffer(dst);
    try std.testing.expect(events.contains(.validate_sealbuffer_resourcestate));
    gfx.sealBuffer(.{ .id = 12345 });
    try std.testing.expect(events.contains(.seal_buffer_alive));
    const image = gfx.makeImage(.{ .width = 4, .height = 4, .usage = .{ .write_unsealed = true } });
    try std.testing.expectEqual(gfx.ResourceState.unsealed, gfx.queryImageState(image));
    const pixels: [64]u8 = @splat(0);
    events.count = 0;
    gfx.writeImageUnsealed(.{ .src = .{ .data = gfx.Range.fromSlice(u8, &pixels) }, .dst = .{ .image = image, .x = 2 }, .size = .{ .width = 4 } });
    try std.testing.expect(events.contains(.validate_writeimage_write_width_overflow));
    gfx.sealImage(image);
    try std.testing.expectEqual(gfx.ResourceState.valid, gfx.queryImageState(image));
}

test "WebGPU mapping callback owns abandoned tickets and reports mapping failures" {
    const sdk = @import("backends/wgpu/sdk.zig");
    const Pending = @import("backends/wgpu/readback.zig").Pending;
    const Fake = struct {
        var callback: sdk.BufferMapCallbackInfo = .{};
        var released: u32 = 0;
        var unmapped: u32 = 0;
        fn map(_: ?sdk.Buffer, _: u64, _: usize, _: usize, cb: sdk.BufferMapCallbackInfo) callconv(.c) sdk.Future {
            callback = cb;
            return .{ .id = 1 };
        }
        fn release(_: ?sdk.Buffer) callconv(.c) void {
            released += 1;
        }
        fn unmap(_: ?sdk.Buffer) callconv(.c) void {
            unmapped += 1;
        }
    };
    Fake.released = 0;
    Fake.unmapped = 0;
    var procs: sdk.Procs = undefined;
    procs.wgpuBufferMapAsync = Fake.map;
    procs.wgpuBufferRelease = Fake.release;
    procs.wgpuBufferUnmap = Fake.unmap;
    const allocator = std.testing.allocator;
    var borrowed: [4]u8 = @splat(0xA5);
    for ([_]bool{ true, false }) |owns_data| for ([_]u32{ 1, 5 }) |status| {
        const pending = try allocator.create(Pending);
        pending.* = .{ .allocator = allocator, .procs = procs, .device = @ptrFromInt(1), .device_poll = null, .buffer = @ptrFromInt(1), .mapped_size = 4, .data = if (owns_data) try allocator.alloc(u8, 4) else &borrowed, .owns_data = owns_data };
        pending.start();
        try std.testing.expectEqual(@as(?[]const u8, null), try pending.poll());
        // Drop the client while the driver still holds userdata. Completion must
        // release it once, not touch freed memory or leak the output allocation.
        pending.release();
        Fake.callback.callback.?(status, .{}, Fake.callback.userdata1, null);
        try std.testing.expectEqual([4]u8{ 0xA5, 0xA5, 0xA5, 0xA5 }, borrowed);
    };
    try std.testing.expectEqual(@as(u32, 4), Fake.released);
    try std.testing.expectEqual(@as(u32, 2), Fake.unmapped);
}

test "D3D12 failed fence event registration cannot retire unfinished work" {
    const sdk = @import("backends/d3d12/sdk.zig");
    const Fake = struct {
        vtable: *const [10]?*const anyopaque,
        value: u64 = 0,
        registrations: u32 = 0,
        fn completed(object: *sdk.Object) callconv(sdk.call_conv) u64 {
            const self: *@This() = @ptrCast(@alignCast(object));
            return self.value;
        }
        fn register(object: *sdk.Object, target: u64, _: sdk.Handle) callconv(sdk.call_conv) i32 {
            const self: *@This() = @ptrCast(@alignCast(object));
            self.registrations += 1;
            if (self.registrations < 3) return -1;
            self.value = target;
            return 0;
        }
    };
    var functions: [10]?*const anyopaque = @splat(null);
    functions[8] = @ptrCast(&Fake.completed);
    functions[9] = @ptrCast(&Fake.register);
    var fence: Fake = .{ .vtable = &functions };
    @import("backends/d3d12/memory.zig").waitFence(@ptrCast(&fence), null, 7);
    try std.testing.expectEqual(@as(u32, 3), fence.registrations);
    try std.testing.expectEqual(@as(u64, 7), fence.value);
}

test {
    _ = @import("backends/vulkan/pipeline_cache.zig");
}
