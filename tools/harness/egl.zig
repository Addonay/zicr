//! Surfaceless EGL contexts for GL and GLES, through runtime-loaded EGL and GL libraries.
const std = @import("std");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");

const XWindow = @import("x11.zig").Window;

const Egl = struct {
    library: std.DynLib,
    get_platform_display: *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque,
    initialize: *const fn (?*anyopaque, ?*i32, ?*i32) callconv(.c) u32,
    choose_config: *const fn (?*anyopaque, ?[*]const i32, ?[*]?*anyopaque, i32, ?*i32) callconv(.c) u32,
    bind_api: *const fn (u32) callconv(.c) u32,
    create_context: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque,
    create_surface: *const fn (?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque,
    make_current: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32,
    destroy_context: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u32,
    destroy_surface: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u32,
    terminate: *const fn (?*anyopaque) callconv(.c) u32,
    get_proc: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,

    fn open() !Egl {
        var library = try std.DynLib.open("libEGL.so.1");
        errdefer library.close();
        var result: Egl = undefined;
        result.library = library;
        const names = .{
            .{ "get_platform_display", "eglGetPlatformDisplay" }, .{ "initialize", "eglInitialize" },
            .{ "choose_config", "eglChooseConfig" },              .{ "bind_api", "eglBindAPI" },
            .{ "create_context", "eglCreateContext" },            .{ "create_surface", "eglCreatePbufferSurface" },
            .{ "make_current", "eglMakeCurrent" },                .{ "destroy_context", "eglDestroyContext" },
            .{ "destroy_surface", "eglDestroySurface" },          .{ "terminate", "eglTerminate" },
            .{ "get_proc", "eglGetProcAddress" },
        };
        inline for (names) |entry| @field(result, entry[0]) = library.lookup(@TypeOf(@field(result, entry[0])), entry[1]) orelse return error.MissingEglFunction;
        return result;
    }
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    egl: Egl,
    gl: std.DynLib,
    display: *anyopaque,
    context: *anyopaque,
    surface: *anyopaque,
    gles: bool,
    window: ?XWindow = null,
    get_error: *const fn () callconv(.c) u32,
    version: []const u8,
    native_errors: std.atomic.Value(u32) = .init(0),
    debug_callback: ?DebugCallbackFn = null,
    const DebugCallback = *const fn (u32, u32, u32, u32, i32, [*:0]const u8, ?*anyopaque) callconv(.c) void;
    const DebugCallbackFn = *const fn (?DebugCallback, ?*anyopaque) callconv(.c) void;

    fn debugMessage(_: u32, kind: u32, _: u32, severity: u32, length: i32, message: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
        if (kind != 0x824C and severity != 0x9146 and severity != 0x9147) return;
        const self: *Context = @ptrCast(@alignCast(user.?));
        _ = self.native_errors.fetchAdd(1, .monotonic);
        const text = if (length > 0) message[0..@intCast(length)] else std.mem.span(message);
        std.debug.print("GL validation: {s}\n", .{text});
    }

    pub fn validationAvailable(self: *Context) bool {
        return self.debug_callback != null;
    }

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return createImpl(gpa, variant, true, false);
    }

    /// Benchmarks disable native debug callbacks as well as library validation.
    pub fn createBenchmark(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return createImpl(gpa, variant, false, false);
    }

    pub fn createWindow(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return createImpl(gpa, variant, true, true);
    }

    fn createImpl(gpa: std.mem.Allocator, variant: harness.Variant, validation: bool, windowed: bool) !*Context {
        const gles = variant == .gles or variant == .gles_legacy;
        const legacy = variant == .gl_legacy or variant == .gles_legacy;
        const self = try gpa.create(Context);
        errdefer gpa.destroy(self);
        self.native_errors = .init(0);
        self.debug_callback = null;
        self.window = if (windowed) try XWindow.create() else null;
        errdefer if (self.window) |*window| window.deinit();
        self.gpa = gpa;
        self.gles = gles;
        self.egl = try Egl.open();
        errdefer self.egl.library.close();
        const egl = &self.egl;
        self.display = egl.get_platform_display(if (windowed) 0x31D5 else 0x31DD, if (self.window) |window| window.display else null, null) orelse return error.NoSurfacelessEglDisplay;
        var major: i32 = 0;
        var minor: i32 = 0;
        if (egl.initialize(self.display, &major, &minor) == 0) return error.EglInitializationFailed;
        errdefer _ = egl.terminate(self.display);
        self.gl = try std.DynLib.open(if (gles) "libGLESv2.so.2" else "libGL.so.1");
        errdefer self.gl.close();
        const none = 0x3038;
        const config_attributes = [_]i32{
            0x3033, if (windowed) 4 else 1, // EGL_WINDOW_BIT / EGL_PBUFFER_BIT
            0x3040, if (gles) 0x40 else 8, // EGL_RENDERABLE_TYPE, ES3/OpenGL
            0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, // RGBA
            0x302E, if (self.window) |window| @intCast(window.visual_id) else -1, // EGL_NATIVE_VISUAL_ID / DONT_CARE
            none,
        };
        var config: ?*anyopaque = null;
        var count: i32 = 0;
        if (egl.choose_config(self.display, &config_attributes, @ptrCast(&config), 1, &count) == 0 or count < 1) return error.NoEglConfig;
        if (egl.bind_api(if (gles) 0x30A0 else 0x30A2) == 0) return error.EglBindApiFailed;
        const context_attributes = if (gles)
            [_]i32{ 0x3098, 3, 0x30FB, if (legacy) 0 else 1, 0x31B0, @intFromBool(validation), none, none, none }
        else
            [_]i32{ 0x3098, if (legacy) 3 else 4, 0x30FB, if (legacy) 3 else 6, 0x30FD, 1, 0x31B0, @intFromBool(validation), none };
        var native_context = egl.create_context(self.display, config, null, &context_attributes);
        if (native_context == null and !legacy) {
            var fallback = context_attributes;
            if (gles) {
                fallback[3] = 0; // ES 3.0 still covers the portable graphics path.
                native_context = egl.create_context(self.display, config, null, &fallback);
            } else {
                // Software drivers and macOS-style capability levels need not
                // expose 4.6. Select the best supported graphics/compute context.
                for ([_]i32{ 3, 1 }) |minor_version| {
                    fallback[3] = minor_version;
                    native_context = egl.create_context(self.display, config, null, &fallback);
                    if (native_context != null) break;
                }
            }
        }
        self.context = native_context orelse return error.EglContextCreationFailed;
        errdefer _ = egl.destroy_context(self.display, self.context);
        const surface_attributes = [_]i32{ 0x3057, 16, 0x3056, 16, none };
        self.surface = if (self.window) |window| blk: {
            const create_window = egl.library.lookup(*const fn (?*anyopaque, ?*anyopaque, c_ulong, ?[*]const i32) callconv(.c) ?*anyopaque, "eglCreateWindowSurface") orelse return error.MissingEglFunction;
            break :blk create_window(self.display, config, window.handle, null) orelse return error.EglSurfaceCreationFailed;
        } else egl.create_surface(self.display, config, &surface_attributes) orelse return error.EglSurfaceCreationFailed;
        errdefer _ = egl.destroy_surface(self.display, self.surface);
        if (egl.make_current(self.display, self.surface, self.surface, self.context) == 0) return error.EglMakeCurrentFailed;
        self.get_error = @ptrCast(@alignCast(resolve("glGetError", self) orelse return error.MissingGlFunction));
        const get_string: *const fn (u32) callconv(.c) ?[*:0]const u8 = @ptrCast(@alignCast(resolve("glGetString", self) orelse return error.MissingGlFunction));
        self.version = try std.fmt.allocPrint(gpa, "{s}; {s}", .{ std.mem.span(get_string(0x1F02) orelse "unknown"), std.mem.span(get_string(0x1F01) orelse "unknown renderer") });
        const get_integer: *const fn (u32, *i32) callconv(.c) void = @ptrCast(@alignCast(resolve("glGetIntegerv", self) orelse return error.MissingGlFunction));
        const get_indexed: *const fn (u32, u32) callconv(.c) ?[*:0]const u8 = @ptrCast(@alignCast(resolve("glGetStringi", self) orelse return error.MissingGlFunction));
        var extension_count: i32 = 0;
        get_integer(0x821D, &extension_count);
        var gl_major: i32 = 0;
        var gl_minor: i32 = 0;
        get_integer(0x821B, &gl_major);
        get_integer(0x821C, &gl_minor);
        const gl_version = gl_major * 10 + gl_minor;
        var has_debug = gl_version >= (if (gles) @as(i32, 32) else @as(i32, 43));
        for (0..@intCast(@max(0, extension_count))) |index| {
            const extension = get_indexed(0x1F03, @intCast(index)) orelse continue;
            if (std.mem.eql(u8, std.mem.span(extension), "GL_KHR_debug")) has_debug = true;
        }
        // A resolver may expose unsupported entry points. Require advertised support.
        if (validation and has_debug) {
            const address = if (gles)
                resolve("glDebugMessageCallbackKHR", self) orelse resolve("glDebugMessageCallback", self)
            else
                resolve("glDebugMessageCallback", self) orelse resolve("glDebugMessageCallbackKHR", self);
            if (address) |pointer| {
                const callback: DebugCallbackFn = @ptrCast(@alignCast(pointer));
                const enable: *const fn (u32) callconv(.c) void = @ptrCast(@alignCast(resolve("glEnable", self).?));
                enable(0x92E0); // GL_DEBUG_OUTPUT
                enable(0x8242); // GL_DEBUG_OUTPUT_SYNCHRONOUS
                callback(debugMessage, self);
                self.debug_callback = callback;
            }
        }
        return self;
    }

    pub fn destroy(self: *Context) void {
        const egl = &self.egl;
        if (self.debug_callback) |callback| callback(null, null);
        _ = egl.make_current(self.display, null, null, null);
        _ = egl.destroy_surface(self.display, self.surface);
        _ = egl.destroy_context(self.display, self.context);
        _ = egl.terminate(self.display);
        self.gl.close();
        egl.library.close();
        if (self.window) |*window| window.deinit();
        self.gpa.free(self.version);
        self.gpa.destroy(self);
    }

    fn resolve(name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque {
        const self: *Context = @ptrCast(@alignCast(user_data.?));
        return self.egl.get_proc(name.ptr) orelse self.gl.lookup(*const anyopaque, name);
    }

    pub fn options(self: *Context) gpu.Options {
        const gl: gpu.BackendOptions.GlOptions = .{ .get_proc_address = resolve, .user_data = self };
        return .{ .backend = if (self.gles) .{ .gles = gl } else .{ .gl = gl } };
    }

    pub fn description(self: *Context) []const u8 {
        return self.version;
    }

    pub fn drain(self: *Context) void {
        const finish: *const fn () callconv(.c) void = @ptrCast(@alignCast(resolve("glFinish", self).?));
        finish();
    }

    pub fn present(self: *Context, verify: bool) !void {
        if (self.window == null) return error.NoWindow;
        if (verify) {
            const read = @as(*const fn (i32, i32, i32, i32, u32, u32, *[4]u8) callconv(.c) void, @ptrCast(@alignCast(resolve("glReadPixels", self).?)));
            var pixel: [4]u8 = undefined;
            read(32, 32, 1, 1, 0x1908, 0x1401, &pixel);
            if (!std.mem.eql(u8, &pixel, &.{ 0, 0, 255, 255 })) return error.PresentationPixelMismatch;
        }
        const swap = self.egl.library.lookup(*const fn (?*anyopaque, ?*anyopaque) callconv(.c) u32, "eglSwapBuffers") orelse return error.MissingEglFunction;
        if (swap(self.display, self.surface) == 0) return error.EglSwapFailed;
    }

    pub fn takeNativeErrors(self: *Context) u32 {
        var count: u32 = self.native_errors.swap(0, .monotonic);
        while (self.get_error() != 0 and count < 64) count += 1;
        return count;
    }
};
