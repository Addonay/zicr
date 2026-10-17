//! A WebGPU device through wgpu-native, loaded at runtime from the library named by the
//! WGPU_NATIVE_LIB environment variable. Only the instance, adapter and device calls are
//! declared here; every other webgpu function is resolved by the backend itself.
const std = @import("std");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");

const StringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,
};
const ChainedStruct = extern struct {
    next: ?*const ChainedStruct = null,
    s_type: u32 = 0,
};
const Future = extern struct { id: u64 = 0 };
const callback_mode_allow_process_events: u32 = 2;
const feature_depth32_float_stencil8: u32 = 3;
const status_success: u32 = 1;
const max_spins: usize = 1 << 28;

const UncapturedErrorCallback = *const fn (device: ?*const anyopaque, error_type: u32, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
const DeviceLostCallback = *const fn (device: ?*const anyopaque, reason: u32, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
const RequestAdapterCallback = *const fn (status: u32, adapter: ?*anyopaque, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
const RequestDeviceCallback = *const fn (status: u32, device: ?*anyopaque, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;

const RequestAdapterCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?RequestAdapterCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
const RequestDeviceCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?RequestDeviceCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
const UncapturedErrorCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    callback: ?UncapturedErrorCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
const DeviceLostCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?DeviceLostCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
const QueueDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: StringView = .{},
};
const DeviceDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: StringView = .{},
    required_feature_count: usize = 0,
    required_features: ?[*]const u32 = null,
    required_limits: ?*const anyopaque = null,
    default_queue: QueueDescriptor = .{},
    device_lost_callback_info: DeviceLostCallbackInfo = .{},
    uncaptured_error_callback_info: UncapturedErrorCallbackInfo = .{},
};
const AdapterInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    vendor: StringView = .{},
    architecture: StringView = .{},
    device: StringView = .{},
    description: StringView = .{},
    backend_type: u32 = 0,
    adapter_type: u32 = 0,
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    subgroup_min_size: u32 = 0,
    subgroup_max_size: u32 = 0,
};

const Procs = struct {
    wgpuCreateInstance: *const fn (?*const anyopaque) callconv(.c) ?*anyopaque,
    wgpuInstanceRequestAdapter: *const fn (?*anyopaque, ?*const anyopaque, RequestAdapterCallbackInfo) callconv(.c) Future,
    wgpuInstanceProcessEvents: *const fn (?*anyopaque) callconv(.c) void,
    wgpuInstanceRelease: *const fn (?*anyopaque) callconv(.c) void,
    wgpuAdapterRequestDevice: *const fn (?*anyopaque, ?*const DeviceDescriptor, RequestDeviceCallbackInfo) callconv(.c) Future,
    wgpuAdapterGetInfo: *const fn (?*anyopaque, *AdapterInfo) callconv(.c) u32,
    wgpuAdapterRelease: *const fn (?*anyopaque) callconv(.c) void,
    wgpuDeviceRelease: *const fn (?*anyopaque) callconv(.c) void,
};

const Waiter = struct {
    done: bool = false,
    status: u32 = 0,
    handle: ?*anyopaque = null,
};

fn onAdapter(status: u32, adapter: ?*anyopaque, _: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const waiter: *Waiter = @ptrCast(@alignCast(userdata1.?));
    waiter.status = status;
    waiter.handle = adapter;
    waiter.done = true;
}

fn onDevice(status: u32, device: ?*anyopaque, _: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const waiter: *Waiter = @ptrCast(@alignCast(userdata1.?));
    waiter.status = status;
    waiter.handle = device;
    waiter.done = true;
}

fn onUncapturedError(_: ?*const anyopaque, _: u32, message: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const self: *Context = @ptrCast(@alignCast(userdata1.?));
    _ = @atomicRmw(u32, &self.native_errors, .Add, 1, .monotonic);
    std.debug.print("wgpu error: {s}\n", .{messageText(message)});
}

fn onDeviceLost(_: ?*const anyopaque, reason: u32, message: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const self: *Context = @ptrCast(@alignCast(userdata1.?));
    _ = @atomicRmw(u32, &self.native_errors, .Add, 1, .monotonic);
    std.debug.print("wgpu device lost reason={d}: {s}\n", .{ reason, messageText(message) });
}

fn messageText(message: StringView) []const u8 {
    const data = message.data orelse return "";
    return data[0..message.length];
}

pub const Context = struct {
    gpa: std.mem.Allocator,
    library: std.DynLib,
    procs: Procs,
    instance: *anyopaque,
    adapter: *anyopaque,
    device: *anyopaque,
    /// Incremented by the uncaptured error and device lost callbacks.
    native_errors: u32 = 0,
    description_text: []u8,

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        _ = variant;
        const path = std.mem.span(std.c.getenv("WGPU_NATIVE_LIB") orelse return error.MissingWgpuNativeLibrary);
        const self = try gpa.create(Context);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.native_errors = 0;
        self.library = try std.DynLib.open(path);
        errdefer self.library.close();
        inline for (@typeInfo(Procs).@"struct".field_names) |name| {
            @field(self.procs, name) = self.library.lookup(@TypeOf(@field(self.procs, name)), name) orelse return error.MissingWgpuFunction;
        }
        self.instance = self.procs.wgpuCreateInstance(null) orelse return error.InstanceFailed;
        errdefer self.procs.wgpuInstanceRelease(self.instance);

        var adapter_waiter: Waiter = .{};
        _ = self.procs.wgpuInstanceRequestAdapter(self.instance, null, .{
            .mode = callback_mode_allow_process_events,
            .callback = onAdapter,
            .userdata1 = &adapter_waiter,
        });
        try self.pump(&adapter_waiter);
        if (adapter_waiter.status != status_success) return error.AdapterFailed;
        self.adapter = adapter_waiter.handle orelse return error.AdapterFailed;
        errdefer self.procs.wgpuAdapterRelease(self.adapter);

        var info: AdapterInfo = .{};
        _ = self.procs.wgpuAdapterGetInfo(self.adapter, &info);
        self.description_text = try std.fmt.allocPrint(gpa, "{s} (wgpu-native, backend {d})", .{ messageText(info.description), info.backend_type });
        errdefer gpa.free(self.description_text);

        // depth32float-stencil8 is needed by the depth-stencil scenes
        const features = [_]u32{feature_depth32_float_stencil8};
        var device_desc: DeviceDescriptor = .{
            .required_feature_count = features.len,
            .required_features = &features,
            .uncaptured_error_callback_info = .{ .callback = onUncapturedError, .userdata1 = self },
            .device_lost_callback_info = .{ .mode = callback_mode_allow_process_events, .callback = onDeviceLost, .userdata1 = self },
        };
        var device_waiter: Waiter = .{};
        _ = self.procs.wgpuAdapterRequestDevice(self.adapter, &device_desc, .{
            .mode = callback_mode_allow_process_events,
            .callback = onDevice,
            .userdata1 = &device_waiter,
        });
        try self.pump(&device_waiter);
        if (device_waiter.status != status_success) return error.DeviceFailed;
        self.device = device_waiter.handle orelse return error.DeviceFailed;
        return self;
    }

    fn pump(self: *Context, waiter: *const Waiter) !void {
        var spins: usize = 0;
        while (!waiter.done) : (spins += 1) {
            if (spins > max_spins) return error.WgpuTimeout;
            self.procs.wgpuInstanceProcessEvents(self.instance);
        }
    }

    pub fn destroy(self: *Context) void {
        self.procs.wgpuDeviceRelease(self.device);
        self.procs.wgpuAdapterRelease(self.adapter);
        self.procs.wgpuInstanceRelease(self.instance);
        self.gpa.free(self.description_text);
        self.library.close();
        self.gpa.destroy(self);
    }

    /// Resolves webgpu.h names through the library, for the backend.
    fn resolve(name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque {
        const self: *Context = @ptrCast(@alignCast(user_data.?));
        return self.library.lookup(*const anyopaque, name);
    }

    pub fn options(self: *Context) gpu.Options {
        return .{
            .backend = .{ .wgpu = .{
                .device = self.device,
                .get_proc_address = resolve,
                .user_data = self,
            } },
            .defaults = .{ .color_format = .rgba8 },
        };
    }

    pub fn description(self: *Context) []const u8 {
        return self.description_text;
    }

    pub fn takeNativeErrors(self: *Context) u32 {
        return @atomicRmw(u32, &self.native_errors, .Xchg, 0, .monotonic);
    }
};
