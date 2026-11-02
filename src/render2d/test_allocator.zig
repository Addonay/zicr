//! Failure-injection backing allocator: forbid in-place resizing/remapping so
//! allocation counts cannot depend on the debug allocator's current page layout.
const std = @import("std");
pub fn noResize(backing: *std.mem.Allocator) std.mem.Allocator {
    return .{ .ptr = backing, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}
fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
    const backing: *std.mem.Allocator = @ptrCast(@alignCast(context));
    return backing.rawAlloc(length, alignment, address);
}
fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}
fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
    return null;
}
fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
    const backing: *std.mem.Allocator = @ptrCast(@alignCast(context));
    backing.rawFree(memory, alignment, address);
}
