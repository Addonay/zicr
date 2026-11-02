//! Native headless Metal host. Runtime availability and validation are explicit;
//! compiling this harness on Linux does not prove execution on Apple hardware.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");
const sdk = gpu.raw.native.metal;
pub const Context = struct {
    allocator: std.mem.Allocator,
    pool: sdk.AutoreleasePool,
    device: sdk.Id,
    name: []u8,
    window: sdk.Id = null,
    layer: sdk.Id = null,
    drawable: sdk.Id = null,
    frame_pool: ?sdk.AutoreleasePool = null,
    appkit: ?std.DynLib = null,
    quartz: ?std.DynLib = null,
    pub fn create(allocator: std.mem.Allocator, _: harness.Variant) !*Context {
        var pool = sdk.AutoreleasePool.init();
        errdefer pool.deinit();
        const device = sdk.defaultDevice() orelse return error.NoMetalDevice;
        errdefer sdk.release(device);
        const native_name = sdk.msg(sdk.Id, device, "name", .{});
        const utf8 = sdk.msg(?[*:0]const u8, native_name, "UTF8String", .{});
        const name = try allocator.dupe(u8, if (utf8) |ptr| std.mem.span(ptr) else "Metal device");
        errdefer allocator.free(name);
        const self = try allocator.create(Context);
        self.* = .{ .allocator = allocator, .pool = pool, .device = device, .name = name };
        return self;
    }
    /// Native macOS window host; iOS requires an application-owned UIKit host.
    pub fn createBenchmark(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return create(gpa, variant);
    }
    pub fn createWindow(allocator: std.mem.Allocator, variant: harness.Variant) !*Context {
        if (builtin.os.tag != .macos) return error.WindowHostUnavailable;
        const self = try create(allocator, variant);
        errdefer self.destroy();
        self.appkit = try std.DynLib.open("/System/Library/Frameworks/AppKit.framework/AppKit");
        self.quartz = try std.DynLib.open("/System/Library/Frameworks/QuartzCore.framework/QuartzCore");
        const application = sdk.msg(sdk.Id, sdk.cls("NSApplication"), "sharedApplication", .{}) orelse return error.NoApplication;
        _ = sdk.msg(bool, application, "setActivationPolicy:", .{@as(isize, 0)});
        sdk.msg(void, application, "finishLaunching", .{});
        const Rect = extern struct { x: f64, y: f64, width: f64, height: f64 };
        const allocated = sdk.msg(sdk.Id, sdk.cls("NSWindow"), "alloc", .{});
        self.window = sdk.msg(sdk.Id, allocated, "initWithContentRect:styleMask:backing:defer:", .{ Rect{ .x = 0, .y = 0, .width = 64, .height = 64 }, @as(usize, 0), @as(usize, 2), false }) orelse return error.NoWindow;
        sdk.msg(void, self.window, "setReleasedWhenClosed:", .{false});
        const view = sdk.msg(sdk.Id, self.window, "contentView", .{});
        sdk.msg(void, view, "setWantsLayer:", .{true});
        self.layer = sdk.allocInit("CAMetalLayer") orelse return error.NoMetalLayer;
        sdk.msg(void, self.layer, "setDevice:", .{self.device});
        sdk.msg(void, self.layer, "setPixelFormat:", .{@as(usize, 80)}); // BGRA8Unorm
        sdk.msg(void, self.layer, "setFramebufferOnly:", .{false});
        sdk.msg(void, self.layer, "setFrame:", .{Rect{ .x = 0, .y = 0, .width = 64, .height = 64 }});
        sdk.msg(void, self.layer, "setContentsScale:", .{@as(f64, 1)});
        const Size = extern struct { width: f64, height: f64 };
        sdk.msg(void, self.layer, "setDrawableSize:", .{Size{ .width = 64, .height = 64 }});
        sdk.msg(void, view, "setLayer:", .{self.layer});
        sdk.msg(void, self.window, "makeKeyAndOrderFront:", .{@as(sdk.Id, null)});
        sdk.msg(void, application, "activateIgnoringOtherApps:", .{true});
        sdk.msg(void, self.window, "displayIfNeeded", .{});
        sdk.msg(void, sdk.cls("CATransaction"), "flush", .{});
        return self;
    }
    pub fn acquireSwapchain(self: *Context) !gpu.Swapchain {
        sdk.release(self.drawable);
        self.drawable = null;
        if (self.frame_pool) |*pool| pool.deinit();
        self.frame_pool = sdk.AutoreleasePool.init();
        if (self.layer == null) return error.NoWindow;
        self.drawable = sdk.retain(sdk.msg(sdk.Id, self.layer, "nextDrawable", .{})) orelse return error.NoDrawable;
        return .{ .width = 64, .height = 64, .color_format = .bgra8, .depth_format = .none, .native = .{ .metal = .{ .current_drawable = self.drawable.? } } };
    }
    pub fn verifyWindow(self: *Context, device: *gpu.Device) !void {
        const texture = sdk.msg(sdk.Id, self.drawable, "texture", .{}) orelse return error.NoDrawable;
        const image = try device.createImage(.{ .width = 64, .height = 64, .format = .bgra8, .usage = .{ .color_attachment = true, .copy_src = true }, .native = .{ .metal = texture } });
        defer device.destroy(image);
        var pixel: [4]u8 = undefined;
        try device.readImage(image, .{ .x = 32, .y = 32, .width = 1, .height = 1 }, &pixel, .{});
        if (!std.mem.eql(u8, &pixel, &.{ 255, 0, 0, 255 })) return error.PresentationPixelMismatch;
    }
    pub fn present(_: *Context, _: bool) !void {
        // The backend schedules presentDrawable on the producing command buffer.
        // A CLI host still needs to service AppKit/CoreAnimation between frames.
        sdk.msg(void, sdk.cls("CATransaction"), "flush", .{});
        const loop = sdk.msg(sdk.Id, sdk.cls("NSRunLoop"), "currentRunLoop", .{});
        const until = sdk.msg(sdk.Id, sdk.cls("NSDate"), "dateWithTimeIntervalSinceNow:", .{@as(f64, 0.001)});
        sdk.msg(void, loop, "runUntilDate:", .{until});
    }

    pub fn destroy(self: *Context) void {
        sdk.release(self.drawable);
        if (self.frame_pool) |*pool| pool.deinit();
        sdk.release(self.layer);
        if (self.window != null) sdk.msg(void, self.window, "close", .{});
        sdk.release(self.window);
        if (self.quartz) |*library| library.close();
        if (self.appkit) |*library| library.close();
        sdk.release(self.device);
        self.allocator.free(self.name);
        self.pool.deinit();
        self.allocator.destroy(self);
    }
    pub fn options(self: *Context) gpu.Options {
        return .{ .backend = .{ .metal = .{ .device = self.device.?, .platform = if (builtin.os.tag == .macos) .macos else .ios } } };
    }
    pub fn description(self: *Context) []const u8 {
        return self.name;
    }
    /// Metal API validation errors abort the process; command-buffer errors also
    /// set Device.status to lost and fail the scene runner. No fictitious native
    /// callback counter is claimed here.
    pub fn takeNativeErrors(_: *Context) u32 {
        return 0;
    }
    pub fn validationAvailable(_: *Context) bool {
        const layer = std.c.getenv("MTL_DEBUG_LAYER") orelse return false;
        const shaders = std.c.getenv("MTL_SHADER_VALIDATION") orelse return false;
        return std.mem.eql(u8, std.mem.span(layer), "1") and std.mem.eql(u8, std.mem.span(shaders), "1");
    }
};
