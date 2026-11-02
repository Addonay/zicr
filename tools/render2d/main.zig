//! Public renderer acceptance example: ordered alpha, nested clipping and atlas UVs.
const std = @import("std");
const zicr = @import("zicr");
const gpu = zicr.gpu;
const r2 = zicr.render2d;
const shaders = @import("renderer_shaders");
const harness = @import("harness");
var diagnostics: u32 = 0;
var legacy_gl = false;
fn shader(dev: *gpu.Device) !gpu.ShaderDesc {
    return if (legacy_gl) shaders.quad.glsl330 else shaders.quad.desc(dev.backend()) orelse error.NoShader;
}
fn diagnostic(d: gpu.Diagnostic) void {
    if (d.level == .err or d.level == .panic) {
        diagnostics += 1;
        std.debug.print("GPU diagnostic: {s}\n", .{@tagName(d.item)});
    }
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const variant = if (args.len > 1) std.meta.stringToEnum(harness.Variant, args[1]) orelse return error.UnknownBackend else .gl;
    switch (variant) {
        inline else => |v| {
            const Context = harness.contextFor(v);
            legacy_gl = v == .gl_legacy;
            if (Context == void) return error.BackendUnavailable;
            const bench = @import("render2d_options").benchmark or (args.len > 2 and std.mem.eql(u8, args[2], "--bench"));
            const windowed = !bench and args.len > 2 and std.mem.eql(u8, args[2], "--window");
            const ctx = if (windowed) blk: {
                if (comptime @hasDecl(Context, "createWindow")) break :blk try Context.createWindow(init.gpa, v);
                return error.WindowUnavailable;
            } else if (bench) blk: {
                if (comptime @hasDecl(Context, "createBenchmark")) break :blk try Context.createBenchmark(init.gpa, v);
                break :blk try Context.create(init.gpa, v);
            } else try Context.create(init.gpa, v);
            defer ctx.destroy();
            if (bench) std.debug.print("benchmark adapter: {s}\n", .{ctx.description()});
            var options = ctx.options();
            if (bench) {
                options.validation = .off;
                if (options.backend == .vulkan) options.backend.vulkan.descriptor_set_capacity = 12000;
            }
            options.diagnostics = diagnostic;
            var tracked = std.testing.FailingAllocator.init(init.gpa, .{});
            {
                var dev = try gpu.Device.init(tracked.allocator(), options);
                defer dev.deinit();
                if (bench) {
                    dev.setStatsEnabled(false);
                    try benchmark(init, &dev, &tracked);
                } else if (windowed) {
                    try window(Context, ctx, init.gpa, &dev);
                } else if (args.len == 4 and std.mem.eql(u8, args[2], "--stroke-reference")) {
                    try @import("stroke_reference.zig").run(init.gpa, init.io, &dev, try shader(&dev), args[3]);
                } else try run(init.gpa, &dev);
            }
            if (diagnostics != 0 or ctx.takeNativeErrors() != 0) return error.ValidationFailed;
            std.debug.print("render2d {s} {s}: passed\n", .{ @tagName(v), if (bench) "benchmark" else if (windowed) "window" else "pixel acceptance" });
        },
    }
}
fn run(allocator: std.mem.Allocator, dev: *gpu.Device) !void {
    var renderer = try r2.Renderer.init(dev, try shader(dev), .{ .max_quads = 8 });
    defer renderer.deinit();
    var list = try r2.DrawList.init(allocator, .{ .max_quads = 8 });
    defer list.deinit();
    // Two atlas cells: opaque yellow, transparent red. Nearest sampling makes
    // the expected result independent of texture interpolation at cell edges.
    const texels = [_]u8{ 255, 255, 0, 255, 255, 0, 0, 0 };
    const atlas = try dev.createImage(.{ .width = 2, .height = 1, .format = .rgba8, .data = &.{&texels} });
    defer dev.destroy(atlas);
    const sampled = try dev.createView(.{ .texture = .{ .image = atlas } });
    defer dev.destroy(sampled);
    for ([_]u32{ 64, 32, 64 }) |size| {
        const target = try dev.createImage(.{ .width = size, .height = size, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
        defer dev.destroy(target);
        const attachment = try dev.createView(.{ .color_attachment = .{ .image = target } });
        defer dev.destroy(attachment);
        // Fixed logical world demonstrates resize independently of geometry.
        try list.reset(@intCast(size), @intCast(size), .{ .width = 64, .height = 64 });
        try list.rect(.{ .width = 64, .height = 64 }, .{ .r = 0, .g = 0, .b = 1 });
        try list.rect(.{ .width = 32, .height = 64 }, .{ .r = 1, .g = 0, .b = 0, .a = 0.5 });
        try list.pushClip(.{ .x = @intCast(size / 4), .y = @intCast(size / 4), .width = @intCast(size / 2), .height = @intCast(size / 2) });
        try list.pushClip(.{ .width = @intCast(size / 2), .height = @intCast(size / 2) });
        try list.rect(.{ .width = 64, .height = 64 }, .{ .r = 0, .g = 1, .b = 0 });
        try list.popClip();
        try list.popClip();
        try list.quad(.{ .rect = .{ .x = 32, .width = 32, .height = 32 }, .uv = .{ .width = 0.5, .height = 1 }, .texture = .{ .view = sampled } });
        // Transparent red must not introduce a red fringe or replace blue.
        try list.quad(.{ .rect = .{ .x = 32, .y = 32, .width = 32, .height = 32 }, .uv = .{ .x = 0.5, .width = 0.5, .height = 1 }, .texture = .{ .view = sampled } });
        const pass: gpu.PassDesc = .{ .target = .{ .attachments = .{ .colors = &.{attachment} } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 0 } } }} };
        try renderer.submit(&list, pass);
        if (renderer.submit(&list, pass)) |_| return error.DuplicateSubmissionAccepted else |err| if (err != error.AlreadySubmitted) return err;
        dev.commit();
        const pixels = try allocator.alloc(u8, @as(usize, size) * size * 4);
        defer allocator.free(pixels);
        try dev.readImage(target, .{}, pixels, .{});
        for (0..size) |y| for (0..size) |x| {
            const expected: [4]u8 = if (x >= size / 2 and y < size / 2) .{ 255, 255, 0, 255 } else if (x >= size / 4 and x < size / 2 and y >= size / 4 and y < size / 2) .{ 0, 255, 0, 255 } else if (x < size / 2) .{ 128, 0, 128, 255 } else .{ 0, 0, 255, 255 };
            const read_y = if (dev.features().origin_top_left) y else size - 1 - y;
            const offset = (read_y * size + x) * 4;
            for (expected, pixels[offset..][0..4]) |want, got| {
                if (@abs(@as(i32, want) - @as(i32, got)) > 1) {
                    std.debug.print("pixel ({d},{d}) size {d}: expected {any}, got {any}\n", .{ x, y, size, expected, pixels[offset..][0..4] });
                    return error.PixelMismatch;
                }
            }
        };
    }
    try offscreen(allocator, dev, &renderer);
}

fn offscreen(allocator: std.mem.Allocator, dev: *gpu.Device, consumer: *r2.Renderer) !void {
    var producer = try r2.Renderer.init(dev, try shader(dev), .{ .max_quads = 2 });
    defer producer.deinit();
    var draws = try r2.DrawList.init(allocator, .{ .max_quads = 2 });
    defer draws.deinit();
    const image = try dev.createImage(.{ .width = 16, .height = 16, .format = .rgba8, .usage = .{ .color_attachment = true } });
    defer dev.destroy(image);
    const attachment = try dev.createView(.{ .color_attachment = .{ .image = image } });
    defer dev.destroy(attachment);
    const texture = try dev.createView(.{ .texture = .{ .image = image } });
    defer dev.destroy(texture);
    const output = try dev.createImage(.{ .width = 16, .height = 16, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    defer dev.destroy(output);
    const output_view = try dev.createView(.{ .color_attachment = .{ .image = output } });
    defer dev.destroy(output_view);
    try draws.reset(16, 16, null);
    try draws.rect(.{ .width = 16, .height = 8 }, .{ .r = 1, .g = 0, .b = 0, .a = 0.5 });
    try producer.submit(&draws, .{ .target = .{ .attachments = .{ .colors = &.{attachment} } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 0 } } }} });
    try draws.reset(16, 16, null);
    try draws.quad(.{ .rect = .{ .width = 16, .height = 16 }, .texture = .{ .view = texture, .alpha = .premultiplied, .flip_y = !dev.features().origin_top_left } });
    try consumer.submit(&draws, .{ .target = .{ .attachments = .{ .colors = &.{output_view} } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 1, 1 } } }} });
    dev.commit();
    var pixels: [16 * 16 * 4]u8 = undefined;
    try dev.readImage(output, .{}, &pixels, .{});
    for (0..16) |y| for (0..16) |x| {
        const row = if (dev.features().origin_top_left) y else 15 - y;
        const got = pixels[(row * 16 + x) * 4 ..][0..4];
        const expected: [4]u8 = if (y < 8) .{ 128, 0, 127, 255 } else .{ 0, 0, 255, 255 };
        for (got, expected) |a, b| if (@abs(@as(i32, a) - @as(i32, b)) > 1) return error.OffscreenCompositionMismatch;
    };
}

fn window(comptime Context: type, ctx: *Context, allocator: std.mem.Allocator, dev: *gpu.Device) !void {
    if (comptime !@hasDecl(Context, "present")) return error.WindowUnavailable;
    var list = try r2.DrawList.init(allocator, .{ .max_quads = 2 });
    defer list.deinit();
    var renderer: ?r2.Renderer = null;
    defer if (renderer) |*r| r.deinit();
    for (0..32) |frame| {
        const target: gpu.Swapchain = if (comptime @hasDecl(Context, "acquireSwapchain")) try ctx.acquireSwapchain() else .{ .width = 64, .height = 64, .color_format = .rgba8, .depth_format = .none, .native = .{ .gl = .{} } };
        if (renderer == null) renderer = try r2.Renderer.init(dev, try shader(dev), .{ .max_quads = 2, .color_format = target.color_format orelse .rgba8, .depth_format = target.depth_format orelse .none, .sample_count = target.sample_count orelse 1 });
        try list.reset(@intCast(target.width), @intCast(target.height), null);
        try list.rect(.{ .width = @floatFromInt(target.width), .height = @floatFromInt(target.height) }, if (frame & 1 == 0) .{ .r = 1, .g = 0, .b = 0 } else .{ .r = 0, .g = 0, .b = 1 });
        try list.quad(.{ .rect = .{ .width = 8, .height = 8 }, .transform = .{ .tx = @floatFromInt(frame % 16), .ty = 4 }, .tint = .{ .r = 0, .g = 1, .b = 0 } });
        try renderer.?.submit(&list, .{ .target = .{ .swapchain = target }, .colors = &.{.{ .load = .dont_care }} });
        dev.commit();
        if (comptime @hasDecl(Context, "verifyWindow")) if (frame == 31) try ctx.verifyWindow(dev);
        try ctx.present(frame == 31);
    }
    std.debug.print("render2d window: 32 submitted frames, final blue pixel verified\n", .{});
}

fn benchmark(init: std.process.Init, dev: *gpu.Device, tracked: *std.testing.FailingAllocator) !void {
    const count = 10000;
    var renderer = try r2.Renderer.init(dev, try shader(dev), .{ .max_quads = count });
    defer renderer.deinit();
    var cpu = std.testing.FailingAllocator.init(init.gpa, .{});
    var list = try r2.DrawList.init(cpu.allocator(), .{ .max_quads = count });
    defer list.deinit();
    const samplers = [2]gpu.Sampler{ try dev.createSampler(.{}), try dev.createSampler(.{ .min_filter = .linear, .mag_filter = .linear }) };
    defer for (samplers) |sampler| dev.destroy(sampler);
    const image = try dev.createImage(.{ .width = 128, .height = 128, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    defer dev.destroy(image);
    const view = try dev.createView(.{ .color_attachment = .{ .image = image } });
    defer dev.destroy(view);
    const pass: gpu.PassDesc = .{ .target = .{ .attachments = .{ .colors = &.{view} } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 0 } } }} };
    var pixels: [128 * 128 * 4]u8 = undefined;
    for ([_]bool{ false, true }) |fragmented| {
        var encode: [9]u64 = undefined;
        var submit: [9]u64 = undefined;
        var gpu_allocations: usize = 0;
        const cpu_before = cpu.allocations;
        for (0..12) |sample| {
            const alloc_before = tracked.allocations;
            const start = std.Io.Clock.awake.now(init.io).nanoseconds;
            try list.reset(128, 128, null);
            for (0..count) |i| {
                const x = i % 100;
                const y = i / 100;
                try list.quad(.{ .rect = .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = 1, .height = 1 }, .tint = .{ .r = @floatFromInt(x % 2), .g = @floatFromInt(y % 2), .b = 0.25 }, .texture = .{ .sampler = if (fragmented) samplers[i % 2] else .invalid } });
            }
            const encoded = std.Io.Clock.awake.now(init.io).nanoseconds;
            try renderer.submit(&list, pass);
            dev.commit();
            const end = std.Io.Clock.awake.now(init.io).nanoseconds;
            if (sample >= 3) {
                encode[sample - 3] = @intCast(encoded - start);
                submit[sample - 3] = @intCast(end - encoded);
                gpu_allocations += tracked.allocations - alloc_before;
            }
            // Drain and verify every pixel outside the timed region. No GPU
            // backlog can accumulate across samples. Readback cost is excluded.
            try dev.readImage(image, .{}, &pixels, .{});
            for (0..128) |y| for (0..128) |x| {
                const row = if (dev.features().origin_top_left) y else 127 - y;
                const expected: [4]u8 = if (x < 100 and y < 100) .{ @as(u8, @intCast(x % 2)) * 255, @as(u8, @intCast(y % 2)) * 255, 64, 255 } else .{ 0, 0, 0, 0 };
                const got = pixels[(row * 128 + x) * 4 ..][0..4];
                for (got, expected) |a, b| if (@abs(@as(i32, a) - @as(i32, b)) > 1) return error.BenchmarkOutputMismatch;
            };
        }
        if (cpu.allocations != cpu_before) return error.SteadyStateCpuAllocation;
        std.debug.print("{{\"backend\":\"{s}\",\"workload\":\"{s}\",\"quads\":10000,\"batches\":{d},\"upload_bytes\":{d},\"cpu_allocations\":0,\"gpu_allocator_calls\":{d},\"encode_ns\":[", .{ @tagName(dev.backend()), if (fragmented) "fragmented" else "batched", renderer.stats.batches, renderer.stats.upload_bytes, gpu_allocations });
        for (encode, 0..) |ns, i| std.debug.print("{s}{d}", .{ if (i == 0) "" else ",", ns });
        std.debug.print("],\"submit_commit_ns\":[", .{});
        for (submit, 0..) |ns, i| std.debug.print("{s}{d}", .{ if (i == 0) "" else ",", ns });
        std.debug.print("]}}\n", .{});
    }
}
