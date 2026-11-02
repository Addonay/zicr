//! Equal real-GPU workloads through C sokol, the source-shaped raw API and Device.
//! C is linked into this benchmark only; zicr remains native Zig.
const std = @import("std");
const gpu = @import("zicr").gpu;
const raw = gpu.raw;
const c = @import("bench_ref");
const toC = @import("c_convert.zig").toC;
const shaders = @import("bench_shaders");
const harness = @import("harness");
const bench_backend = @import("bench_options").backend;
const vulkan_bench = std.mem.eql(u8, bench_backend, "vulkan");
const wgpu_bench = std.mem.eql(u8, bench_backend, "wgpu");
const d3d11_bench = std.mem.eql(u8, bench_backend, "d3d11");
const metal_bench = std.mem.eql(u8, bench_backend, "metal");
const backend: gpu.Backend = if (metal_bench) .metal else if (d3d11_bench) .d3d11 else if (wgpu_bench) .wgpu else if (vulkan_bench) .vulkan else .gl;
const variant: harness.Variant = if (metal_bench) .metal else if (d3d11_bench) .d3d11 else if (wgpu_bench) .wgpu else if (vulkan_bench) .vulkan_descriptor_buffer else .gl;
const Context = harness.contextFor(variant);
var native_context: *Context = undefined;
export fn bench_host_wait(id: u64) u32 {
    return if (wgpu_bench) @intFromBool(native_context.waitFuture(id)) else 0;
}
const Mode = enum { c, raw, public };
const Workload = enum { draws, churn, upload, readback };
const positions = [_]f32{ -1, -1, 3, -1, -1, 3 };
const colors = [2][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 } };
var diagnostics: u32 = 0;
var gl_options: gpu.BackendOptions.GlOptions = undefined;

fn publicLog(diagnostic: gpu.Diagnostic) void {
    if (diagnostic.level == .err or diagnostic.level == .panic) {
        diagnostics += 1;
        std.debug.print("benchmark diagnostic: {s}\n", .{diagnostic.message orelse @tagName(diagnostic.item)});
    }
}
fn rawLog(_: ?[*:0]const u8, level: u32, _: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    if (level <= 1) {
        diagnostics += 1;
        std.debug.print("benchmark diagnostic: {s}\n", .{if (message) |text| std.mem.span(text) else "native resource operation failed"});
    }
}
fn cLog(_: [*c]const u8, level: u32, _: u32, message: [*c]const u8, _: u32, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {
    if (level <= 1) {
        diagnostics += 1;
        std.debug.print("C benchmark diagnostic: {s}\n", .{if (message != null) std.mem.span(message) else "native resource operation failed"});
    }
}
fn source(function: gpu.ShaderFunction) raw.ShaderFunction {
    return switch (function.code) {
        .source => |text| .{ .source = text.ptr, .entry = if (function.entry) |entry| entry.ptr else null, .d3d11_target = if (function.d3d_target) |target| target.ptr else null },
        .bytecode => |bytes| .{ .bytecode = .{ .ptr = bytes.ptr, .size = bytes.len }, .entry = if (function.entry) |entry| entry.ptr else null, .d3d11_target = if (function.d3d_target) |target| target.ptr else null },
    };
}
fn shaderDescriptor(desc: gpu.ShaderDesc) raw.ShaderDesc {
    var result: raw.ShaderDesc = .{ .vertex_func = source(desc.stages.render.vertex), .fragment_func = source(desc.stages.render.fragment) };
    result.attrs[0].glsl_name = "position";
    result.attrs[0].hlsl_sem_name = if (desc.attrs[0].hlsl_semantic) |name| name.ptr else null;
    result.attrs[0].hlsl_sem_index = desc.attrs[0].hlsl_semantic_index;
    const block = desc.uniform_blocks[0];
    result.uniform_blocks[0] = .{ .stage = .fragment, .size = 16, .layout = .std140, .hlsl_register_b_n = block.bindings.hlsl, .msl_buffer_n = block.bindings.msl, .wgsl_group0_binding_n = block.bindings.wgsl, .spirv_set0_binding_n = block.bindings.spirv };
    result.uniform_blocks[0].glsl_uniforms[0] = .{ .type = .float4, .array_count = 1, .glsl_name = "fs_params" };
    return result;
}

const Frontend = struct {
    mode: Mode,
    device: ?gpu.Device = null,
    public_vb: [2]gpu.Buffer = @splat(.invalid),
    public_upload: gpu.Buffer = .invalid,
    public_image: gpu.Image = .invalid,
    public_attachment: gpu.View = .invalid,
    public_pipeline: gpu.Pipeline = .invalid,
    raw_vb: [2]raw.Buffer = @splat(.{}),
    raw_upload: raw.Buffer = .{},
    raw_image: raw.Image = .{},
    raw_attachment: raw.View = .{},
    raw_pipeline: raw.Pipeline = .{},

    fn init(mode: Mode, allocator: std.mem.Allocator, options: gpu.Options, bytes: usize) !Frontend {
        var self: Frontend = .{ .mode = mode };
        const shader_desc = shaders.bench.desc(backend).?;
        var desc: raw.Desc = .{ .environment = .{ .defaults = .{ .color_format = .rgba8, .depth_format = .none } }, .uniform_buffer_size = @intCast(options.uniform_buffer_size), .logger = .{ .func = rawLog } };
        if (vulkan_bench) {
            const vk = options.backend.vulkan;
            desc.environment.vulkan = .{ .instance = vk.instance, .physical_device = vk.physical_device, .device = vk.device, .queue = vk.queue, .queue_family_index = vk.queue_family_index, .get_instance_proc_addr = vk.get_instance_proc_addr };
            desc.vulkan.use_descriptor_buffer = true;
        } else if (wgpu_bench) {
            const wgpu = options.backend.wgpu;
            desc.environment.wgpu = .{ .instance = wgpu.instance, .wait_timeout_ns = wgpu.wait_timeout_ns, .device = wgpu.device, .get_proc_address = wgpu.get_proc_address, .user_data = wgpu.user_data };
        } else if (d3d11_bench) {
            const d3d = options.backend.d3d11;
            desc.environment.d3d11 = .{ .device = d3d.device, .device_context = d3d.device_context };
        } else if (metal_bench) {
            desc.environment.metal = .{ .device = options.backend.metal.device };
        } else desc.environment.gl = .{ .get_proc_address = gl_options.get_proc_address, .user_data = gl_options.user_data };
        switch (mode) {
            .c => {
                var c_desc = toC(c.sg_desc, desc);
                c_desc.logger.func = cLog;
                const c_shader = toC(c.sg_shader_desc, shaderDescriptor(shader_desc));
                if (!c.bench_ref_setup(&c_desc, &c_shader, &positions, bytes)) return error.CReferenceInitFailed;
            },
            .raw => {
                try raw.setup(allocator, if (metal_bench) .metal else if (d3d11_bench) .d3d11 else if (wgpu_bench) .wgpu else if (vulkan_bench) .vulkan else .glcore, desc);
                errdefer raw.shutdown();
                raw.disableStats();
                for (&self.raw_vb) |*buffer| buffer.* = raw.makeBuffer(.{ .data = .{ .ptr = &positions, .size = @sizeOf(@TypeOf(positions)) }, .usage = .{ .vertex_buffer = true } });
                self.raw_upload = raw.makeBuffer(.{ .size = bytes, .usage = .{ .vertex_buffer = true, .copy_src = true, .write_transient = true } });
                self.raw_image = raw.makeImage(.{ .width = 1, .height = 1, .pixel_format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
                self.raw_attachment = raw.makeView(.{ .color_attachment = .{ .image = self.raw_image } });
                const shader = raw.makeShader(shaderDescriptor(shader_desc));
                var pipeline: raw.PipelineDesc = .{ .shader = shader, .depth = .{ .pixel_format = .none } };
                pipeline.layout.attrs[0].format = .float2;
                pipeline.colors[0].pixel_format = .rgba8;
                self.raw_pipeline = raw.makePipeline(pipeline);
                if (raw.queryPipelineState(self.raw_pipeline) != .valid or raw.queryBufferState(self.raw_upload) != .valid) return error.RawInitFailed;
            },
            .public => {
                self.device = try gpu.Device.init(allocator, options);
                errdefer self.device.?.deinit();
                const device = &self.device.?;
                device.setStatsEnabled(false);
                for (&self.public_vb) |*buffer| buffer.* = try device.createBuffer(.{ .data = std.mem.sliceAsBytes(&positions), .usage = .{ .vertex = true } });
                self.public_upload = try device.createBuffer(.{ .size = @intCast(bytes), .usage = .{ .vertex = true, .copy_src = true, .writes = .transient } });
                self.public_image = try device.createImage(.{ .width = 1, .height = 1, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
                self.public_attachment = try device.createView(.{ .color_attachment = .{ .image = self.public_image } });
                const shader = try device.createShader(shader_desc);
                self.public_pipeline = try device.createPipeline(.{ .shader = shader, .vertex_attrs = &.{.{ .format = .float2 }}, .colors = &.{.{ .format = .rgba8 }}, .depth = .{ .format = .none } });
            },
        }
        return self;
    }
    fn deinit(self: *Frontend) void {
        switch (self.mode) {
            .c => c.bench_ref_shutdown(),
            .raw => raw.shutdown(),
            .public => self.device.?.deinit(),
        }
    }
    fn rawPass(self: *Frontend) raw.Pass {
        var pass: raw.Pass = .{};
        pass.attachments.colors[0] = self.raw_attachment;
        pass.action.colors[0] = .{ .load_action = .clear, .clear_value = .{ .a = 1 } };
        return pass;
    }
    fn publicPass(self: *Frontend) gpu.Pass {
        return self.device.?.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{self.public_attachment} } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 1 } } }} });
    }
    fn draws(self: *Frontend, count: usize) void {
        switch (self.mode) {
            .c => c.bench_ref_draws(@intCast(count), @ptrCast(&colors)),
            .raw => {
                raw.beginPass(self.rawPass());
                raw.applyPipeline(self.raw_pipeline);
                for (0..count) |i| {
                    var bindings: raw.Bindings = .{};
                    bindings.vertex_buffers[0] = self.raw_vb[i & 1];
                    raw.applyBindings(bindings);
                    raw.applyUniforms(0, .{ .ptr = &colors[i & 1], .size = 16 });
                    raw.draw(0, 3, 1);
                }
                raw.endPass();
                raw.commit();
            },
            .public => {
                var pass = self.publicPass();
                pass.setPipeline(self.public_pipeline);
                for (0..count) |i| {
                    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = self.public_vb[i & 1] }} });
                    pass.setUniforms(0, &colors[i & 1]);
                    pass.draw(.{ .count = 3 });
                }
                pass.end();
                self.device.?.commit();
            },
        }
    }
    fn churn(self: *Frontend, count: usize) !void {
        if (self.mode == .c) {
            if (!c.bench_ref_churn(@intCast(count))) return error.ResourceCreationFailed;
            return;
        }
        for (0..count) |i| {
            if (self.mode == .raw) {
                const buffer = raw.makeBuffer(.{ .size = 4096, .usage = .{ .vertex_buffer = true, .write_transient = true } });
                if (raw.queryBufferState(buffer) != .valid) return error.ResourceCreationFailed;
                raw.destroyBuffer(buffer);
            } else {
                const buffer = try self.device.?.createBuffer(.{ .size = 4096, .usage = .{ .vertex = true, .writes = .transient } });
                self.device.?.destroy(buffer);
            }
            if (i & 63 == 63 or i + 1 == count) {
                if (self.mode == .raw) {
                    raw.beginPass(self.rawPass());
                    raw.endPass();
                    raw.commit();
                } else {
                    var pass = self.publicPass();
                    pass.end();
                    self.device.?.commit();
                }
            }
        }
    }
    fn upload(self: *Frontend, data: []const u8) void {
        switch (self.mode) {
            .c => c.bench_ref_upload(data.ptr, data.len),
            .raw => {
                raw.writeBufferTransient(.{ .src = .{ .data = .{ .ptr = data.ptr, .size = data.len } }, .dst = .{ .buffer = self.raw_upload } });
                raw.commit();
            },
            .public => {
                self.device.?.writeBuffer(self.public_upload, 0, data);
                self.device.?.commit();
            },
        }
    }
    fn read(self: *Frontend, data: []u8) !void {
        switch (self.mode) {
            .c => if (!c.bench_ref_read(data.ptr, data.len)) return error.CReadbackFailed,
            .raw => if (!raw.readBuffer(self.raw_upload, 0, data)) return error.RawReadbackFailed,
            .public => try self.device.?.readBuffer(self.public_upload, 0, data),
        }
    }
    fn drain(self: *Frontend) !void {
        if (comptime @hasDecl(Context, "drain")) {
            native_context.drain();
        } else {
            // D3D11/Metal expose different frontend command queues. An equal
            // four-byte native read waits for the producing queue in each mode.
            var scratch: [4]u8 = undefined;
            try self.read(&scratch);
        }
    }
    fn pixel(self: *Frontend) ![4]u8 {
        var rgba: [4]u8 = undefined;
        switch (self.mode) {
            .c => if (!c.bench_ref_pixel(&rgba)) return error.CReadbackFailed,
            .raw => if (!raw.readImage(.{ .image = self.raw_image }, &rgba)) return error.RawReadbackFailed,
            .public => try self.device.?.readImage(self.public_image, .{}, &rgba, .{}),
        }
        return rgba;
    }
};

const Result = struct { workload: Workload, operations: usize, bytes: usize, samples_ns: []u64 };
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var mode: Mode = .public;
    var draws: usize = 10000;
    var resources: usize = 1000;
    var bytes: usize = 4 * 1024 * 1024;
    var samples: usize = 9;
    var warmup: usize = 3;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingArgument;
        const key = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--mode")) mode = std.meta.stringToEnum(Mode, value) orelse return error.UnknownMode else if (std.mem.eql(u8, key, "--draws")) draws = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--resources")) resources = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--bytes")) bytes = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--samples")) samples = try std.fmt.parseInt(usize, value, 10) else if (std.mem.eql(u8, key, "--warmup")) warmup = try std.fmt.parseInt(usize, value, 10) else return error.UnknownArgument;
    }
    if (draws == 0 or draws > 100000 or resources == 0 or resources > 100000 or bytes == 0 or bytes > 64 * 1024 * 1024 or samples == 0 or samples > 100 or warmup > 100) return error.InvalidWorkloadSize;
    const context = try Context.createBenchmark(init.gpa, variant);
    defer context.destroy();
    native_context = context;
    if (context.validationAvailable()) return error.NativeValidationEnabledInBenchmark;
    var options = context.options();
    options.validation = .off;
    options.diagnostics = publicLog;
    options.defaults = .{ .color_format = .rgba8, .depth_format = .none };
    options.uniform_buffer_size = @intCast(draws * 256 + 4096);
    if (!vulkan_bench and !wgpu_bench and !d3d11_bench and !metal_bench) gl_options = options.backend.gl;
    var frontend = try Frontend.init(mode, init.gpa, options, bytes);
    var frontend_live = true;
    defer if (frontend_live) frontend.deinit();
    const input = try allocator.alloc(u8, bytes);
    const output = try allocator.alloc(u8, bytes);
    for (input, 0..) |*byte, index| byte.* = @truncate(index *% 73 +% 19);
    var results: [4]Result = undefined;
    inline for ([_]Workload{ .draws, .churn, .upload, .readback }, 0..) |workload, index| {
        const times = try allocator.alloc(u64, samples);
        for (0..warmup + samples) |iteration| {
            if (workload == .readback) frontend.upload(input);
            try frontend.drain();
            const start = std.Io.Clock.awake.now(init.io).nanoseconds;
            switch (workload) {
                .draws => frontend.draws(draws),
                .churn => try frontend.churn(resources),
                .upload => frontend.upload(input),
                .readback => try frontend.read(output),
            }
            const end = std.Io.Clock.awake.now(init.io).nanoseconds;
            if (iteration >= warmup) times[iteration - warmup] = @intCast(end - start);
            // Validate outside the timed interval, and finish before the next sample.
            if (workload == .draws or workload == .churn) {
                const pixel = try frontend.pixel();
                const want: [4]u8 = if (workload == .churn) .{ 0, 0, 0, 255 } else if ((draws - 1) & 1 == 0) .{ 255, 0, 0, 255 } else .{ 0, 255, 0, 255 };
                if (!std.mem.eql(u8, &pixel, &want)) {
                    std.debug.print("pixel {any}, expected {any}\n", .{ pixel, want });
                    return error.IncorrectPixels;
                }
            } else {
                if (workload == .upload) try frontend.read(output);
                if (!std.mem.eql(u8, input, output)) return error.IncorrectUploadData;
            }
            try frontend.drain();
            if (diagnostics != 0 or context.takeNativeErrors() != 0) return error.NativeDiagnostic;
        }
        results[index] = .{ .workload = workload, .operations = if (workload == .draws) draws else if (workload == .churn) resources else 1, .bytes = if (workload == .upload or workload == .readback) bytes else 0, .samples_ns = times };
    }
    frontend.deinit();
    frontend_live = false;
    if (comptime @hasDecl(Context, "drain")) context.drain();
    if (diagnostics != 0 or context.takeNativeErrors() != 0) return error.TeardownDiagnostic;
    var json: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(.{ .schema = @as(u32, 1), .backend = @tagName(backend), .mode = mode, .adapter = context.description(), .zig = @import("builtin").zig_version_string, .optimize = @tagName(@import("builtin").mode), .c_compiler = std.mem.span(c.bench_ref_compiler()), .cpu = @import("builtin").cpu.model.name, .validation = false, .statistics = false, .allocator = "std.process.Init.gpa", .warmup = warmup, .results = results }, .{ .whitespace = .indent_2 }, &json.writer);
    try json.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(init.io, json.written());
}
