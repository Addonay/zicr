//! A D3D12 device on the default hardware adapter, through the runtime-loaded
//! d3d12.dll. The debug layer is enabled when available, and the stored error
//! messages of its info queue count as native errors.
const std = @import("std");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");
const sdk = gpu.raw.native.d3d12;
const Library = gpu.raw.native.WindowsLibrary;
const Window = @import("dxgi_window.zig").Window;

pub const Context = struct {
    window: ?Window = null,
    gpa: std.mem.Allocator,
    library: Library,
    device: *sdk.Object,
    queue: *sdk.Object,
    info_queue: ?*sdk.Object,
    name: []const u8,
    warp: ?gpu.raw.native.dxgi.Warp = null,
    preferred: ?gpu.raw.native.dxgi.Preferred = null,
    gpu_validation: bool = false,
    dred: bool = false,

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        const library = try Library.open("d3d12.dll");
        errdefer library.close();
        var gpu_validation = false;
        var dred = false;
        if (library.lookup(sdk.GetDebugInterfaceFn, "D3D12GetDebugInterface")) |get_debug| {
            var debug: ?*sdk.Object = null;
            if (get_debug(&sdk.iid_debug, &debug) >= 0 and debug != null) sdk.debugEnableLayer(debug.?);
            sdk.release(debug);
            var debug1: ?*sdk.Object = null;
            if (get_debug(&sdk.iid_debug1, &debug1) >= 0 and debug1 != null) {
                sdk.debugEnableLayer(debug1.?);
                sdk.debugEnableGpuValidation(debug1.?);
                gpu_validation = true;
            }
            sdk.release(debug1);
            var settings: ?*sdk.Object = null;
            if (get_debug(&sdk.iid_dred_settings, &settings) >= 0 and settings != null) {
                sdk.enableDred(settings.?);
                dred = true;
            }
            sdk.release(settings);
        }
        const CreateDevice = *const fn (?*anyopaque, u32, *const sdk.Guid, *?*sdk.Object) callconv(sdk.call_conv) i32;
        const create_device = library.lookup(CreateDevice, "D3D12CreateDevice") orelse return error.MissingDeviceEntry;
        var device: ?*sdk.Object = null;
        var warp: ?gpu.raw.native.dxgi.Warp = null;
        errdefer if (warp) |*adapter| adapter.deinit();
        const force_warp = variant == .d3d12_warp;
        var preferred: ?gpu.raw.native.dxgi.Preferred = if (force_warp) null else gpu.raw.native.dxgi.Preferred.init(.high_performance, 0) catch null;
        errdefer if (preferred) |*adapter| adapter.deinit();
        if (force_warp or create_device(if (preferred) |adapter| adapter.adapter else null, 0xb000, &sdk.iid_device, &device) < 0 or device == null) {
            warp = try gpu.raw.native.dxgi.Warp.init();
            if (create_device(warp.?.adapter, 0xb000, &sdk.iid_device, &device) < 0 or device == null) return error.DeviceCreationFailed;
        }
        errdefer sdk.release(device);
        var queue: ?*sdk.Object = null;
        // D3D12_COMMAND_LIST_TYPE_DIRECT queue
        const queue_desc: sdk.CommandQueueDesc = .{ .type = 0 };
        if (sdk.createCommandQueue(device.?, &queue_desc, &queue) < 0 or queue == null) return error.DeviceCreationFailed;
        errdefer sdk.release(queue);
        var info_queue: ?*sdk.Object = null;
        _ = sdk.queryInterface(device.?, &sdk.iid_info_queue, &info_queue);
        const adapter_name: []const u8 = if (warp != null) (if (info_queue == null) "WARP (info queue unavailable)" else if (gpu_validation) "WARP (GPU validation requested)" else "WARP") else if (info_queue == null) "hardware (info queue unavailable)" else "hardware";
        var root_version: u32 = 2;
        const root_1_1 = library.lookup(sdk.VersionedRootSignatureSerializeFn, "D3D12SerializeVersionedRootSignature") != null and sdk.checkFeatureSupport(device.?, 12, &root_version, @sizeOf(u32)) >= 0 and root_version >= 2;
        const name = try std.fmt.allocPrint(gpa, "{s}; root signature {s}", .{ adapter_name, if (root_1_1) "1.1" else "1.0" });
        errdefer gpa.free(name);
        const self = try gpa.create(Context);
        self.* = .{ .gpa = gpa, .library = library, .device = device.?, .queue = queue.?, .info_queue = info_queue, .name = name, .warp = warp, .preferred = preferred, .gpu_validation = gpu_validation, .dred = dred };
        return self;
    }

    pub fn createWindow(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        const self = try create(gpa, variant);
        errdefer self.destroy();
        self.window = try Window.create(self.device, self.queue, true);
        return self;
    }

    pub fn acquireSwapchain(self: *Context) !gpu.Swapchain {
        if (self.window) |*window| return window.acquire();
        return error.NoWindow;
    }

    pub fn present(self: *Context, verify: bool) !void {
        if (self.window) |*window| return window.present(verify);
        return error.NoWindow;
    }

    pub fn destroy(self: *Context) void {
        if (self.window) |*window| window.deinit();
        sdk.release(self.info_queue);
        sdk.release(self.queue);
        sdk.release(self.device);
        if (self.warp) |*adapter| adapter.deinit();
        if (self.preferred) |*adapter| adapter.deinit();
        self.library.close();
        self.gpa.free(self.name);
        self.gpa.destroy(self);
    }

    pub fn validationAvailable(self: *Context) bool {
        return self.info_queue != null and self.gpu_validation;
    }

    pub fn options(self: *Context) gpu.Options {
        return .{ .backend = .{ .d3d12 = .{ .device = self.device, .queue = self.queue } } };
    }

    pub fn description(self: *Context) []const u8 {
        return self.name;
    }

    /// Error and corruption messages stored by the info queue since the last call.
    pub fn takeNativeErrors(self: *Context) u32 {
        const info = self.info_queue orelse return 0;
        var errors: u32 = 0;
        const count = sdk.infoGetNumStoredMessages(info);
        for (0..count) |index| {
            var size: usize = 0;
            if (sdk.infoGetMessage(info, index, null, &size) < 0) continue;
            const words = self.gpa.alloc(u64, (size + 7) / 8) catch continue;
            defer self.gpa.free(words);
            const message: *sdk.Message = @ptrCast(words.ptr);
            if (sdk.infoGetMessage(info, index, message, &size) < 0) continue;
            if (message.severity == 0 or message.severity == 1) errors += 1;
        }
        sdk.infoClearStoredMessages(info);
        return errors;
    }
};
