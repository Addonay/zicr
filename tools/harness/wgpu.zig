//! A native WebGPU device (wgpu-native or ABI-compatible Dawn), loaded from the
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
const InstanceDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    required_feature_count: usize = 0,
    required_features: ?[*]const u32 = null,
    required_limits: ?*const anyopaque = null,
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

const WorkDoneInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 1,
    callback: ?*const fn (u32, StringView, ?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
const FutureWaitInfo = extern struct { future: Future, completed: u32 = 0 };

const Procs = struct {
    wgpuCreateInstance: *const fn (?*const anyopaque) callconv(.c) ?*anyopaque,
    wgpuInstanceRequestAdapter: *const fn (?*anyopaque, ?*const anyopaque, RequestAdapterCallbackInfo) callconv(.c) Future,
    wgpuInstanceProcessEvents: *const fn (?*anyopaque) callconv(.c) void,
    wgpuInstanceRelease: *const fn (?*anyopaque) callconv(.c) void,
    wgpuAdapterRequestDevice: *const fn (?*anyopaque, ?*const DeviceDescriptor, RequestDeviceCallbackInfo) callconv(.c) Future,
    wgpuAdapterHasFeature: *const fn (?*anyopaque, u32) callconv(.c) u32,
    wgpuAdapterGetInfo: *const fn (?*anyopaque, *AdapterInfo) callconv(.c) u32,
    wgpuAdapterInfoFreeMembers: *const fn (AdapterInfo) callconv(.c) void,
    wgpuAdapterRelease: *const fn (?*anyopaque) callconv(.c) void,
    wgpuDeviceGetQueue: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    wgpuQueueRelease: *const fn (?*anyopaque) callconv(.c) void,
    wgpuQueueOnSubmittedWorkDone: *const fn (?*anyopaque, WorkDoneInfo) callconv(.c) Future,
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
    waiter: Waiter = .{},
    description_text: []u8,
    timed_wait: bool = false,

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
        const has_poll = self.library.lookup(*const anyopaque, "wgpuDevicePoll") != null;
        const HasFeature = *const fn (u32) callconv(.c) u32;
        self.timed_wait = if (has_poll) false else if (self.library.lookup(HasFeature, "wgpuHasInstanceFeature")) |has| has(1) != 0 else false;
        const timed_feature: u32 = 1;
        const instance_desc: InstanceDescriptor = .{ .required_feature_count = if (self.timed_wait) 1 else 0, .required_features = if (self.timed_wait) @ptrCast(&timed_feature) else null };
        self.instance = self.procs.wgpuCreateInstance(&instance_desc) orelse return error.InstanceFailed;
        errdefer self.procs.wgpuInstanceRelease(self.instance);

        self.waiter = .{};
        const adapter_waiter = &self.waiter;
        _ = self.procs.wgpuInstanceRequestAdapter(self.instance, null, .{
            .mode = callback_mode_allow_process_events,
            .callback = onAdapter,
            .userdata1 = adapter_waiter,
        });
        try self.pump(adapter_waiter);
        if (adapter_waiter.status != status_success) return error.AdapterFailed;
        self.adapter = adapter_waiter.handle orelse return error.AdapterFailed;
        errdefer self.procs.wgpuAdapterRelease(self.adapter);

        var info: AdapterInfo = .{};
        const info_status = self.procs.wgpuAdapterGetInfo(self.adapter, &info);
        defer self.procs.wgpuAdapterInfoFreeMembers(info);
        if (info_status != status_success) return error.AdapterInfoFailed;
        self.description_text = try std.fmt.allocPrint(gpa, "{s} (native WebGPU, backend {d}, {s})", .{ messageText(info.description), info.backend_type, if (has_poll) "DevicePoll" else if (self.timed_wait) "TimedWaitAny" else "ProcessEvents" });
        errdefer gpa.free(self.description_text);

        // depth32float-stencil8 is needed by the depth-stencil scenes
        var features: [5]u32 = undefined;
        var feature_count: usize = 0;
        // webgpu.h v29: depth32-stencil8=3, BC=4, ETC2=6, ASTC=7, dual source=17.
        for ([_]u32{ feature_depth32_float_stencil8, 4, 6, 7, 17 }) |feature| {
            if (self.procs.wgpuAdapterHasFeature(self.adapter, feature) == 0) continue;
            features[feature_count] = feature;
            feature_count += 1;
        }
        var device_desc: DeviceDescriptor = .{
            .required_feature_count = feature_count,
            .required_features = &features,
            .uncaptured_error_callback_info = .{ .callback = onUncapturedError, .userdata1 = self },
            .device_lost_callback_info = .{ .mode = callback_mode_allow_process_events, .callback = onDeviceLost, .userdata1 = self },
        };
        self.waiter = .{};
        const device_waiter = &self.waiter;
        _ = self.procs.wgpuAdapterRequestDevice(self.adapter, &device_desc, .{
            .mode = callback_mode_allow_process_events,
            .callback = onDevice,
            .userdata1 = device_waiter,
        });
        try self.pump(device_waiter);
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

    pub fn createBenchmark(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return create(gpa, variant);
    }
    pub fn validationAvailable(_: *Context) bool {
        // No optional native debug/GPU-validation layer is requested. WebGPU's
        // mandatory provider checks are shared equally by all benchmark modes.
        return false;
    }
    pub fn waitFuture(self: *Context, id: u64) bool {
        if (self.library.lookup(*const fn (?*anyopaque, u32, ?*const u64) callconv(.c) u32, "wgpuDevicePoll")) |poll| {
            _ = poll(self.device, 1, null);
            self.procs.wgpuInstanceProcessEvents(self.instance);
            return true;
        }
        if (!self.timed_wait) return false;
        const Wait = *const fn (?*anyopaque, usize, [*]FutureWaitInfo, u64) callconv(.c) u32;
        const wait = self.library.lookup(Wait, "wgpuInstanceWaitAny") orelse return false;
        var info: FutureWaitInfo = .{ .future = .{ .id = id } };
        return wait(self.instance, 1, @ptrCast(&info), 1_000_000_000) == 1 and info.completed != 0;
    }
    fn workDone(status: u32, _: StringView, user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const result: *u32 = @ptrCast(@alignCast(user.?));
        result.* = status;
    }
    pub fn drain(self: *Context) void {
        const queue = self.procs.wgpuDeviceGetQueue(self.device) orelse @panic("no benchmark queue");
        defer self.procs.wgpuQueueRelease(queue);
        var status: u32 = 0;
        const future = self.procs.wgpuQueueOnSubmittedWorkDone(queue, .{ .callback = workDone, .userdata1 = &status });
        if (!self.waitFuture(future.id) or status != 1) @panic("benchmark GPU drain failed");
    }

    /// Resolves webgpu.h names through the library, for the backend.
    fn resolve(name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque {
        const self: *Context = @ptrCast(@alignCast(user_data.?));
        return self.library.lookup(*const anyopaque, name);
    }

    pub fn options(self: *Context) gpu.Options {
        return .{
            .backend = .{ .wgpu = .{
                .instance = self.instance,
                .wait_timeout_ns = if (self.timed_wait) 1_000_000_000 else 0,
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
