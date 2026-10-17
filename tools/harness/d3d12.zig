//! A D3D12 device on the default hardware adapter, through the runtime-loaded
//! d3d12.dll. The debug layer is enabled when available, and the stored error
//! messages of its info queue count as native errors.
const std = @import("std");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");
const sdk = gpu.raw.native.d3d12;
const Library = gpu.raw.native.WindowsLibrary;

pub const Context = struct {
    gpa: std.mem.Allocator,
    library: Library,
    device: *sdk.Object,
    queue: *sdk.Object,
    info_queue: ?*sdk.Object,
    name: []const u8,

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        _ = variant;
        const library = try Library.open("d3d12.dll");
        errdefer library.close();
        if (library.lookup(sdk.GetDebugInterfaceFn, "D3D12GetDebugInterface")) |get_debug| {
            var debug: ?*sdk.Object = null;
            if (get_debug(&sdk.iid_debug, &debug) >= 0 and debug != null) sdk.debugEnableLayer(debug.?);
            sdk.release(debug);
        }
        const CreateDevice = *const fn (?*anyopaque, u32, *const sdk.Guid, *?*sdk.Object) callconv(sdk.call_conv) i32;
        const create_device = library.lookup(CreateDevice, "D3D12CreateDevice") orelse return error.MissingDeviceEntry;
        var device: ?*sdk.Object = null;
        // D3D_FEATURE_LEVEL_11_0 on the default adapter
        if (create_device(null, 0xb000, &sdk.iid_device, &device) < 0 or device == null) return error.DeviceCreationFailed;
        errdefer sdk.release(device);
        var queue: ?*sdk.Object = null;
        // D3D12_COMMAND_LIST_TYPE_DIRECT queue
        const queue_desc: sdk.CommandQueueDesc = .{ .type = 0 };
        if (sdk.createCommandQueue(device.?, &queue_desc, &queue) < 0 or queue == null) return error.DeviceCreationFailed;
        errdefer sdk.release(queue);
        var info_queue: ?*sdk.Object = null;
        const name: []const u8 = if (sdk.queryInterface(device.?, &sdk.iid_info_queue, &info_queue) < 0 or info_queue == null) "hardware (info queue unavailable)" else "hardware";
        const self = try gpa.create(Context);
        self.* = .{ .gpa = gpa, .library = library, .device = device.?, .queue = queue.?, .info_queue = info_queue, .name = name };
        return self;
    }

    pub fn destroy(self: *Context) void {
        sdk.release(self.info_queue);
        sdk.release(self.queue);
        sdk.release(self.device);
        self.library.close();
        self.gpa.destroy(self);
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
