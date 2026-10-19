//! A D3D11 device on the default hardware adapter (or WARP), through the
//! runtime-loaded d3d11.dll.
const std = @import("std");
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");
const sdk = gpu.raw.native.d3d11;
const Library = gpu.raw.native.WindowsLibrary;
const Window = @import("dxgi_window.zig").Window;

pub const Context = struct {
    window: ?Window = null,
    gpa: std.mem.Allocator,
    library: Library,
    device: *sdk.Object,
    context: *sdk.Object,
    name: []const u8,

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        _ = variant;
        const library = try Library.open("d3d11.dll");
        errdefer library.close();
        const CreateDevice = *const fn (?*anyopaque, u32, ?*anyopaque, u32, ?[*]const u32, u32, u32, *?*sdk.Object, *u32, *?*sdk.Object) callconv(sdk.call_conv) i32;
        const create_device = library.lookup(CreateDevice, "D3D11CreateDevice") orelse return error.MissingDeviceEntry;
        var device: ?*sdk.Object = null;
        var context: ?*sdk.Object = null;
        var level: u32 = 0;
        const levels = [_]u32{ 0xb100, 0xb000 };
        // D3D_DRIVER_TYPE_HARDWARE, then WARP; D3D11_CREATE_DEVICE_BGRA_SUPPORT
        var status = create_device(null, 1, null, 0x20, &levels, levels.len, 7, &device, &level, &context);
        var name: []const u8 = "hardware";
        if (status < 0) {
            status = create_device(null, 5, null, 0x20, &levels, levels.len, 7, &device, &level, &context);
            name = "WARP";
        }
        if (status < 0 or device == null or context == null) return error.DeviceCreationFailed;
        errdefer sdk.release(context);
        errdefer sdk.release(device);
        const adapter_name = gpu.raw.native.dxgi.describeD3D11Device(gpa, device.?) catch try gpa.dupe(u8, name);
        errdefer gpa.free(adapter_name);
        const self = try gpa.create(Context);
        self.* = .{ .gpa = gpa, .library = library, .device = device.?, .context = context.?, .name = adapter_name };
        return self;
    }

    pub fn createBenchmark(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return create(gpa, variant);
    }
    pub fn createWindow(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        const self = try create(gpa, variant);
        errdefer self.destroy();
        self.window = try Window.create(self.device, self.context, false);
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
        sdk.release(self.context);
        sdk.release(self.device);
        self.library.close();
        self.gpa.free(self.name);
        self.gpa.destroy(self);
    }

    pub fn options(self: *Context) gpu.Options {
        return .{ .backend = .{ .d3d11 = .{ .device = self.device, .device_context = self.context } } };
    }

    pub fn validationAvailable(_: *Context) bool {
        return false;
    }
    pub fn description(self: *Context) []const u8 {
        return self.name;
    }

    pub fn takeNativeErrors(self: *Context) u32 {
        _ = self;
        return 0;
    }
};
