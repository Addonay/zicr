//! Forces semantic analysis of the Metal backend for Apple targets.
const std = @import("std");
const gfx = @import("zicr").gpu.raw;

/// The default std panic handler does not build for iOS in Zig 0.17.
pub const panic = std.debug.no_panic;
pub const std_options: std.Options = .{ .logFn = discardLog };
fn discardLog(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    _ = .{ level, scope, format, args };
}

var memory: [1 << 20]u8 = undefined;

export fn sokolGfxMetalCheck(device: ?*const anyopaque) void {
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    gfx.setup(fba.allocator(), .metal_macos, .{ .environment = .{ .metal = .{ .device = device } } }) catch return;
    defer gfx.shutdown();
    gfx.beginPass(.{ .swapchain = .{ .width = 1, .height = 1 } });
    gfx.endPass();
    gfx.commit();
}

/// Force both synchronous and asynchronous readback bodies on real Apple ABIs.
export fn zicrMetalReadbackCheck(native_device: ?*const anyopaque) void {
    const gpu = @import("zicr").gpu;
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    var device = gpu.Device.init(fba.allocator(), .{ .backend = .{ .metal = .{ .device = native_device orelse return } } }) catch return;
    defer device.deinit();
    const bytes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    const buffer = device.createBuffer(.{ .usage = .{ .copy_src = true }, .data = &bytes }) catch return;
    var output: [7]u8 = undefined;
    device.readBuffer(buffer, 3, &output) catch {};
    var ticket = device.requestReadBuffer(buffer, 12, 1) catch return;
    _ = ticket.poll() catch null;
    ticket.deinit();
    const image = device.createImage(.{ .width = 4, .height = 4, .usage = .{ .color_attachment = true, .copy_src = true } }) catch return;
    var image_output: [64]u8 = undefined;
    device.readImage(image, .{}, &image_output, .{}) catch {};
    var pixels = device.requestReadImage(image, .{}, .{}) catch return;
    _ = pixels.poll() catch null;
    pixels.deinit();
}

/// x86_64 aggregate returns must use objc_msgSend_stret, ARM64 uses x8.
export fn zicrMetalAggregateAbiCheck(object: ?*anyopaque) usize {
    const sdk = gfx.native.metal;
    const size = sdk.msg(sdk.Size, object, "maxThreadsPerThreadgroup", .{});
    return size.width;
}

export fn zicrMetalHostCheck() void {
    const harness = @import("harness");
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    const allocator = fba.allocator();
    const context = harness.metal.Context.create(allocator, .metal) catch return;
    defer context.destroy();
    _ = context.validationAvailable();
    var device = @import("zicr").gpu.Device.init(allocator, context.options()) catch return;
    defer device.deinit();
    _ = device.status();
}

var scene_memory: [64 * 1024 * 1024]u8 = undefined;
/// Force the complete shared scene suite on each Apple ABI, without claiming
/// execution or requiring Apple framework linking on the cross-build host.
export fn zicrMetalSceneCheck(native_device: ?*const anyopaque) void {
    const gpu = @import("zicr").gpu;
    const scenes = @import("scenes");
    var fba: std.heap.FixedBufferAllocator = .init(&scene_memory);
    const options: gpu.Options = .{ .backend = .{ .metal = .{
        .device = native_device orelse return,
        .platform = if (@import("builtin").os.tag == .macos) .macos else .ios,
    } } };
    var device = gpu.Device.init(fba.allocator(), options) catch return;
    defer device.deinit();
    for (scenes.all) |scene| {
        var env: scenes.Env = .{ .dev = &device, .allocator = fba.allocator(), .native_options = options, .prefer_async = true };
        scene.run(&env) catch {};
    }
}

/// Force native macOS window/drawable ABI analysis without claiming execution.
export fn zicrMetalWindowCheck() void {
    if (@import("builtin").os.tag != .macos) return;
    const harness = @import("harness");
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    const context = harness.metal.Context.createWindow(fba.allocator(), .metal) catch return;
    defer context.destroy();
    var device = @import("zicr").gpu.Device.init(fba.allocator(), context.options()) catch return;
    defer device.deinit();
    const swapchain = context.acquireSwapchain() catch return;
    var pass = device.beginPass(.{ .target = .{ .swapchain = swapchain } });
    pass.end();
    device.commit();
    context.verifyWindow(&device) catch {};
    context.present(true) catch {};
}
