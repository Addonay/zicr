//! Headless device setup for test tools. Every backend module provides a
//! `Context` with this interface:
//!
//! ```zig
//! pub fn create(gpa: std.mem.Allocator, variant: Variant) !*Context
//! pub fn destroy(self: *Context) void
//! pub fn options(self: *Context) gpu.Options // backend and defaults, diagnostics unset
//! pub fn description(self: *Context) []const u8 // driver/adapter name
//! /// Native validation or API errors observed since the last call.
//! pub fn takeNativeErrors(self: *Context) u32
//! ```
const builtin = @import("builtin");

pub const Variant = enum {
    gl,
    gles,
    /// GL 3.3 / GLES 3.0 contexts.
    gl_legacy,
    gles_legacy,
    vulkan,
    wgpu,
    d3d11,
    d3d12,
};

pub const egl = if (builtin.os.tag == .linux) @import("egl.zig") else struct {};
pub const d3d11 = if (builtin.os.tag == .windows) @import("d3d11.zig") else struct {};
pub const wgpu = if (builtin.os.tag == .linux) @import("wgpu.zig") else struct {};
pub const vulkan = if (builtin.os.tag == .linux) @import("vulkan.zig") else struct {};

/// The context type of a variant on the target platform, or void.
pub fn contextFor(comptime variant: Variant) type {
    return switch (variant) {
        .gl, .gles, .gl_legacy, .gles_legacy => if (builtin.os.tag == .linux) egl.Context else void,
        .wgpu => if (builtin.os.tag == .linux) wgpu.Context else void,
        .vulkan => if (builtin.os.tag == .linux) vulkan.Context else void,
        .d3d11 => if (builtin.os.tag == .windows) d3d11.Context else void,
        else => void,
    };
}
