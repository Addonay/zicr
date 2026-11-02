//! Minimal runtime-loaded X11 window for presentation smoke tests. No dependency
//! on a user's desktop: CI runs this host against its own Xvfb display.
const std = @import("std");
pub const Window = struct {
    library: std.DynLib,
    display: *anyopaque,
    handle: c_ulong,
    visual_id: c_ulong,
    close_display: *const fn (*anyopaque) callconv(.c) c_int,
    destroy_window: *const fn (*anyopaque, c_ulong) callconv(.c) c_int,
    pub fn create() !Window {
        var library = try std.DynLib.open("libX11.so.6");
        errdefer library.close();
        const open = library.lookup(*const fn (?[*:0]const u8) callconv(.c) ?*anyopaque, "XOpenDisplay") orelse return error.MissingX11Function;
        const close = library.lookup(*const fn (*anyopaque) callconv(.c) c_int, "XCloseDisplay") orelse return error.MissingX11Function;
        const screen = library.lookup(*const fn (*anyopaque) callconv(.c) c_int, "XDefaultScreen") orelse return error.MissingX11Function;
        const root = library.lookup(*const fn (*anyopaque, c_int) callconv(.c) c_ulong, "XRootWindow") orelse return error.MissingX11Function;
        const visual = library.lookup(*const fn (*anyopaque, c_int) callconv(.c) *anyopaque, "XDefaultVisual") orelse return error.MissingX11Function;
        const visual_id = library.lookup(*const fn (*anyopaque) callconv(.c) c_ulong, "XVisualIDFromVisual") orelse return error.MissingX11Function;
        const create_window = library.lookup(*const fn (*anyopaque, c_ulong, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) c_ulong, "XCreateSimpleWindow") orelse return error.MissingX11Function;
        const destroy = library.lookup(*const fn (*anyopaque, c_ulong) callconv(.c) c_int, "XDestroyWindow") orelse return error.MissingX11Function;
        const map = library.lookup(*const fn (*anyopaque, c_ulong) callconv(.c) c_int, "XMapWindow") orelse return error.MissingX11Function;
        const sync = library.lookup(*const fn (*anyopaque, c_int) callconv(.c) c_int, "XSync") orelse return error.MissingX11Function;
        const display = open(null) orelse return error.NoX11Display;
        errdefer _ = close(display);
        const index = screen(display);
        const handle = create_window(display, root(display, index), 0, 0, 64, 64, 0, 0, 0);
        if (handle == 0) return error.X11WindowCreationFailed;
        _ = map(display, handle);
        _ = sync(display, 0);
        return .{ .library = library, .display = display, .handle = handle, .visual_id = visual_id(visual(display, index)), .close_display = close, .destroy_window = destroy };
    }
    pub fn deinit(self: *Window) void {
        _ = self.destroy_window(self.display, self.handle);
        _ = self.close_display(self.display);
        self.library.close();
    }
};
