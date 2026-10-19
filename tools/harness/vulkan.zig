//! Headless Vulkan 1.3 device for the scene suite. Loads libvulkan.so.1 at runtime and creates an
//! instance (with VK_LAYER_KHRONOS_validation when the loader finds it; VK_ADD_LAYER_PATH is honoured
//! by the loader) and a device with the features the Vulkan backend requires: dynamic rendering,
//! synchronization2, buffer device address and VK_EXT_descriptor_buffer. A debug messenger counts the
//! errors and warnings the validation layer reports for takeNativeErrors().
const std = @import("std");
const builtin = @import("builtin");
const Loader = if (builtin.os.tag == .windows) gpu.raw.native.WindowsLibrary else std.DynLib;
const gpu = @import("zicr").gpu;
const harness = @import("harness.zig");
const Window = @import("vulkan_window.zig").Window;

const Instance = ?*anyopaque;
const PhysicalDevice = ?*anyopaque;
const Device = ?*anyopaque;
const Queue = ?*anyopaque;
const AllocationCallbacks = anyopaque;
const DebugUtilsMessengerEXT = u64;
const GetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const anyopaque;

const SUCCESS = 0;
const TRUE = 1;
const FALSE = 0;
const QUEUE_GRAPHICS_COMPUTE_TRANSFER: u32 = 0x1 | 0x2 | 0x4;
const API_VERSION_1_3: u32 = (1 << 22) | (3 << 12);
const DEBUG_SEVERITY_WARNING: u32 = 0x100;
const DEBUG_SEVERITY_ERROR: u32 = 0x1000;
const DEBUG_TYPE_ALL: u32 = 0x7;
const VK_MAX_DESCRIPTION_SIZE = 256;

const DebugUtilsMessengerCallback = *const fn (u32, u32, *const DebugUtilsMessengerCallbackDataEXT, ?*anyopaque) callconv(.c) u32;

const ApplicationInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    pApplicationName: ?[*:0]const u8 = null,
    applicationVersion: u32 = 0,
    pEngineName: ?[*:0]const u8 = null,
    engineVersion: u32 = 0,
    apiVersion: u32 = 0,
};
const InstanceCreateInfo = extern struct {
    sType: i32 = 1,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pApplicationInfo: ?*const ApplicationInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
};
const DeviceQueueCreateInfo = extern struct {
    sType: i32 = 2,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32 = 0,
    queueCount: u32 = 0,
    pQueuePriorities: ?[*]const f32 = null,
};
const DeviceCreateInfo = extern struct {
    sType: i32 = 3,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueCreateInfoCount: u32 = 0,
    pQueueCreateInfos: ?[*]const DeviceQueueCreateInfo = null,
    enabledLayerCount: u32 = 0,
    ppEnabledLayerNames: ?[*]const [*:0]const u8 = null,
    enabledExtensionCount: u32 = 0,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8 = null,
    pEnabledFeatures: ?*const anyopaque = null,
};
const DebugUtilsMessengerCreateInfoEXT = extern struct {
    sType: i32 = 1000128004,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    messageSeverity: u32 = 0,
    messageType: u32 = 0,
    pfnUserCallback: DebugUtilsMessengerCallback,
    pUserData: ?*anyopaque = null,
};

const ExtensionProperties = extern struct { name: [256]u8, version: u32 };
const SwapchainMaintenanceFeatures = extern struct {
    sType: i32 = 1000275000,
    pNext: ?*anyopaque = null,
    swapchainMaintenance1: u32 = 0,
};

/// Loader and driver entry points, resolved through vkGetInstanceProcAddr.
const Vk = struct {
    vkEnumerateInstanceExtensionProperties: *const fn (?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) i32 = undefined,
    vkEnumerateDeviceExtensionProperties: *const fn (PhysicalDevice, ?[*:0]const u8, *u32, ?[*]ExtensionProperties) callconv(.c) i32 = undefined,
    vkGetPhysicalDeviceFeatures2: *const fn (PhysicalDevice, *PhysicalDeviceFeatures2) callconv(.c) void = undefined,
    vkCreateInstance: *const fn (*const InstanceCreateInfo, ?*const AllocationCallbacks, *Instance) callconv(.c) i32 = undefined,
    vkEnumerateInstanceLayerProperties: *const fn (*u32, ?[*]LayerProperties) callconv(.c) i32 = undefined,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) i32 = undefined,
    vkGetPhysicalDeviceFeatures: *const fn (PhysicalDevice, *PhysicalDeviceFeatures) callconv(.c) void = undefined,
    vkGetPhysicalDeviceProperties: *const fn (PhysicalDevice, *PhysicalDeviceProperties) callconv(.c) void = undefined,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void = undefined,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const AllocationCallbacks, *Device) callconv(.c) i32 = undefined,
    vkCreateDebugUtilsMessengerEXT: *const fn (Instance, *const DebugUtilsMessengerCreateInfoEXT, ?*const AllocationCallbacks, *DebugUtilsMessengerEXT) callconv(.c) i32 = undefined,
    vkDestroyDebugUtilsMessengerEXT: *const fn (Instance, DebugUtilsMessengerEXT, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkDestroyDevice: *const fn (Device, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkDestroyInstance: *const fn (Instance, ?*const AllocationCallbacks) callconv(.c) void = undefined,
    vkDeviceWaitIdle: *const fn (Device) callconv(.c) i32 = undefined,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(.c) void = undefined,
};

/// Loads the entry points named by the fields of `Vk`; absent ones stay undefined.
fn loadVk(out: *Vk, get: GetInstanceProcAddr, handle: anytype) void {
    inline for (@typeInfo(Vk).@"struct".field_names) |name| {
        if (get(handle, name.ptr)) |proc| @field(out, name) = @ptrCast(proc);
    }
}

fn debugCallback(severity: u32, _: u32, data: *const DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(.c) u32 {
    if (severity & (DEBUG_SEVERITY_ERROR | DEBUG_SEVERITY_WARNING) != 0) {
        const self: *Context = @ptrCast(@alignCast(user_data.?));
        _ = self.native_errors.fetchAdd(1, .monotonic);
        const message = if (data.pMessage) |m| std.mem.span(m) else "";
        std.debug.print("vulkan validation (severity 0x{x}): {s}\n", .{ severity, message });
    }
    return FALSE;
}

pub const Context = struct {
    gpa: std.mem.Allocator,
    native_errors: std.atomic.Value(u32) = .init(0),
    lib: Loader,
    get_instance: GetInstanceProcAddr,
    vk: Vk,
    instance: Instance,
    physical: PhysicalDevice,
    messenger: DebugUtilsMessengerEXT,
    device: Device,
    queue: Queue,
    queue_family_index: u32,
    descriptor_buffer: bool,
    native_validation: bool,
    name: []u8,
    window: ?Window = null,

    pub fn validationAvailable(self: *Context) bool {
        return self.native_validation and self.messenger != 0;
    }

    pub fn create(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return createImpl(gpa, variant, false, true);
    }

    pub fn createWindow(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return createImpl(gpa, variant, true, true);
    }

    pub fn createBenchmark(gpa: std.mem.Allocator, variant: harness.Variant) !*Context {
        return createImpl(gpa, variant, false, false);
    }

    pub fn drain(self: *Context) void {
        if (self.vk.vkDeviceWaitIdle(self.device) != SUCCESS) @panic("benchmark GPU drain failed");
    }

    fn createImpl(gpa: std.mem.Allocator, variant: harness.Variant, windowed: bool, request_validation: bool) !*Context {
        const self = try gpa.create(Context);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.window = null;
        self.native_errors = .init(0);
        self.descriptor_buffer = variant == .vulkan_descriptor_buffer;
        self.lib = try Loader.open(if (builtin.os.tag == .windows) "vulkan-1.dll" else "libvulkan.so.1");
        errdefer self.lib.close();
        self.get_instance = self.lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVulkanLoader;
        var global: Vk = .{};
        loadVk(&global, self.get_instance, @as(Instance, null));

        var layer_count: u32 = 0;
        _ = global.vkEnumerateInstanceLayerProperties(&layer_count, null);
        var layers: [64]LayerProperties = undefined;
        layer_count = @min(layer_count, layers.len);
        _ = global.vkEnumerateInstanceLayerProperties(&layer_count, &layers);
        var validation = false;
        for (layers[0..@min(layer_count, layers.len)]) |*layer| {
            if (std.mem.eql(u8, std.mem.sliceTo(&layer.layerName, 0), "VK_LAYER_KHRONOS_validation")) validation = true;
        }
        validation = validation and request_validation;
        self.native_validation = validation;
        const validation_layer = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        // VK_KHR_surface is required by VK_KHR_swapchain, which the device enables
        const instance_ext = [_][*:0]const u8{ "VK_KHR_surface", "VK_EXT_debug_utils", "VK_EXT_validation_features" };
        const window_ext = [_][*:0]const u8{ "VK_KHR_surface", if (builtin.os.tag == .windows) "VK_KHR_win32_surface" else "VK_KHR_xlib_surface", "VK_KHR_get_surface_capabilities2", "VK_EXT_surface_maintenance1", "VK_EXT_debug_utils", "VK_EXT_validation_features" };
        if (windowed) {
            var count: u32 = 0;
            if (global.vkEnumerateInstanceExtensionProperties(null, &count, null) != SUCCESS or count > 512) return error.ExtensionEnumerationFailed;
            var extensions: [512]ExtensionProperties = undefined;
            if (global.vkEnumerateInstanceExtensionProperties(null, &count, &extensions) != SUCCESS) return error.ExtensionEnumerationFailed;
            for (window_ext[2..4]) |required| {
                var found = false;
                for (extensions[0..count]) |*extension| if (std.mem.eql(u8, std.mem.sliceTo(&extension.name, 0), std.mem.span(required))) {
                    found = true;
                    break;
                };
                if (!found) return error.PresentFenceExtensionsUnavailable;
            }
        }
        const sync_feature: u32 = 4;
        const validation_features: ValidationFeatures = .{ .enabledValidationFeatureCount = 1, .pEnabledValidationFeatures = @ptrCast(&sync_feature) };
        const app_info: ApplicationInfo = .{ .pApplicationName = "zicr scenes", .apiVersion = API_VERSION_1_3 };
        const instance_info: InstanceCreateInfo = .{
            .pNext = if (validation) &validation_features else null,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = if (validation) 1 else 0,
            .ppEnabledLayerNames = if (validation) &validation_layer else null,
            .enabledExtensionCount = if (windowed) (if (validation) @as(u32, 6) else 4) else (if (validation) @as(u32, 3) else 1),
            .ppEnabledExtensionNames = if (windowed) &window_ext else &instance_ext,
        };
        if (global.vkCreateInstance(&instance_info, null, &self.instance) != SUCCESS) return error.VulkanInitFailed;
        self.vk = .{};
        loadVk(&self.vk, self.get_instance, self.instance);
        errdefer self.vk.vkDestroyInstance(self.instance, null);

        self.messenger = 0;
        if (validation) {
            const messenger_info: DebugUtilsMessengerCreateInfoEXT = .{
                .messageSeverity = DEBUG_SEVERITY_ERROR | DEBUG_SEVERITY_WARNING | 0x1,
                .messageType = DEBUG_TYPE_ALL,
                .pfnUserCallback = debugCallback,
                .pUserData = self,
            };
            if (self.vk.vkCreateDebugUtilsMessengerEXT(self.instance, &messenger_info, null, &self.messenger) != SUCCESS) return error.VulkanInitFailed;
        }
        errdefer if (validation) self.vk.vkDestroyDebugUtilsMessengerEXT(self.instance, self.messenger, null);

        // physical device with graphics, compute and transfer
        var phys_count: u32 = 0;
        _ = self.vk.vkEnumeratePhysicalDevices(self.instance, &phys_count, null);
        var phys: [16]PhysicalDevice = undefined;
        _ = self.vk.vkEnumeratePhysicalDevices(self.instance, &phys_count, &phys);
        var physical: PhysicalDevice = null;
        var family: u32 = 0;
        for (phys[0..@min(phys_count, phys.len)]) |candidate| {
            var fam_count: u32 = 0;
            self.vk.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &fam_count, null);
            var families: [32]QueueFamilyProperties = undefined;
            self.vk.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &fam_count, &families);
            for (families[0..@min(fam_count, families.len)], 0..) |*fam, i| {
                if (fam.queueFlags & QUEUE_GRAPHICS_COMPUTE_TRANSFER == QUEUE_GRAPHICS_COMPUTE_TRANSFER) {
                    physical = candidate;
                    family = @intCast(i);
                    break;
                }
            }
            if (physical != null) break;
        }
        if (physical == null) return error.MissingVulkanDevice;
        self.physical = physical;
        var props: PhysicalDeviceProperties = undefined;
        self.vk.vkGetPhysicalDeviceProperties(physical, &props);
        self.name = try gpa.dupe(u8, std.mem.sliceTo(&props.deviceName, 0));
        errdefer gpa.free(self.name);

        // device with the features the Vulkan backend needs
        const priority: f32 = 1.0;
        const queue_info: DeviceQueueCreateInfo = .{ .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = @ptrCast(&priority) };
        var maintenance: SwapchainMaintenanceFeatures = .{};
        if (windowed) {
            var count: u32 = 0;
            if (self.vk.vkEnumerateDeviceExtensionProperties(physical, null, &count, null) != SUCCESS or count > 512) return error.ExtensionEnumerationFailed;
            var extensions: [512]ExtensionProperties = undefined;
            if (self.vk.vkEnumerateDeviceExtensionProperties(physical, null, &count, &extensions) != SUCCESS) return error.ExtensionEnumerationFailed;
            var found = false;
            for (extensions[0..count]) |*extension| if (std.mem.eql(u8, std.mem.sliceTo(&extension.name, 0), "VK_EXT_swapchain_maintenance1")) {
                found = true;
                break;
            };
            if (!found) return error.PresentFenceExtensionsUnavailable;
            var query: PhysicalDeviceFeatures2 = .{ .pNext = &maintenance };
            self.vk.vkGetPhysicalDeviceFeatures2(physical, &query);
            if (maintenance.swapchainMaintenance1 == FALSE) return error.PresentFenceFeaturesUnavailable;
        }
        var dbuf_features: PhysicalDeviceDescriptorBufferFeaturesEXT = .{ .sType = 1000316002, .pNext = if (windowed) &maintenance else null, .descriptorBuffer = TRUE };
        var features13: PhysicalDeviceVulkan13Features = .{ .sType = 53, .pNext = if (self.descriptor_buffer) &dbuf_features else if (windowed) &maintenance else null, .dynamicRendering = TRUE, .synchronization2 = TRUE };
        var features12: PhysicalDeviceVulkan12Features = .{ .sType = 51, .pNext = &features13, .bufferDeviceAddress = TRUE };
        var features2: PhysicalDeviceFeatures2 = .{ .sType = 1000059000, .pNext = &features12 };
        var supported: PhysicalDeviceFeatures = undefined;
        self.vk.vkGetPhysicalDeviceFeatures(physical, &supported);
        // Optional capabilities used by the public API must be enabled, rather
        // than merely queried from the physical device. Keep unrelated features off.
        inline for (.{ "imageCubeArray", "independentBlend", "dualSrcBlend", "samplerAnisotropy", "textureCompressionETC2", "textureCompressionASTC_LDR", "textureCompressionBC", "shaderStorageImageExtendedFormats", "vertexPipelineStoresAndAtomics", "fragmentStoresAndAtomics" }) |feature| {
            @field(features2.features, feature) = @field(supported, feature);
        }

        var device_extensions: [3][*:0]const u8 = undefined;
        device_extensions[0] = "VK_KHR_swapchain";
        var extension_count: u32 = 1;
        if (self.descriptor_buffer) {
            device_extensions[extension_count] = "VK_EXT_descriptor_buffer";
            extension_count += 1;
        }
        if (windowed) {
            device_extensions[extension_count] = "VK_EXT_swapchain_maintenance1";
            extension_count += 1;
        }
        const device_info: DeviceCreateInfo = .{
            .pNext = &features2,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = @ptrCast(&queue_info),
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = &device_extensions,
        };
        if (self.vk.vkCreateDevice(physical, &device_info, null, &self.device) != SUCCESS) return error.VulkanInitFailed;
        errdefer self.vk.vkDestroyDevice(self.device, null);
        self.queue = null;
        self.vk.vkGetDeviceQueue(self.device, family, 0, &self.queue);
        self.queue_family_index = family;
        if (comptime builtin.os.tag == .linux or builtin.os.tag == .windows) {
            if (windowed) self.window = try Window.create(self.get_instance, self.instance, self.physical, self.device, self.queue, family);
        }
        return self;
    }

    pub fn destroy(self: *Context) void {
        _ = self.vk.vkDeviceWaitIdle(self.device);
        if (comptime builtin.os.tag == .linux or builtin.os.tag == .windows) {
            if (self.window) |*window| window.deinit();
        }
        self.vk.vkDestroyDevice(self.device, null);
        if (self.messenger != 0) self.vk.vkDestroyDebugUtilsMessengerEXT(self.instance, self.messenger, null);
        self.vk.vkDestroyInstance(self.instance, null);
        self.gpa.free(self.name);
        self.lib.close();
        self.gpa.destroy(self);
    }

    pub fn options(self: *Context) gpu.Options {
        return .{ .backend = .{ .vulkan = .{
            .get_instance_proc_addr = @ptrCast(self.get_instance),
            .instance = @ptrCast(self.instance.?),
            .physical_device = @ptrCast(self.physical.?),
            .device = @ptrCast(self.device.?),
            .queue = @ptrCast(self.queue.?),
            .queue_family_index = self.queue_family_index,
            .use_descriptor_buffer = self.descriptor_buffer,
        } } };
    }

    pub fn description(self: *Context) []const u8 {
        return self.name;
    }

    pub fn acquireSwapchain(self: *Context) !gpu.Swapchain {
        if (comptime builtin.os.tag == .linux or builtin.os.tag == .windows) {
            if (self.window) |*window| return window.acquire();
        }
        return error.NoWindow;
    }

    pub fn present(self: *Context, verify: bool) !void {
        if (comptime builtin.os.tag == .linux or builtin.os.tag == .windows) {
            if (self.window) |*window| return window.present(verify, self.physical);
        }
        return error.NoWindow;
    }

    pub fn takeNativeErrors(self: *Context) u32 {
        return self.native_errors.swap(0, .acq_rel);
    }
};

pub const PhysicalDeviceFeatures2 = extern struct {
    sType: i32 = 1000059000,
    pNext: ?*anyopaque = null,
    features: PhysicalDeviceFeatures = std.mem.zeroes(PhysicalDeviceFeatures),
};
pub const ImageCreateInfo = extern struct {
    sType: i32 = 14,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    imageType: i32 = 0,
    format: i32 = 0,
    extent: Extent3D = std.mem.zeroes(Extent3D),
    mipLevels: u32 = 0,
    arrayLayers: u32 = 0,
    samples: i32 = 0,
    tiling: i32 = 0,
    usage: u32 = 0,
    sharingMode: i32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?*const u32 = null,
    initialLayout: i32 = 0,
};
pub const ImageViewCreateInfo = extern struct {
    sType: i32 = 15,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    image: u64 = 0,
    viewType: i32 = 0,
    format: i32 = 0,
    components: ComponentMapping = std.mem.zeroes(ComponentMapping),
    subresourceRange: ImageSubresourceRange = std.mem.zeroes(ImageSubresourceRange),
};
pub const ImageSubresourceRange = extern struct {
    aspectMask: u32 = 0,
    baseMipLevel: u32 = 0,
    levelCount: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const BufferCreateInfo = extern struct {
    sType: i32 = 12,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    size: u64 = 0,
    usage: u32 = 0,
    sharingMode: i32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?*const u32 = null,
};
pub const MemoryAllocateInfo = extern struct {
    sType: i32 = 5,
    pNext: ?*const anyopaque = null,
    allocationSize: u64 = 0,
    memoryTypeIndex: u32 = 0,
};
pub const PhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32 = 0,
    memoryTypes: [32]MemoryType = std.mem.zeroes([32]MemoryType),
    memoryHeapCount: u32 = 0,
    memoryHeaps: [16]MemoryHeap = std.mem.zeroes([16]MemoryHeap),
};
pub const CommandPoolCreateInfo = extern struct {
    sType: i32 = 39,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    queueFamilyIndex: u32 = 0,
};
pub const CommandBufferAllocateInfo = extern struct {
    sType: i32 = 40,
    pNext: ?*const anyopaque = null,
    commandPool: u64 = 0,
    level: i32 = 0,
    commandBufferCount: u32 = 0,
};
pub const CommandBufferBeginInfo = extern struct {
    sType: i32 = 42,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pInheritanceInfo: ?*const CommandBufferInheritanceInfo = null,
};
pub const SubmitInfo = extern struct {
    sType: i32 = 4,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 0,
    pWaitSemaphores: ?*const u64 = null,
    pWaitDstStageMask: ?*const u32 = null,
    commandBufferCount: u32 = 0,
    pCommandBuffers: ?*const ?*anyopaque = null,
    signalSemaphoreCount: u32 = 0,
    pSignalSemaphores: ?*const u64 = null,
};
pub const FenceCreateInfo = extern struct {
    sType: i32 = 8,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
};
pub const ImageMemoryBarrier2 = extern struct {
    sType: i32 = 1000314002,
    pNext: ?*const anyopaque = null,
    srcStageMask: u64 = 0,
    srcAccessMask: u64 = 0,
    dstStageMask: u64 = 0,
    dstAccessMask: u64 = 0,
    oldLayout: i32 = 0,
    newLayout: i32 = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    image: u64 = 0,
    subresourceRange: ImageSubresourceRange = std.mem.zeroes(ImageSubresourceRange),
};
pub const DependencyInfo = extern struct {
    sType: i32 = 1000314003,
    pNext: ?*const anyopaque = null,
    dependencyFlags: u32 = 0,
    memoryBarrierCount: u32 = 0,
    pMemoryBarriers: ?*const MemoryBarrier2 = null,
    bufferMemoryBarrierCount: u32 = 0,
    pBufferMemoryBarriers: ?*const BufferMemoryBarrier2 = null,
    imageMemoryBarrierCount: u32 = 0,
    pImageMemoryBarriers: ?*const ImageMemoryBarrier2 = null,
};
pub const BufferImageCopy = extern struct {
    bufferOffset: u64 = 0,
    bufferRowLength: u32 = 0,
    bufferImageHeight: u32 = 0,
    imageSubresource: ImageSubresourceLayers = std.mem.zeroes(ImageSubresourceLayers),
    imageOffset: Offset3D = std.mem.zeroes(Offset3D),
    imageExtent: Extent3D = std.mem.zeroes(Extent3D),
};
pub const MemoryRequirements = extern struct {
    size: u64 = 0,
    alignment: u64 = 0,
    memoryTypeBits: u32 = 0,
};
pub const ImageSubresourceLayers = extern struct {
    aspectMask: u32 = 0,
    mipLevel: u32 = 0,
    baseArrayLayer: u32 = 0,
    layerCount: u32 = 0,
};
pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
};
pub const Offset3D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    z: i32 = 0,
};
pub const ComponentMapping = extern struct {
    r: i32 = 0,
    g: i32 = 0,
    b: i32 = 0,
    a: i32 = 0,
};
pub const Extent2D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
};
pub const Offset2D = extern struct {
    x: i32 = 0,
    y: i32 = 0,
};
pub const Rect2D = extern struct {
    offset: Offset2D = std.mem.zeroes(Offset2D),
    extent: Extent2D = std.mem.zeroes(Extent2D),
};
pub const Viewport = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    minDepth: f32 = 0,
    maxDepth: f32 = 0,
};
pub const PhysicalDeviceFeatures = extern struct {
    robustBufferAccess: u32 = 0,
    fullDrawIndexUint32: u32 = 0,
    imageCubeArray: u32 = 0,
    independentBlend: u32 = 0,
    geometryShader: u32 = 0,
    tessellationShader: u32 = 0,
    sampleRateShading: u32 = 0,
    dualSrcBlend: u32 = 0,
    logicOp: u32 = 0,
    multiDrawIndirect: u32 = 0,
    drawIndirectFirstInstance: u32 = 0,
    depthClamp: u32 = 0,
    depthBiasClamp: u32 = 0,
    fillModeNonSolid: u32 = 0,
    depthBounds: u32 = 0,
    wideLines: u32 = 0,
    largePoints: u32 = 0,
    alphaToOne: u32 = 0,
    multiViewport: u32 = 0,
    samplerAnisotropy: u32 = 0,
    textureCompressionETC2: u32 = 0,
    textureCompressionASTC_LDR: u32 = 0,
    textureCompressionBC: u32 = 0,
    occlusionQueryPrecise: u32 = 0,
    pipelineStatisticsQuery: u32 = 0,
    vertexPipelineStoresAndAtomics: u32 = 0,
    fragmentStoresAndAtomics: u32 = 0,
    shaderTessellationAndGeometryPointSize: u32 = 0,
    shaderImageGatherExtended: u32 = 0,
    shaderStorageImageExtendedFormats: u32 = 0,
    shaderStorageImageMultisample: u32 = 0,
    shaderStorageImageReadWithoutFormat: u32 = 0,
    shaderStorageImageWriteWithoutFormat: u32 = 0,
    shaderUniformBufferArrayDynamicIndexing: u32 = 0,
    shaderSampledImageArrayDynamicIndexing: u32 = 0,
    shaderStorageBufferArrayDynamicIndexing: u32 = 0,
    shaderStorageImageArrayDynamicIndexing: u32 = 0,
    shaderClipDistance: u32 = 0,
    shaderCullDistance: u32 = 0,
    shaderFloat64: u32 = 0,
    shaderInt64: u32 = 0,
    shaderInt16: u32 = 0,
    shaderResourceResidency: u32 = 0,
    shaderResourceMinLod: u32 = 0,
    sparseBinding: u32 = 0,
    sparseResidencyBuffer: u32 = 0,
    sparseResidencyImage2D: u32 = 0,
    sparseResidencyImage3D: u32 = 0,
    sparseResidency2Samples: u32 = 0,
    sparseResidency4Samples: u32 = 0,
    sparseResidency8Samples: u32 = 0,
    sparseResidency16Samples: u32 = 0,
    sparseResidencyAliased: u32 = 0,
    variableMultisampleRate: u32 = 0,
    inheritedQueries: u32 = 0,
};
pub const MemoryType = extern struct {
    propertyFlags: u32 = 0,
    heapIndex: u32 = 0,
};
pub const MemoryHeap = extern struct {
    size: u64 = 0,
    flags: u32 = 0,
};
pub const CommandBufferInheritanceInfo = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    renderPass: u64 = 0,
    subpass: u32 = 0,
    framebuffer: u64 = 0,
    occlusionQueryEnable: u32 = 0,
    queryFlags: u32 = 0,
    pipelineStatistics: u32 = 0,
};
pub const MemoryBarrier2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcStageMask: u64 = 0,
    srcAccessMask: u64 = 0,
    dstStageMask: u64 = 0,
    dstAccessMask: u64 = 0,
};
pub const BufferMemoryBarrier2 = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    srcStageMask: u64 = 0,
    srcAccessMask: u64 = 0,
    dstStageMask: u64 = 0,
    dstAccessMask: u64 = 0,
    srcQueueFamilyIndex: u32 = 0,
    dstQueueFamilyIndex: u32 = 0,
    buffer: u64 = 0,
    offset: u64 = 0,
    size: u64 = 0,
};
pub const PhysicalDeviceVulkan12Features = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    samplerMirrorClampToEdge: u32 = 0,
    drawIndirectCount: u32 = 0,
    storageBuffer8BitAccess: u32 = 0,
    uniformAndStorageBuffer8BitAccess: u32 = 0,
    storagePushConstant8: u32 = 0,
    shaderBufferInt64Atomics: u32 = 0,
    shaderSharedInt64Atomics: u32 = 0,
    shaderFloat16: u32 = 0,
    shaderInt8: u32 = 0,
    descriptorIndexing: u32 = 0,
    shaderInputAttachmentArrayDynamicIndexing: u32 = 0,
    shaderUniformTexelBufferArrayDynamicIndexing: u32 = 0,
    shaderStorageTexelBufferArrayDynamicIndexing: u32 = 0,
    shaderUniformBufferArrayNonUniformIndexing: u32 = 0,
    shaderSampledImageArrayNonUniformIndexing: u32 = 0,
    shaderStorageBufferArrayNonUniformIndexing: u32 = 0,
    shaderStorageImageArrayNonUniformIndexing: u32 = 0,
    shaderInputAttachmentArrayNonUniformIndexing: u32 = 0,
    shaderUniformTexelBufferArrayNonUniformIndexing: u32 = 0,
    shaderStorageTexelBufferArrayNonUniformIndexing: u32 = 0,
    descriptorBindingUniformBufferUpdateAfterBind: u32 = 0,
    descriptorBindingSampledImageUpdateAfterBind: u32 = 0,
    descriptorBindingStorageImageUpdateAfterBind: u32 = 0,
    descriptorBindingStorageBufferUpdateAfterBind: u32 = 0,
    descriptorBindingUniformTexelBufferUpdateAfterBind: u32 = 0,
    descriptorBindingStorageTexelBufferUpdateAfterBind: u32 = 0,
    descriptorBindingUpdateUnusedWhilePending: u32 = 0,
    descriptorBindingPartiallyBound: u32 = 0,
    descriptorBindingVariableDescriptorCount: u32 = 0,
    runtimeDescriptorArray: u32 = 0,
    samplerFilterMinmax: u32 = 0,
    scalarBlockLayout: u32 = 0,
    imagelessFramebuffer: u32 = 0,
    uniformBufferStandardLayout: u32 = 0,
    shaderSubgroupExtendedTypes: u32 = 0,
    separateDepthStencilLayouts: u32 = 0,
    hostQueryReset: u32 = 0,
    timelineSemaphore: u32 = 0,
    bufferDeviceAddress: u32 = 0,
    bufferDeviceAddressCaptureReplay: u32 = 0,
    bufferDeviceAddressMultiDevice: u32 = 0,
    vulkanMemoryModel: u32 = 0,
    vulkanMemoryModelDeviceScope: u32 = 0,
    vulkanMemoryModelAvailabilityVisibilityChains: u32 = 0,
    shaderOutputViewportIndex: u32 = 0,
    shaderOutputLayer: u32 = 0,
    subgroupBroadcastDynamicId: u32 = 0,
};
pub const PhysicalDeviceVulkan13Features = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    robustImageAccess: u32 = 0,
    inlineUniformBlock: u32 = 0,
    descriptorBindingInlineUniformBlockUpdateAfterBind: u32 = 0,
    pipelineCreationCacheControl: u32 = 0,
    privateData: u32 = 0,
    shaderDemoteToHelperInvocation: u32 = 0,
    shaderTerminateInvocation: u32 = 0,
    subgroupSizeControl: u32 = 0,
    computeFullSubgroups: u32 = 0,
    synchronization2: u32 = 0,
    textureCompressionASTC_HDR: u32 = 0,
    shaderZeroInitializeWorkgroupMemory: u32 = 0,
    dynamicRendering: u32 = 0,
    shaderIntegerDotProduct: u32 = 0,
    maintenance4: u32 = 0,
};
pub const PhysicalDeviceDescriptorBufferFeaturesEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*anyopaque = null,
    descriptorBuffer: u32 = 0,
    descriptorBufferCaptureReplay: u32 = 0,
    descriptorBufferImageLayoutIgnored: u32 = 0,
    descriptorBufferPushDescriptors: u32 = 0,
};
pub const QueueFamilyProperties = extern struct {
    queueFlags: u32 = 0,
    queueCount: u32 = 0,
    timestampValidBits: u32 = 0,
    minImageTransferGranularity: Extent3D = std.mem.zeroes(Extent3D),
};
pub const SemaphoreCreateInfo = extern struct {
    sType: i32 = 9,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
};
pub const LayerProperties = extern struct {
    layerName: [256]u8 = std.mem.zeroes([256]u8),
    specVersion: u32 = 0,
    implementationVersion: u32 = 0,
    description: [VK_MAX_DESCRIPTION_SIZE]u8 = std.mem.zeroes([VK_MAX_DESCRIPTION_SIZE]u8),
};
pub const DebugUtilsMessengerCallbackDataEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    pMessageIdName: ?[*:0]const u8 = null,
    messageIdNumber: i32 = 0,
    pMessage: ?[*:0]const u8 = null,
    queueLabelCount: u32 = 0,
    pQueueLabels: ?*const DebugUtilsLabelEXT = null,
    cmdBufLabelCount: u32 = 0,
    pCmdBufLabels: ?*const DebugUtilsLabelEXT = null,
    objectCount: u32 = 0,
    pObjects: ?*const DebugUtilsObjectNameInfoEXT = null,
};
pub const DebugUtilsLabelEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    pLabelName: ?[*:0]const u8 = null,
    color: [4]f32 = std.mem.zeroes([4]f32),
};
pub const DebugUtilsObjectNameInfoEXT = extern struct {
    sType: i32 = 0,
    pNext: ?*const anyopaque = null,
    objectType: i32 = 0,
    objectHandle: u64 = 0,
    pObjectName: ?[*:0]const u8 = null,
};
pub const PhysicalDeviceProperties = extern struct {
    apiVersion: u32 = 0,
    driverVersion: u32 = 0,
    vendorID: u32 = 0,
    deviceID: u32 = 0,
    deviceType: i32 = 0,
    deviceName: [256]u8 = std.mem.zeroes([256]u8),
    pipelineCacheUUID: [16]u8 = std.mem.zeroes([16]u8),
    limits: PhysicalDeviceLimits = std.mem.zeroes(PhysicalDeviceLimits),
    sparseProperties: PhysicalDeviceSparseProperties = std.mem.zeroes(PhysicalDeviceSparseProperties),
};

pub const PhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32 = 0,
    maxImageDimension2D: u32 = 0,
    maxImageDimension3D: u32 = 0,
    maxImageDimensionCube: u32 = 0,
    maxImageArrayLayers: u32 = 0,
    maxTexelBufferElements: u32 = 0,
    maxUniformBufferRange: u32 = 0,
    maxStorageBufferRange: u32 = 0,
    maxPushConstantsSize: u32 = 0,
    maxMemoryAllocationCount: u32 = 0,
    maxSamplerAllocationCount: u32 = 0,
    bufferImageGranularity: u64 = 0,
    sparseAddressSpaceSize: u64 = 0,
    maxBoundDescriptorSets: u32 = 0,
    maxPerStageDescriptorSamplers: u32 = 0,
    maxPerStageDescriptorUniformBuffers: u32 = 0,
    maxPerStageDescriptorStorageBuffers: u32 = 0,
    maxPerStageDescriptorSampledImages: u32 = 0,
    maxPerStageDescriptorStorageImages: u32 = 0,
    maxPerStageDescriptorInputAttachments: u32 = 0,
    maxPerStageResources: u32 = 0,
    maxDescriptorSetSamplers: u32 = 0,
    maxDescriptorSetUniformBuffers: u32 = 0,
    maxDescriptorSetUniformBuffersDynamic: u32 = 0,
    maxDescriptorSetStorageBuffers: u32 = 0,
    maxDescriptorSetStorageBuffersDynamic: u32 = 0,
    maxDescriptorSetSampledImages: u32 = 0,
    maxDescriptorSetStorageImages: u32 = 0,
    maxDescriptorSetInputAttachments: u32 = 0,
    maxVertexInputAttributes: u32 = 0,
    maxVertexInputBindings: u32 = 0,
    maxVertexInputAttributeOffset: u32 = 0,
    maxVertexInputBindingStride: u32 = 0,
    maxVertexOutputComponents: u32 = 0,
    maxTessellationGenerationLevel: u32 = 0,
    maxTessellationPatchSize: u32 = 0,
    maxTessellationControlPerVertexInputComponents: u32 = 0,
    maxTessellationControlPerVertexOutputComponents: u32 = 0,
    maxTessellationControlPerPatchOutputComponents: u32 = 0,
    maxTessellationControlTotalOutputComponents: u32 = 0,
    maxTessellationEvaluationInputComponents: u32 = 0,
    maxTessellationEvaluationOutputComponents: u32 = 0,
    maxGeometryShaderInvocations: u32 = 0,
    maxGeometryInputComponents: u32 = 0,
    maxGeometryOutputComponents: u32 = 0,
    maxGeometryOutputVertices: u32 = 0,
    maxGeometryTotalOutputComponents: u32 = 0,
    maxFragmentInputComponents: u32 = 0,
    maxFragmentOutputAttachments: u32 = 0,
    maxFragmentDualSrcAttachments: u32 = 0,
    maxFragmentCombinedOutputResources: u32 = 0,
    maxComputeSharedMemorySize: u32 = 0,
    maxComputeWorkGroupCount: [3]u32 = std.mem.zeroes([3]u32),
    maxComputeWorkGroupInvocations: u32 = 0,
    maxComputeWorkGroupSize: [3]u32 = std.mem.zeroes([3]u32),
    subPixelPrecisionBits: u32 = 0,
    subTexelPrecisionBits: u32 = 0,
    mipmapPrecisionBits: u32 = 0,
    maxDrawIndexedIndexValue: u32 = 0,
    maxDrawIndirectCount: u32 = 0,
    maxSamplerLodBias: f32 = 0,
    maxSamplerAnisotropy: f32 = 0,
    maxViewports: u32 = 0,
    maxViewportDimensions: [2]u32 = std.mem.zeroes([2]u32),
    viewportBoundsRange: [2]f32 = std.mem.zeroes([2]f32),
    viewportSubPixelBits: u32 = 0,
    minMemoryMapAlignment: usize = 0,
    minTexelBufferOffsetAlignment: u64 = 0,
    minUniformBufferOffsetAlignment: u64 = 0,
    minStorageBufferOffsetAlignment: u64 = 0,
    minTexelOffset: i32 = 0,
    maxTexelOffset: u32 = 0,
    minTexelGatherOffset: i32 = 0,
    maxTexelGatherOffset: u32 = 0,
    minInterpolationOffset: f32 = 0,
    maxInterpolationOffset: f32 = 0,
    subPixelInterpolationOffsetBits: u32 = 0,
    maxFramebufferWidth: u32 = 0,
    maxFramebufferHeight: u32 = 0,
    maxFramebufferLayers: u32 = 0,
    framebufferColorSampleCounts: u32 = 0,
    framebufferDepthSampleCounts: u32 = 0,
    framebufferStencilSampleCounts: u32 = 0,
    framebufferNoAttachmentsSampleCounts: u32 = 0,
    maxColorAttachments: u32 = 0,
    sampledImageColorSampleCounts: u32 = 0,
    sampledImageIntegerSampleCounts: u32 = 0,
    sampledImageDepthSampleCounts: u32 = 0,
    sampledImageStencilSampleCounts: u32 = 0,
    storageImageSampleCounts: u32 = 0,
    maxSampleMaskWords: u32 = 0,
    timestampComputeAndGraphics: u32 = 0,
    timestampPeriod: f32 = 0,
    maxClipDistances: u32 = 0,
    maxCullDistances: u32 = 0,
    maxCombinedClipAndCullDistances: u32 = 0,
    discreteQueuePriorities: u32 = 0,
    pointSizeRange: [2]f32 = std.mem.zeroes([2]f32),
    lineWidthRange: [2]f32 = std.mem.zeroes([2]f32),
    pointSizeGranularity: f32 = 0,
    lineWidthGranularity: f32 = 0,
    strictLines: u32 = 0,
    standardSampleLocations: u32 = 0,
    optimalBufferCopyOffsetAlignment: u64 = 0,
    optimalBufferCopyRowPitchAlignment: u64 = 0,
    nonCoherentAtomSize: u64 = 0,
};

pub const PhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: u32 = 0,
    residencyStandard2DMultisampleBlockShape: u32 = 0,
    residencyStandard3DBlockShape: u32 = 0,
    residencyAlignedMipSize: u32 = 0,
    residencyNonResidentStrict: u32 = 0,
};

const ValidationFeatures = extern struct {
    sType: u32 = 1000247000,
    pNext: ?*const anyopaque = null,
    enabledValidationFeatureCount: u32 = 0,
    pEnabledValidationFeatures: ?[*]const u32 = null,
    disabledValidationFeatureCount: u32 = 0,
    pDisabledValidationFeatures: ?[*]const u32 = null,
};
