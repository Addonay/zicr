//! Forces semantic analysis of the Metal backend for Apple targets.
const std = @import("std");
const gfx = @import("sokol_gfx");

/// The default std panic handler does not build for iOS in Zig 0.17.
pub const panic = std.debug.no_panic;

var memory: [1 << 20]u8 = undefined;

export fn sokolGfxMetalCheck(device: ?*const anyopaque) void {
    var fba: std.heap.FixedBufferAllocator = .init(&memory);
    gfx.setup(fba.allocator(), .metal_macos, .{ .environment = .{ .metal = .{ .device = device } } }) catch return;
    defer gfx.shutdown();
    gfx.beginPass(.{ .swapchain = .{ .width = 1, .height = 1 } });
    gfx.endPass();
    gfx.commit();
}
