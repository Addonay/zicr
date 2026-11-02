//! Freestanding browser entry point; the browser owns the context and presentation.
const std = @import("std");
const gpu = @import("zicr").gpu;
const r2 = @import("zicr").render2d;
const renderer_shaders = @import("renderer_shaders");
var canvas_renderer: ?r2.Renderer = null;
var canvas_draws: ?r2.DrawList = null;
const scenes = @import("scenes");
const imports = gpu.web;
extern "host" fn log(ptr: [*]const u8, len: usize) void;
var device: gpu.Device = undefined;
var initialized = false;
var errors: u32 = 0;
var first_error: gpu.LogItem = .ok;
var env: scenes.Env = undefined;
pub const std_options: std.Options = .{ .logFn = logFn };
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime fmt: []const u8, args: anytype) void {
    _ = .{ level, scope };
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch &buffer;
    log(message.ptr, message.len);
}
pub const panic = std.debug.FullPanic(struct {
    fn panic(message: []const u8, _: ?usize) noreturn {
        log(message.ptr, message.len);
        @trap();
    }
}.panic);
fn diagnostic(d: gpu.Diagnostic) void {
    if (d.level == .err or d.level == .panic) {
        if (errors == 0) first_error = d.item;
        errors += 1;
        const message = d.message orelse @tagName(d.item);
        log(message.ptr, message.len);
    }
}
export fn wgpu_layout_ptr() [*]const u8 {
    return imports.wgpu_layout.ptr;
}
export fn wgpu_layout_len() usize {
    return imports.wgpu_layout.len;
}
export fn alloc(size: usize) usize {
    const data = std.heap.wasm_allocator.alloc(u8, size) catch return 0;
    return @intFromPtr(data.ptr);
}
export fn free(ptr: usize, size: usize) void {
    std.heap.wasm_allocator.free(@as([*]u8, @ptrFromInt(ptr))[0..size]);
}
export fn mapped_callback(callback: usize, status: u32, user1: usize, user2: usize) void {
    imports.dispatchMapCallback(callback, status, user1, user2);
}
export fn init(backend: u32, native_device: usize) u32 {
    if (initialized) return 1;
    device = gpu.Device.init(std.heap.wasm_allocator, .{
        .backend = if (backend == 0) .{ .gles = .{ .get_proc_address = imports.glProcAddress } } else .{ .wgpu = .{
            .device = @ptrFromInt(native_device),
            .get_proc_address = imports.wgpuProcAddress,
        } },
        .defaults = .{ .color_format = .rgba8, .depth_format = .none },
        .validation = .report,
        .diagnostics = diagnostic,
    }) catch |err| {
        const message = @errorName(err);
        log(message.ptr, message.len);
        return 0;
    };
    async_backend = true;
    initialized = true;
    return 1;
}
export fn shutdown() void {
    clearReads();
    reads.deinit(std.heap.wasm_allocator);
    reads = .empty;
    if (canvas_renderer) |*renderer| renderer.deinit();
    canvas_renderer = null;
    if (canvas_draws) |*draws| draws.deinit();
    canvas_draws = null;
    if (initialized) device.deinit();
    initialized = false;
}
export fn scene_count() u32 {
    return scenes.all.len;
}
export fn scene_name(index: u32) [*]const u8 {
    return scenes.all[index].name.ptr;
}
export fn scene_name_len(index: u32) usize {
    return scenes.all[index].name.len;
}
// The scene suite is deterministic. Replay at readback checkpoints lets its
// existing CPU assertions consume async snapshots without JSPI or blocking wasm.
var async_backend = false;
var active_scene: ?u32 = null;
var reads: std.ArrayList(gpu.Readback) = .empty;
var pending: ?gpu.Readback = null;
var cursor: usize = 0;
fn clearReads() void {
    if (pending) |*ticket| ticket.deinit();
    pending = null;
    for (reads.items) |*ticket| ticket.deinit();
    reads.clearRetainingCapacity();
}
fn cachedRead(out: []u8) !bool {
    defer cursor += 1;
    if (cursor >= reads.items.len) return false;
    const data = (try reads.items[cursor].poll()).?;
    if (data.len > out.len) return error.ReadFailed;
    @memset(out, 0);
    @memcpy(out[0..data.len], data);
    return true;
}
fn readBuffer(dev: *gpu.Device, buffer: gpu.Buffer, offset: usize, out: []u8) !void {
    if (try cachedRead(out)) return;
    pending = try dev.requestReadBuffer(buffer, offset, out.len);
    return error.PendingRead;
}
fn readImage(dev: *gpu.Device, image: gpu.Image, region: gpu.ImageRegion, out: []u8, layout: gpu.DataLayout) !void {
    if (try cachedRead(out)) return;
    pending = try dev.requestReadImage(image, region, layout);
    return error.PendingRead;
}
/// 0 pending, 1 ready, 2 failed. No spinning: JS yields before the next poll.
export fn poll_read() u32 {
    if (pending) |*ticket| {
        _ = (ticket.poll() catch return 2) orelse return 0;
        reads.append(std.heap.wasm_allocator, ticket.*) catch return 2;
        pending = null;
        return 1;
    }
    return 2;
}

/// 0 pass, 1 fail, 2 capability skip, 3 waiting for readback.
export fn run_scene(index: u32) u32 {
    if (!initialized or index >= scenes.all.len) return 1;
    if (active_scene != index) {
        clearReads();
        active_scene = index;
    }
    cursor = 0;
    errors = 0;
    first_error = .ok;
    env = .{ .dev = &device, .allocator = std.heap.wasm_allocator };
    if (async_backend) {
        env.read_buffer = readBuffer;
        env.read_image = readImage;
    }
    scenes.all[index].run(&env) catch |err| {
        if (err == error.PendingRead) return 3;
        clearReads();
        active_scene = null;
        if (err == error.SkipScene) return 2;
        const message = if (err == error.Mismatch) env.failure() else @errorName(err);
        log(message.ptr, message.len);
        return 1;
    };
    clearReads();
    active_scene = null;
    const diagnostics_match = if (env.expected_diagnostic) |expected|
        errors == 1 and first_error == expected
    else
        errors == 0;
    return if (diagnostics_match) 0 else 1;
}
/// The shim builds its extension string table in this persistent scratch area.
var strings: [65536]u8 = undefined;
export fn string_table() [*]u8 {
    return &strings;
}

export fn notify_device_lost(code: i32) void {
    if (initialized) device.notifyLost(code);
}

/// Render into the browser's acquired canvas image, rather than an offscreen
/// library image. JavaScript presents between frames and verifies the last one.
export fn present_frame(frame: u32, native_view: usize) u32 {
    if (!initialized) return 0;
    errors = 0;
    presentRendererFrame(frame, native_view) catch |err| {
        const message = @errorName(err);
        log(message.ptr, message.len);
        return 0;
    };
    return if (errors == 0) 1 else 0;
}

fn presentRendererFrame(frame: u32, native_view: usize) !void {
    if (canvas_renderer == null) canvas_renderer = try r2.Renderer.init(&device, renderer_shaders.quad.desc(device.backend()) orelse return error.NoRendererShader, .{ .max_quads = 2 });
    if (canvas_draws == null) canvas_draws = try r2.DrawList.init(std.heap.wasm_allocator, .{ .max_quads = 2 });
    const draws = &canvas_draws.?;
    try draws.reset(64, 64, null);
    try draws.rect(.{ .width = 64, .height = 64 }, if (frame & 1 == 0) .{ .r = 1, .g = 0, .b = 0 } else .{ .r = 0, .g = 0, .b = 1 });
    try draws.quad(.{ .rect = .{ .width = 8, .height = 8 }, .transform = .{ .tx = @floatFromInt(frame % 16), .ty = 4 }, .tint = .{ .r = 0, .g = 1, .b = 0 } });
    try canvas_renderer.?.submit(draws, .{
        .target = .{ .swapchain = .{ .width = 64, .height = 64, .color_format = .rgba8, .depth_format = .none, .native = if (native_view == 0) .{ .gl = .{} } else .{ .wgpu = .{ .render_view = @ptrFromInt(native_view) } } } },
        .colors = &.{.{ .load = .dont_care, .store = .store }},
    });
    device.commit();
}
