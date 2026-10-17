//! Surfaceless EGL contexts for GL and GLES, through runtime-loaded EGL and GL libraries.
const std = @import("std");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");

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
    get_error: *const fn () callconv(.c) u32,
    version: []const u8,

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        const gles = variant == .gles or variant == .gles_legacy;
        const legacy = variant == .gl_legacy or variant == .gles_legacy;
        const self = try gpa.create(Context);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.gles = gles;
        self.egl = try Egl.open();
        errdefer self.egl.library.close();
        const egl = &self.egl;
        self.display = egl.get_platform_display(0x31DD, null, null) orelse return error.NoSurfacelessEglDisplay;
        var major: i32 = 0;
        var minor: i32 = 0;
        if (egl.initialize(self.display, &major, &minor) == 0) return error.EglInitializationFailed;
        errdefer _ = egl.terminate(self.display);
        self.gl = try std.DynLib.open(if (gles) "libGLESv2.so.2" else "libGL.so.1");
        errdefer self.gl.close();
        const none = 0x3038;
        const config_attributes = [_]i32{
            0x3033, 1, // EGL_SURFACE_TYPE, EGL_PBUFFER_BIT
            0x3040, if (gles) 0x40 else 8, // EGL_RENDERABLE_TYPE, ES3/OpenGL
            0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, // RGBA
            none,
        };
        var config: ?*anyopaque = null;
        var count: i32 = 0;
        if (egl.choose_config(self.display, &config_attributes, @ptrCast(&config), 1, &count) == 0 or count < 1) return error.NoEglConfig;
        if (egl.bind_api(if (gles) 0x30A0 else 0x30A2) == 0) return error.EglBindApiFailed;
        const context_attributes = if (gles)
            [_]i32{ 0x3098, 3, 0x30FB, if (legacy) 0 else 1, none, none, none }
        else
            [_]i32{ 0x3098, if (legacy) 3 else 4, 0x30FB, if (legacy) 3 else 6, 0x30FD, 1, none };
        self.context = egl.create_context(self.display, config, null, &context_attributes) orelse return error.EglContextCreationFailed;
        errdefer _ = egl.destroy_context(self.display, self.context);
        const surface_attributes = [_]i32{ 0x3057, 16, 0x3056, 16, none };
        self.surface = egl.create_surface(self.display, config, &surface_attributes) orelse return error.EglSurfaceCreationFailed;
        errdefer _ = egl.destroy_surface(self.display, self.surface);
        if (egl.make_current(self.display, self.surface, self.surface, self.context) == 0) return error.EglMakeCurrentFailed;
        self.get_error = @ptrCast(@alignCast(resolve("glGetError", self) orelse return error.MissingGlFunction));
        const get_string: *const fn (u32) callconv(.c) ?[*:0]const u8 = @ptrCast(@alignCast(resolve("glGetString", self) orelse return error.MissingGlFunction));
        self.version = try gpa.dupe(u8, std.mem.span(get_string(0x1F02) orelse "unknown"));
        return self;
    }

    pub fn destroy(self: *Context) void {
        const egl = &self.egl;
        _ = egl.make_current(self.display, null, null, null);
        _ = egl.destroy_surface(self.display, self.surface);
        _ = egl.destroy_context(self.display, self.context);
        _ = egl.terminate(self.display);
        self.gl.close();
        egl.library.close();
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

    pub fn takeNativeErrors(self: *Context) u32 {
        var count: u32 = 0;
        while (self.get_error() != 0 and count < 64) count += 1;
        return count;
    }
};
