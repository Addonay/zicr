//! Native Vulkan verification (`zig build test-vk`). Creates a Vulkan 1.3
//! instance and device with the libvulkan loader, runs the sokol_gfx Vulkan
//! backend in a swapchain-style pass into an app-provided VkImage and reads the
//! pixels back with Vulkan copy commands. Exercises a compute shader that writes a
//! storage buffer, a uniform block, vertex and index buffers, a texture with a
//! sampler, and a second frame with changed uniform data.
//! The structs below are the Vulkan ABI as generated from vulkan_core.h; only the
//! handful of entry points this test needs are declared.
const std = @import("std");
const gfx = @import("zicr").gpu.raw;

const Instance = ?*anyopaque;
const PhysicalDevice = ?*anyopaque;
const Device = ?*anyopaque;
const Queue = ?*anyopaque;
const CommandBuffer = ?*anyopaque;
const AllocationCallbacks = anyopaque;
const DebugUtilsMessengerEXT = u64;
const GetInstanceProcAddr = *const fn (Instance, [*:0]const u8) callconv(.c) ?*const anyopaque;
const GetDeviceProcAddr = *const fn (Device, [*:0]const u8) callconv(.c) ?*const anyopaque;

const VK_MAX_DESCRIPTION_SIZE = 256;
const SUCCESS = 0;
const TRUE = 1;
const FALSE = 0;
const QUEUE_FAMILY_IGNORED: u32 = ~@as(u32, 0);
const QUEUE_GRAPHICS_COMPUTE_TRANSFER: u32 = 0x1 | 0x2 | 0x4;
const WHOLE_SIZE: u64 = ~@as(u64, 0);
const API_VERSION_1_3: u32 = (1 << 22) | (3 << 12);
const IMAGE_LAYOUT_UNDEFINED = 0;
const IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL = 6;
const IMAGE_LAYOUT_PRESENT_SRC_KHR = 1000001002;
const FORMAT_R8G8B8A8_UNORM = 37;
const DEBUG_SEVERITY_ERROR: u32 = 0x1000;
const DEBUG_SEVERITY_WARNING: u32 = 0x100;
const DEBUG_TYPE_ALL: u32 = 0x7;
const PIPELINE_STAGE_TRANSFER_BIT: u32 = 0x1000;
const PIPELINE_STAGE_2_ALL_COMMANDS_BIT: u64 = 0x10000;
const PIPELINE_STAGE_2_COPY_BIT: u64 = 0x100000000;
const ACCESS_2_MEMORY_WRITE_BIT: u64 = 0x10000;
const ACCESS_2_TRANSFER_READ_BIT: u64 = 0x800;
const ACCESS_2_TRANSFER_WRITE_BIT: u64 = 0x1000;
const MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x1;
const MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x2;
const MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x4;
const COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: u32 = 0x2;
const COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x1;
const IMAGE_ASPECT_COLOR_BIT: u32 = 0x1;
const IMAGE_USAGE_TRANSFER_SRC_BIT: u32 = 0x1;
const IMAGE_USAGE_COLOR_ATTACHMENT_BIT: u32 = 0x10;
const BUFFER_USAGE_TRANSFER_DST_BIT: u32 = 0x2;
const BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 0x1;

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

/// Entry points of the loader and the driver used by this test.
const Vk = struct {
    vkCreateInstance: *const fn (*const InstanceCreateInfo, ?*const AllocationCallbacks, *Instance) callconv(.c) i32 = undefined,
    vkEnumerateInstanceLayerProperties: *const fn (*u32, ?[*]LayerProperties) callconv(.c) i32 = undefined,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.c) i32 = undefined,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.c) void = undefined,
    vkGetPhysicalDeviceMemoryProperties: *const fn (PhysicalDevice, *PhysicalDeviceMemoryProperties) callconv(.c) void = undefined,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, ?*const AllocationCallbacks, *Device) callconv(.c) i32 = undefined,
    vkCreateDebugUtilsMessengerEXT: *const fn (Instance, *const DebugUtilsMessengerCreateInfoEXT, ?*const AllocationCallbacks, *DebugUtilsMessengerEXT) callconv(.c) i32 = undefined,
    vkDeviceWaitIdle: *const fn (Device) callconv(.c) i32 = undefined,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *Queue) callconv(.c) void = undefined,
    vkCreateImage: *const fn (Device, *const ImageCreateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkGetImageMemoryRequirements: *const fn (Device, u64, *MemoryRequirements) callconv(.c) void = undefined,
    vkAllocateMemory: *const fn (Device, *const MemoryAllocateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkBindImageMemory: *const fn (Device, u64, u64, u64) callconv(.c) i32 = undefined,
    vkCreateImageView: *const fn (Device, *const ImageViewCreateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkCreateBuffer: *const fn (Device, *const BufferCreateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkGetBufferMemoryRequirements: *const fn (Device, u64, *MemoryRequirements) callconv(.c) void = undefined,
    vkBindBufferMemory: *const fn (Device, u64, u64, u64) callconv(.c) i32 = undefined,
    vkMapMemory: *const fn (Device, u64, u64, u64, u32, *?*anyopaque) callconv(.c) i32 = undefined,
    vkUnmapMemory: *const fn (Device, u64) callconv(.c) void = undefined,
    vkCreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkCreateFence: *const fn (Device, *const FenceCreateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkWaitForFences: *const fn (Device, u32, *const u64, u32, u64) callconv(.c) i32 = undefined,
    vkResetFences: *const fn (Device, u32, *const u64) callconv(.c) i32 = undefined,
    vkCreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, ?*const AllocationCallbacks, *u64) callconv(.c) i32 = undefined,
    vkAllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, *CommandBuffer) callconv(.c) i32 = undefined,
    vkResetCommandBuffer: *const fn (CommandBuffer, u32) callconv(.c) i32 = undefined,
    vkBeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.c) i32 = undefined,
    vkEndCommandBuffer: *const fn (CommandBuffer) callconv(.c) i32 = undefined,
    vkQueueSubmit: *const fn (Queue, u32, *const SubmitInfo, u64) callconv(.c) i32 = undefined,
    vkQueueWaitIdle: *const fn (Queue) callconv(.c) i32 = undefined,
    vkCmdPipelineBarrier2: *const fn (CommandBuffer, *const DependencyInfo) callconv(.c) void = undefined,
    vkCmdCopyImageToBuffer: *const fn (CommandBuffer, u64, i32, u64, u32, [*]const BufferImageCopy) callconv(.c) void = undefined,
};

/// Loads the entry points named by the fields of `Vk`; absent ones stay null.
fn loadVk(out: *Vk, get: anytype, handle: anytype) !void {
    inline for (@typeInfo(Vk).@"struct".field_names) |name| {
        if (get(handle, name.ptr)) |proc| @field(out, name) = @ptrCast(proc);
    }
}

var error_count: u32 = 0;
fn debugCallback(severity: u32, _: u32, data: *const DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) u32 {
    if (severity & DEBUG_SEVERITY_ERROR != 0) error_count += 1;
    if (severity & (DEBUG_SEVERITY_ERROR | DEBUG_SEVERITY_WARNING) != 0) {
        const message = if (data.pMessage) |m| std.mem.span(m) else "";
        std.debug.print("VALIDATION severity=0x{x}: {s}\n", .{ severity, message });
    }
    return FALSE;
}

fn gfxLogger(_: ?[*:0]const u8, level: u32, item: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    std.debug.print("sokol log level={d} item={d}: {s}\n", .{ level, item, if (message) |value| std.mem.span(value) else "" });
}

const vs_bytes = @embedFile("shaders/tri.vert.spv");
const fs_bytes = @embedFile("shaders/tri.frag.spv");
const cs_bytes = @embedFile("shaders/fill.comp.spv");
/// SPIR-V words must be 4-byte aligned, so the embedded blobs are copied into aligned storage.
var vs_code: [vs_bytes.len]u8 align(4) = vs_bytes.*;
var fs_code: [fs_bytes.len]u8 align(4) = fs_bytes.*;
var cs_code: [cs_bytes.len]u8 align(4) = cs_bytes.*;

const width = 64;
const height = 64;
const quad_vertices = [_]f32{
    // position, texcoord
    -0.5, -0.5, 0, 0,
    0.5,  -0.5, 1, 0,
    0.5,  0.5,  1, 1,
    -0.5, 0.5,  0, 1,
};
const quad_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
/// 2x2 RGBA8 texels, row 0 first: red, green / blue, white.
const texels = [_]u8{
    255, 0, 0,   255, 0,   255, 0,   255,
    0,   0, 255, 255, 255, 255, 255, 255,
};

const ClearColor = [4]u8{ 0, 0, 255, 255 };

/// Expected pixel for the smoke frame, computed independently of the GPU.
fn expectedPixel(x: usize, y: usize, mul: [4]u8) [4]u8 {
    const ndc_x = 2.0 * (@as(f64, @floatFromInt(x)) + 0.5) / width - 1.0;
    const ndc_y = 1.0 - 2.0 * (@as(f64, @floatFromInt(y)) + 0.5) / height;
    if (@abs(ndc_x) > 0.5 or @abs(ndc_y) > 0.5) return ClearColor;
    const u = ndc_x + 0.5;
    const v = ndc_y + 0.5;
    const col: usize = @min(@as(usize, @intFromFloat(@floor(u * 2))), 1);
    const row: usize = @min(@as(usize, @intFromFloat(@floor(v * 2))), 1);
    const texel = texels[(row * 2 + col) * 4 ..][0..4];
    var result: [4]u8 = undefined;
    for (0..4) |c| result[c] = @intCast(@as(u32, texel[c]) * mul[c] / 255);
    return result;
}
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

// ---------------------------------------------------------------- shared test context

const color_vs = @embedFile("shaders/color.vert.spv");
const color_fs = @embedFile("shaders/color.frag.spv");
const tex_fs = @embedFile("shaders/tex.frag.spv");
const img_cs = @embedFile("shaders/img.comp.spv");
var color_vs_code: [color_vs.len]u8 align(4) = color_vs.*;
var color_fs_code: [color_fs.len]u8 align(4) = color_fs.*;
var tex_fs_code: [tex_fs.len]u8 align(4) = tex_fs.*;
var img_cs_code: [img_cs.len]u8 align(4) = img_cs.*;

const Pixels = [width * height][4]u8;
const Ctx = struct {
    device: Device,
    queue: Queue,
    fns: Vk,
    mem_props: PhysicalDeviceMemoryProperties,
    target: u64,
    target_view: u64,
    present_sem: u64,
    render_sem: u64,
    fence: u64,
    cmd: CommandBuffer,
    readback: u64,
    readback_mem: u64,
};

fn rgba(c: [4]f32) [4]u8 {
    var r: [4]u8 = undefined;
    for (0..4) |i| r[i] = @intFromFloat(@round(c[i] * 255));
    return r;
}

/// Fills `out` from a function of the pixel coordinates.
fn fillPixels(out: *Pixels, comptime f: fn (usize, usize) [4]u8) void {
    for (0..height) |y| {
        for (0..width) |x| out[y * width + x] = f(x, y);
    }
}

/// Texel of a 2x2 texture that covers the whole target (identity uv mapping).
fn texelAt(texels2x2: *const [4][4]u8, x: usize, y: usize) [4]u8 {
    return texels2x2[(y / 32) * 2 + x / 32];
}

fn presignal(ctx: *Ctx) !void {
    const signal_info: SubmitInfo = .{ .signalSemaphoreCount = 1, .pSignalSemaphores = @ptrCast(&ctx.present_sem) };
    if (ctx.fns.vkQueueSubmit(ctx.queue, 1, &signal_info, 0) != SUCCESS) return error.VulkanSubmitFailed;
}

/// Swapchain-style pass into the app-provided target image.
fn targetPass(ctx: *Ctx, clear: [4]f32) gfx.Pass {
    var pass: gfx.Pass = .{};
    pass.action.colors[0] = .{ .load_action = .clear, .store_action = .store, .clear_value = .{ .r = clear[0], .g = clear[1], .b = clear[2], .a = clear[3] } };
    pass.swapchain = .{
        .width = width,
        .height = height,
        .sample_count = 1,
        .color_format = .rgba8,
        .depth_format = .none,
        .vulkan = .{
            .render_image = @ptrFromInt(ctx.target),
            .render_view = @ptrFromInt(ctx.target_view),
            .present_complete_semaphore = @ptrFromInt(ctx.present_sem),
            .render_finished_semaphore = @ptrFromInt(ctx.render_sem),
        },
    };
    return pass;
}

/// Reads the target image back after gfx.commit() has submitted the frame.
fn readback(ctx: *Ctx, out: *Pixels) !void {
    const fns = &ctx.fns;
    _ = fns.vkResetFences(ctx.device, 1, &ctx.fence);
    _ = fns.vkResetCommandBuffer(ctx.cmd, 0);
    const begin: CommandBufferBeginInfo = .{ .flags = COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    _ = fns.vkBeginCommandBuffer(ctx.cmd, &begin);
    const to_src: ImageMemoryBarrier2 = .{
        .srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .srcAccessMask = ACCESS_2_MEMORY_WRITE_BIT,
        .dstStageMask = PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
        .oldLayout = IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = QUEUE_FAMILY_IGNORED,
        .image = ctx.target,
        .subresourceRange = .{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
    };
    const dep: DependencyInfo = .{ .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = @ptrCast(&to_src) };
    fns.vkCmdPipelineBarrier2(ctx.cmd, &dep);
    const region: BufferImageCopy = .{
        .imageSubresource = .{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
        .imageExtent = .{ .width = width, .height = height, .depth = 1 },
    };
    fns.vkCmdCopyImageToBuffer(ctx.cmd, ctx.target, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, ctx.readback, 1, @ptrCast(&region));
    _ = fns.vkEndCommandBuffer(ctx.cmd);
    const wait_stage: u32 = PIPELINE_STAGE_TRANSFER_BIT;
    const submit: SubmitInfo = .{
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = @ptrCast(&ctx.render_sem),
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast(&ctx.cmd),
    };
    if (fns.vkQueueSubmit(ctx.queue, 1, &submit, ctx.fence) != SUCCESS) return error.VulkanSubmitFailed;
    _ = fns.vkWaitForFences(ctx.device, 1, &ctx.fence, TRUE, std.math.maxInt(u64));
    var mapped: ?*anyopaque = null;
    if (fns.vkMapMemory(ctx.device, ctx.readback_mem, 0, WHOLE_SIZE, 0, &mapped) != SUCCESS) return error.VulkanMapFailed;
    const pixels: [*]const [4]u8 = @ptrCast(@alignCast(mapped.?));
    @memcpy(out, pixels[0 .. width * height]);
    fns.vkUnmapMemory(ctx.device, ctx.readback_mem);
}

fn check(name: []const u8, actual: *const Pixels, expected: *const Pixels) !void {
    var mismatches: u32 = 0;
    for (actual, expected, 0..) |a, e, i| {
        if (!std.mem.eql(u8, &a, &e)) {
            if (mismatches < 4) std.debug.print("  {s}: pixel ({d},{d}) got {any} expected {any}\n", .{ name, i % width, i / width, a, e });
            mismatches += 1;
        }
    }
    if (mismatches != 0) {
        std.debug.print("FAIL {s}: {d} mismatching pixels\n", .{ name, mismatches });
        return error.PixelMismatch;
    }
    std.debug.print("pass {s}\n", .{name});
}

/// Writes four vertices (position xyz, color rgba) of a quad at depth z into `out[0..28]`.
fn fillColorQuad(out: []f32, x0: f32, y0: f32, x1: f32, y1: f32, z: f32, c: [4]f32) void {
    const corners = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    for (corners, 0..) |p, v| {
        const o = v * 7;
        out[o] = p[0];
        out[o + 1] = p[1];
        out[o + 2] = z;
        for (0..4) |c_i| out[o + 3 + c_i] = c[c_i];
    }
}

/// Full-screen textured quad: position xy, texcoord uv, with identity mapping to the target.
const tex_full = [_]f32{ -1, -1, 0, 1, 1, -1, 1, 1, 1, 1, 1, 0, -1, 1, 0, 0 };
const quad_idx = [_]u16{ 0, 1, 2, 0, 2, 3 };
const color_layout = blk: {
    var l: gfx.VertexLayoutState = .{};
    l.buffers[0] = .{ .stride = 28 };
    l.attrs[0] = .{ .buffer_index = 0, .offset = 0, .format = .float3 };
    l.attrs[1] = .{ .buffer_index = 0, .offset = 12, .format = .float4 };
    break :blk l;
};
const tex_layout = blk: {
    var l: gfx.VertexLayoutState = .{};
    l.buffers[0] = .{ .stride = 16 };
    l.attrs[0] = .{ .buffer_index = 0, .offset = 0, .format = .float2 };
    l.attrs[1] = .{ .buffer_index = 0, .offset = 8, .format = .float2 };
    break :blk l;
};

fn colorShader() gfx.Shader {
    const desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .bytecode = gfx.Range.fromSlice(u8, &color_vs_code), .entry = "main" },
        .fragment_func = .{ .bytecode = gfx.Range.fromSlice(u8, &color_fs_code), .entry = "main" },
    };
    return gfx.makeShader(desc);
}

fn texShader() gfx.Shader {
    var desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .bytecode = gfx.Range.fromSlice(u8, &vs_code), .entry = "main" },
        .fragment_func = .{ .bytecode = gfx.Range.fromSlice(u8, &tex_fs_code), .entry = "main" },
    };
    desc.views[0].texture = .{ .stage = .fragment, .image_type = .@"2d", .sample_type = .float, .spirv_set1_binding_n = 0 };
    desc.samplers[0] = .{ .stage = .fragment, .sampler_type = .filtering, .spirv_set1_binding_n = 1 };
    desc.texture_sampler_pairs[0] = .{ .stage = .fragment, .view_slot = 0, .sampler_slot = 0 };
    return gfx.makeShader(desc);
}

fn valid(state: gfx.ResourceState, what: []const u8) !void {
    if (state != .valid and state != .unsealed) {
        std.debug.print("resource creation failed: {s}\n", .{what});
        return error.ResourceCreationFailed;
    }
}

/// Ends the frame: commit, read back the target and compare with `expected`.
fn finish(ctx: *Ctx, name: []const u8, expected: *const Pixels) !void {
    gfx.commit();
    var actual: Pixels = undefined;
    try readback(ctx, &actual);
    try check(name, &actual, expected);
}

fn solid(c: [4]u8) Pixels {
    var p: Pixels = undefined;
    @memset(&p, c);
    return p;
}

fn colorPipeline(shd: gfx.Shader, depth: gfx.DepthState, color: gfx.ColorTargetState, sample_count: i32) !gfx.Pipeline {
    var desc: gfx.PipelineDesc = .{ .shader = shd, .layout = color_layout, .index_type = .uint16, .cull_mode = .none, .depth = depth, .color_count = 1, .sample_count = sample_count };
    desc.colors[0] = color;
    return mustPipeline(desc);
}

fn mustPipeline(desc: gfx.PipelineDesc) !gfx.Pipeline {
    const p = gfx.makePipeline(desc);
    try valid(gfx.queryPipelineState(p), "pipeline");
    return p;
}

const no_depth: gfx.DepthState = .{ .pixel_format = .none, .compare = .always };
const rgba_target: gfx.ColorTargetState = .{ .pixel_format = .rgba8 };

/// Draws `pip` with the given vertex and index buffers into the bound pass.
fn drawWith(pip: gfx.Pipeline, vb: gfx.Buffer, ib: gfx.Buffer, base: i32, count: i32) void {
    gfx.applyPipeline(pip);
    var bnd: gfx.Bindings = .{};
    bnd.vertex_buffers[0] = vb;
    bnd.index_buffer = ib;
    gfx.applyBindings(bnd);
    gfx.draw(base, count, 1);
}

// 1. write_buffer_transient vertex data, 3 frames with changing data
fn scenarioTransient(ctx: *Ctx) !void {
    const shd = colorShader();
    const pip = try colorPipeline(shd, no_depth, rgba_target, 1);
    const vb = gfx.makeBuffer(.{ .size = 28 * 4 * 4, .usage = .{ .vertex_buffer = true, .write_transient = true } });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    try valid(gfx.queryBufferState(vb), "transient vb");
    const colors = [3][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 0, 0, 1, 1 } };
    for (colors, 0..) |c, frame| {
        var verts: [28]f32 = undefined;
        fillColorQuad(&verts, -0.5, -0.5, 0.5, 0.5, 0.5, c);
        try presignal(ctx);
        gfx.writeBufferTransient(.{ .src = .{ .data = gfx.Range.fromSlice(f32, &verts), .offset = 0 }, .dst = .{ .buffer = vb, .offset = 0 }, .size = @sizeOf(@TypeOf(verts)) });
        gfx.beginPass(targetPass(ctx, .{ 0, 0, 0, 1 }));
        drawWith(pip, vb, ib, 0, 6);
        gfx.endPass();
        var expected: Pixels = undefined;
        for (0..height) |y| for (0..width) |x| {
            const inside = x >= 16 and x < 48 and y >= 16 and y < 48;
            expected[y * width + x] = if (inside) rgba(c) else .{ 0, 0, 0, 255 };
        };
        var name_buf: [96]u8 = undefined;
        try finish(ctx, try std.fmt.bufPrint(&name_buf, "1 transient vertex frame {d}", .{frame}), &expected);
    }
    gfx.destroyBuffer(vb);
    gfx.destroyBuffer(ib);
    gfx.destroyPipeline(pip);
    gfx.destroyShader(shd);
}

const pattern_a = [4][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 255, 255 } };
const pattern_b = [4][4]u8{ .{ 255, 255, 0, 255 }, .{ 0, 0, 0, 255 }, .{ 255, 0, 255, 255 }, .{ 0, 255, 255, 255 } };
const pattern_c = [4][4]u8{ .{ 0, 0, 0, 255 }, .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 } };

fn texPipeline(shd: gfx.Shader) !gfx.Pipeline {
    var desc: gfx.PipelineDesc = .{ .shader = shd, .layout = tex_layout, .index_type = .uint16, .cull_mode = .none, .depth = no_depth, .color_count = 1 };
    desc.colors[0] = rgba_target;
    return mustPipeline(desc);
}

/// Draws the full-screen textured quad sampling `tex_view` with `smp` into the target.
fn sampleTarget(ctx: *Ctx, pip: gfx.Pipeline, vb: gfx.Buffer, ib: gfx.Buffer, tex_view: gfx.View, smp: gfx.Sampler, clear: [4]f32) void {
    gfx.beginPass(targetPass(ctx, clear));
    gfx.applyPipeline(pip);
    var bnd: gfx.Bindings = .{};
    bnd.vertex_buffers[0] = vb;
    bnd.index_buffer = ib;
    bnd.views[0] = tex_view;
    bnd.samplers[0] = smp;
    gfx.applyBindings(bnd);
    gfx.draw(0, 6, 1);
    gfx.endPass();
}

fn nearestSampler() gfx.Sampler {
    return gfx.makeSampler(.{ .min_filter = .nearest, .mag_filter = .nearest, .mipmap_filter = .nearest, .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
}

fn texelFromPattern(p: *const [4][4]u8) [4][4]u8 {
    return p.*;
}

// 2. write_image_transient, texture updated every frame
fn scenarioImageTransient(ctx: *Ctx) !void {
    const shd = texShader();
    const pip = try texPipeline(shd);
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &tex_full) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    const img = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .write_transient = true } });
    const view = gfx.makeView(.{ .texture = .{ .image = img } });
    const smp = nearestSampler();
    try valid(gfx.queryImageState(img), "transient image");
    try valid(gfx.queryViewState(view), "transient image view");
    const patterns = [_]*const [4][4]u8{ &pattern_a, &pattern_b, &pattern_c };
    for (patterns, 0..) |pat, frame| {
        try presignal(ctx);
        gfx.writeImageTransient(.{
            .src = .{ .data = gfx.Range.fromSlice(u8, std.mem.sliceAsBytes(pat)), .offset = 0, .bytes_per_row = 8, .bytes_per_slice = 16 },
            .dst = .{ .image = img, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
            .size = .{ .width = 2, .height = 2, .num_slices = 1 },
        });
        sampleTarget(ctx, pip, vb, ib, view, smp, .{ 0, 0, 0, 1 });
        var expected: Pixels = undefined;
        for (0..height) |y| for (0..width) |x| {
            expected[y * width + x] = texelAt(pat, x, y);
        };
        var name_buf: [96]u8 = undefined;
        try finish(ctx, try std.fmt.bufPrint(&name_buf, "2 transient image frame {d}", .{frame}), &expected);
    }
}

// 3. write_unsealed buffer and image, sealed, then used
fn scenarioUnsealed(ctx: *Ctx) !void {
    const shd = texShader();
    const pip = try texPipeline(shd);
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    const vb = gfx.makeBuffer(.{ .size = 64, .usage = .{ .vertex_buffer = true, .write_unsealed = true } });
    const img = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .write_unsealed = true } });
    const view = gfx.makeView(.{ .texture = .{ .image = img } });
    try valid(gfx.queryBufferState(vb), "unsealed vb");
    try valid(gfx.queryImageState(img), "unsealed img");
    gfx.writeBufferUnsealed(.{ .src = .{ .data = gfx.Range.fromSlice(f32, &tex_full), .offset = 0 }, .dst = .{ .buffer = vb, .offset = 0 }, .size = 64 });
    gfx.sealBuffer(vb);
    gfx.writeImageUnsealed(.{
        .src = .{ .data = gfx.Range.fromSlice(u8, std.mem.sliceAsBytes(&pattern_b)), .offset = 0, .bytes_per_row = 8, .bytes_per_slice = 16 },
        .dst = .{ .image = img, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
        .size = .{ .width = 2, .height = 2, .num_slices = 1 },
    });
    gfx.sealImage(img);
    var expected: Pixels = undefined;
    for (0..height) |y| for (0..width) |x| {
        expected[y * width + x] = texelAt(&pattern_b, x, y);
    };
    try presignal(ctx);
    sampleTarget(ctx, pip, vb, ib, view, nearestSampler(), .{ 0, 0, 0, 1 });
    try finish(ctx, "3 unsealed buffer and image", &expected);
}

// 4. copyBufferToBuffer and copyBufferToImage, from a staging buffer and from a GPU buffer
fn scenarioCopies(ctx: *Ctx) !void {
    const shd = texShader();
    const pip = try texPipeline(shd);
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    // vertices: staging -> GPU buffer copy
    const stage_v = gfx.makeBuffer(.{ .usage = .{ .copy_src = true }, .data = gfx.Range.fromSlice(f32, &tex_full) });
    const gpu_v = gfx.makeBuffer(.{ .size = 64, .usage = .{ .vertex_buffer = true, .copy_dst = true } });
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = stage_v, .offset = 0 }, .dst = .{ .buffer = gpu_v, .offset = 0 }, .size = 64 });
    // image A from a staging buffer
    const stage_a = gfx.makeBuffer(.{ .usage = .{ .copy_src = true }, .data = gfx.Range.fromSlice(u8, std.mem.sliceAsBytes(&pattern_a)) });
    const img_a = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .copy_dst = true } });
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = stage_a, .offset = 0, .bytes_per_row = 8, .bytes_per_slice = 16 },
        .dst = .{ .image = img_a, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
        .size = .{ .width = 2, .height = 2, .num_slices = 1 },
    });
    // image B from a GPU buffer, which itself is filled by copyBufferToBuffer
    const stage_b = gfx.makeBuffer(.{ .usage = .{ .copy_src = true }, .data = gfx.Range.fromSlice(u8, std.mem.sliceAsBytes(&pattern_c)) });
    const gpu_px = gfx.makeBuffer(.{ .size = 16, .usage = .{ .copy_src = true, .copy_dst = true } });
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = stage_b, .offset = 0 }, .dst = .{ .buffer = gpu_px, .offset = 0 }, .size = 16 });
    const img_b = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .copy_dst = true } });
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = gpu_px, .offset = 0, .bytes_per_row = 8, .bytes_per_slice = 16 },
        .dst = .{ .image = img_b, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
        .size = .{ .width = 2, .height = 2, .num_slices = 1 },
    });
    try valid(gfx.queryImageState(img_a), "copy img a");
    try valid(gfx.queryImageState(img_b), "copy img b");
    const view_a = gfx.makeView(.{ .texture = .{ .image = img_a } });
    const view_b = gfx.makeView(.{ .texture = .{ .image = img_b } });
    const smp = nearestSampler();
    // full target from image A, then the left half from image B via a scissor rect
    try presignal(ctx);
    gfx.beginPass(targetPass(ctx, .{ 0, 0, 0, 1 }));
    gfx.applyPipeline(pip);
    var bnd: gfx.Bindings = .{};
    bnd.vertex_buffers[0] = gpu_v;
    bnd.index_buffer = ib;
    bnd.views[0] = view_a;
    bnd.samplers[0] = smp;
    gfx.applyBindings(bnd);
    gfx.draw(0, 6, 1);
    bnd.views[0] = view_b;
    gfx.applyBindings(bnd);
    gfx.applyScissorRect(0, 0, 32, height, true);
    gfx.draw(0, 6, 1);
    gfx.endPass();
    var expected: Pixels = undefined;
    for (0..height) |y| for (0..width) |x| {
        expected[y * width + x] = if (x < 32) texelAt(&pattern_c, x, y) else texelAt(&pattern_a, x, y);
    };
    try finish(ctx, "4 copyBufferToBuffer and copyBufferToImage", &expected);
}

fn stencilOn(compare: gfx.CompareFunc, write_mask: u8, read_mask: u8) gfx.StencilState {
    const face: gfx.StencilFaceState = .{ .compare = compare, .fail_op = .keep, .depth_fail_op = .keep, .pass_op = .replace };
    return .{ .enabled = true, .front = face, .back = face, .read_mask = read_mask, .write_mask = write_mask, .ref = 1 };
}

// 5. offscreen pass with depth and stencil, then sampled in a second pass (7)
// 6. MSAA 4x color attachment with resolve attachment, sampled after the resolve (run as a separate frame)
const Offscreen = struct {
    color: gfx.Image,
    color_view: gfx.View,
    color_tex: gfx.View,
    ds: gfx.Image,
    ds_view: gfx.View,
};

fn scenarioDepthStencil(ctx: *Ctx) !void {
    const shd = colorShader();
    const tex_shd = texShader();
    const tex_pip = try texPipeline(tex_shd);
    const off: Offscreen = .{
        .color = gfx.makeImage(.{ .width = width, .height = height, .pixel_format = .rgba8, .usage = .{ .color_attachment = true } }),
        .color_view = undefined,
        .color_tex = undefined,
        .ds = gfx.makeImage(.{ .width = width, .height = height, .pixel_format = .depth_stencil, .usage = .{ .depth_stencil_attachment = true } }),
        .ds_view = undefined,
    };
    var o = off;
    o.color_view = gfx.makeView(.{ .color_attachment = .{ .image = o.color } });
    o.color_tex = gfx.makeView(.{ .texture = .{ .image = o.color } });
    o.ds_view = gfx.makeView(.{ .depth_stencil_attachment = .{ .image = o.ds } });
    try valid(gfx.queryImageState(o.color), "offscreen color");
    try valid(gfx.queryImageState(o.ds), "offscreen depth stencil");

    // draw order: far red full screen, near green left half, blue left half behind the green one,
    // stencil-only right half, yellow overlay where stencil is set
    var verts: [5 * 28]f32 = undefined;
    fillColorQuad(verts[0..28], -1, -1, 1, 1, 0.8, .{ 1, 0, 0, 1 });
    fillColorQuad(verts[28..56], -1, -1, 0, 1, 0.2, .{ 0, 1, 0, 1 });
    fillColorQuad(verts[56..84], -1, -1, 0, 1, 0.9, .{ 0, 0, 1, 1 });
    fillColorQuad(verts[84..112], 0, -1, 1, 1, 0.0, .{ 1, 1, 1, 1 });
    fillColorQuad(verts[112..140], -1, -1, 1, 1, 0.0, .{ 1, 1, 0, 1 });
    var indices: [30]u16 = undefined;
    for (0..5) |q| for (0..6) |i| {
        indices[q * 6 + i] = @intCast(quad_idx[i] + q * 4);
    };
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &verts) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &indices) });
    const depth_pip = try mustPipeline(.{
        .shader = shd,
        .layout = color_layout,
        .index_type = .uint16,
        .cull_mode = .none,
        .depth = .{ .pixel_format = .depth_stencil, .compare = .less, .write_enabled = true },
        .color_count = 1,
        .colors = .{ rgba_target, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    });
    var stencil_write_desc: gfx.PipelineDesc = .{ .shader = shd, .layout = color_layout, .index_type = .uint16, .cull_mode = .none, .color_count = 1, .depth = .{ .pixel_format = .depth_stencil, .compare = .always, .write_enabled = false }, .stencil = stencilOn(.always, 0xff, 0xff) };
    stencil_write_desc.colors[0] = .{ .pixel_format = .rgba8, .write_mask = .none };
    const stencil_write_pip = try mustPipeline(stencil_write_desc);
    var overlay_desc: gfx.PipelineDesc = .{ .shader = shd, .layout = color_layout, .index_type = .uint16, .cull_mode = .none, .color_count = 1, .depth = .{ .pixel_format = .depth_stencil, .compare = .always, .write_enabled = false }, .stencil = stencilOn(.equal, 0, 0xff) };
    overlay_desc.colors[0] = rgba_target;
    overlay_desc.stencil.front.pass_op = .keep;
    overlay_desc.stencil.back.pass_op = .keep;
    overlay_desc.stencil.ref = 1;
    const overlay_pip = try mustPipeline(overlay_desc);

    // pass A: offscreen
    try presignal(ctx);
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = o.color_view;
    pass.attachments.depth_stencil = o.ds_view;
    pass.action.colors[0] = .{ .load_action = .clear, .store_action = .store, .clear_value = .{ .r = 0, .g = 0, .b = 1, .a = 1 } };
    pass.action.depth = .{ .load_action = .clear, .store_action = .dontcare, .clear_value = 1.0 };
    pass.action.stencil = .{ .load_action = .clear, .store_action = .dontcare, .clear_value = 0 };
    gfx.beginPass(pass);
    drawWith(depth_pip, vb, ib, 0, 6);
    drawWith(depth_pip, vb, ib, 6, 6);
    drawWith(depth_pip, vb, ib, 12, 6);
    drawWith(stencil_write_pip, vb, ib, 18, 6);
    drawWith(overlay_pip, vb, ib, 24, 6);
    gfx.endPass();

    // pass B: sample the offscreen color image into the target
    const vb_tex = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &tex_full) });
    const ib_tex = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    sampleTarget(ctx, tex_pip, vb_tex, ib_tex, o.color_tex, nearestSampler(), .{ 0, 0, 0, 1 });
    var expected: Pixels = undefined;
    for (0..height) |y| for (0..width) |x| {
        expected[y * width + x] = if (x < 32) .{ 0, 255, 0, 255 } else .{ 255, 255, 0, 255 };
    };
    try finish(ctx, "5 depth and stencil, offscreen sampled in a second pass (7)", &expected);
}

// 6. MSAA 4x color attachment, resolved and sampled
fn scenarioMsaa(ctx: *Ctx) !void {
    const shd = colorShader();
    const tex_pip = try texPipeline(texShader());
    const msaa = gfx.makeImage(.{ .width = width, .height = height, .pixel_format = .rgba8, .sample_count = 4, .usage = .{ .color_attachment = true } });
    const resolve = gfx.makeImage(.{ .width = width, .height = height, .pixel_format = .rgba8, .usage = .{ .resolve_attachment = true } });
    try valid(gfx.queryImageState(msaa), "msaa image");
    try valid(gfx.queryImageState(resolve), "resolve image");
    const msaa_view = gfx.makeView(.{ .color_attachment = .{ .image = msaa } });
    const resolve_view = gfx.makeView(.{ .resolve_attachment = .{ .image = resolve } });
    const resolve_tex = gfx.makeView(.{ .texture = .{ .image = resolve } });
    var verts: [28]f32 = undefined;
    fillColorQuad(&verts, -1, -1, 1, 1, 0.5, .{ 1, 0, 1, 1 });
    const indices = quad_idx;
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &verts) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &indices) });
    var msaa_desc: gfx.PipelineDesc = .{ .shader = shd, .layout = color_layout, .index_type = .uint16, .cull_mode = .none, .depth = no_depth, .color_count = 1, .sample_count = 4 };
    msaa_desc.colors[0] = rgba_target;
    const msaa_pip = try mustPipeline(msaa_desc);
    try presignal(ctx);
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = msaa_view;
    pass.attachments.resolves[0] = resolve_view;
    pass.action.colors[0] = .{ .load_action = .clear, .store_action = .store, .clear_value = .{ .r = 0, .g = 0, .b = 1, .a = 1 } };
    gfx.beginPass(pass);
    drawWith(msaa_pip, vb, ib, 0, 6);
    gfx.endPass();
    const vb_tex = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &tex_full) });
    const ib_tex = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    sampleTarget(ctx, tex_pip, vb_tex, ib_tex, resolve_tex, nearestSampler(), .{ 0, 0, 0, 1 });
    try finish(ctx, "6 MSAA 4x resolved and sampled", &solid(.{ 255, 0, 255, 255 }));
}

// 8. storage image written by compute, then sampled
fn scenarioStorageImage(ctx: *Ctx) !void {
    var cdesc: gfx.ShaderDesc = .{ .compute_func = .{ .bytecode = gfx.Range.fromSlice(u8, &img_cs_code), .entry = "main" } };
    cdesc.views[2].storage_image = .{ .stage = .compute, .image_type = .@"2d", .access_format = .rgba8, .writeonly = true, .spirv_set1_binding_n = 3 };
    const cshd = gfx.makeShader(cdesc);
    try valid(gfx.queryShaderState(cshd), "storage compute shader");
    const cpip = gfx.makePipeline(.{ .compute = true, .shader = cshd });
    try valid(gfx.queryPipelineState(cpip), "storage compute pipeline");
    const img = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .storage_image = true } });
    try valid(gfx.queryImageState(img), "storage image");
    const storage_view = gfx.makeView(.{ .storage_image = .{ .image = img } });
    const tex_view = gfx.makeView(.{ .texture = .{ .image = img } });
    const tex_pip = try texPipeline(texShader());
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &tex_full) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    try presignal(ctx);
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(cpip);
    var cbnd: gfx.Bindings = .{};
    cbnd.views[2] = storage_view;
    gfx.applyBindings(cbnd);
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
    sampleTarget(ctx, tex_pip, vb, ib, tex_view, nearestSampler(), .{ 0, 0, 0, 1 });
    var cell_texels: [4][4]u8 = undefined;
    for (0..4) |i| cell_texels[i] = .{ @intCast((i % 2) * 255), @intCast((i / 2) * 255), 255, 255 };
    var expected: Pixels = undefined;
    for (0..height) |y| for (0..width) |x| {
        expected[y * width + x] = texelAt(&cell_texels, x, y);
    };
    try finish(ctx, "8 storage image written by compute, then sampled", &expected);
}

// 9. destroy and recreate resources between frames, 10 frames
fn scenarioRecreate(ctx: *Ctx) !void {
    for (0..10) |k| {
        const shd = texShader();
        const pip = try texPipeline(shd);
        const color: [4]u8 = .{ @intCast((k & 1) * 255), @intCast(((k >> 1) & 1) * 255), 255, 255 };
        var cell_texels: [4][4]u8 = .{ color, color, color, color };
        const img = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .data = .{ .mip_levels = blk: {
            var m: [16]gfx.Range = @splat(.{});
            m[0] = gfx.Range.fromSlice(u8, std.mem.sliceAsBytes(&cell_texels));
            break :blk m;
        } } });
        try valid(gfx.queryImageState(img), "recreated image");
        const view = gfx.makeView(.{ .texture = .{ .image = img } });
        const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &tex_full) });
        const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
        const smp = nearestSampler();
        try presignal(ctx);
        sampleTarget(ctx, pip, vb, ib, view, smp, .{ 0, 0, 0, 1 });
        var name_buf: [96]u8 = undefined;
        try finish(ctx, try std.fmt.bufPrint(&name_buf, "9 recreate frame {d}", .{k}), &solid(color));
        // the delete queue keeps these alive until the frame slot is reused
        gfx.destroySampler(smp);
        gfx.destroyBuffer(ib);
        gfx.destroyBuffer(vb);
        gfx.destroyView(view);
        gfx.destroyImage(img);
        gfx.destroyPipeline(pip);
        gfx.destroyShader(shd);
    }
}

// 10. blending and scissor rect
fn scenarioBlendScissor(ctx: *Ctx) !void {
    const shd = colorShader();
    var verts: [28]f32 = undefined;
    fillColorQuad(&verts, -1, -1, 1, 1, 0.5, .{ 1, 0, 0, 0 });
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &verts) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_idx) });
    var desc: gfx.PipelineDesc = .{ .shader = shd, .layout = color_layout, .index_type = .uint16, .cull_mode = .none, .depth = no_depth, .color_count = 1 };
    desc.colors[0] = .{ .pixel_format = .rgba8, .blend = .{ .enabled = true, .src_factor_rgb = .one, .dst_factor_rgb = .one, .op_rgb = .add, .src_factor_alpha = .one, .dst_factor_alpha = .one, .op_alpha = .add } };
    const pip = try mustPipeline(desc);
    try presignal(ctx);
    gfx.beginPass(targetPass(ctx, .{ 0, 0, 1, 1 }));
    gfx.applyPipeline(pip);
    gfx.applyScissorRect(0, 0, 32, height, true);
    var bnd: gfx.Bindings = .{};
    bnd.vertex_buffers[0] = vb;
    bnd.index_buffer = ib;
    gfx.applyBindings(bnd);
    gfx.draw(0, 6, 1);
    gfx.endPass();
    var expected: Pixels = undefined;
    for (0..height) |y| for (0..width) |x| {
        expected[y * width + x] = if (x < 32) .{ 255, 0, 255, 255 } else .{ 0, 0, 255, 255 };
    };
    try finish(ctx, "10 blending and scissor", &expected);
}

// 0. baseline: compute writes a storage buffer, a fragment shader reads it with a uniform and a texture
fn scenarioBaseline(ctx: *Ctx) !void {
    const cs = gfx.makeShader(.{ .compute_func = .{ .bytecode = gfx.Range.fromSlice(u8, &cs_code), .entry = "main" }, .views = blk: {
        var v: [32]gfx.ShaderView = @splat(.{});
        v[1].storage_buffer = .{ .stage = .compute, .readonly = false, .spirv_set1_binding_n = 2 };
        break :blk v;
    } });
    const cpip = gfx.makePipeline(.{ .compute = true, .shader = cs });
    try valid(gfx.queryShaderState(cs), "baseline compute shader");
    try valid(gfx.queryPipelineState(cpip), "baseline compute pipeline");
    var rdesc: gfx.ShaderDesc = .{
        .vertex_func = .{ .bytecode = gfx.Range.fromSlice(u8, &vs_code), .entry = "main" },
        .fragment_func = .{ .bytecode = gfx.Range.fromSlice(u8, &fs_code), .entry = "main" },
    };
    rdesc.uniform_blocks[0] = .{ .stage = .fragment, .size = 16, .spirv_set0_binding_n = 0 };
    rdesc.views[0].texture = .{ .stage = .fragment, .image_type = .@"2d", .sample_type = .float, .spirv_set1_binding_n = 0 };
    rdesc.views[1].storage_buffer = .{ .stage = .fragment, .readonly = true, .spirv_set1_binding_n = 2 };
    rdesc.samplers[0] = .{ .stage = .fragment, .sampler_type = .filtering, .spirv_set1_binding_n = 1 };
    rdesc.texture_sampler_pairs[0] = .{ .stage = .fragment, .view_slot = 0, .sampler_slot = 0 };
    const rshd = gfx.makeShader(rdesc);
    try valid(gfx.queryShaderState(rshd), "baseline render shader");
    var layout: gfx.VertexLayoutState = .{};
    layout.buffers[0] = .{ .stride = 16 };
    layout.attrs[0] = .{ .buffer_index = 0, .offset = 0, .format = .float2 };
    layout.attrs[1] = .{ .buffer_index = 0, .offset = 8, .format = .float2 };
    var pdesc: gfx.PipelineDesc = .{ .shader = rshd, .layout = layout, .index_type = .uint16, .cull_mode = .none, .depth = no_depth, .color_count = 1 };
    pdesc.colors[0] = rgba_target;
    const rpip = try mustPipeline(pdesc);
    const sb = gfx.makeBuffer(.{ .size = 16, .usage = .{ .storage_buffer = true } });
    const sb_view = gfx.makeView(.{ .storage_buffer = .{ .buffer = sb } });
    const tex = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .data = .{ .mip_levels = blk: {
        var m: [16]gfx.Range = @splat(.{});
        m[0] = gfx.Range.fromSlice(u8, &texels);
        break :blk m;
    } } });
    const tex_view = gfx.makeView(.{ .texture = .{ .image = tex } });
    const smp = nearestSampler();
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &quad_vertices) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &quad_indices) });
    var bnd: gfx.Bindings = .{};
    bnd.vertex_buffers[0] = vb;
    bnd.index_buffer = ib;
    bnd.views[0] = tex_view;
    bnd.views[1] = sb_view;
    bnd.samplers[0] = smp;
    const muls = [_][4]u8{ .{ 255, 255, 255, 255 }, .{ 0, 255, 255, 255 } };
    for (muls, 0..) |mul, frame| {
        try presignal(ctx);
        gfx.beginPass(.{ .compute = true });
        gfx.applyPipeline(cpip);
        var cbnd: gfx.Bindings = .{};
        cbnd.views[1] = sb_view;
        gfx.applyBindings(cbnd);
        gfx.dispatch(1, 1, 1);
        gfx.endPass();
        gfx.beginPass(targetPass(ctx, .{ 0, 0, 1, 1 }));
        gfx.applyPipeline(rpip);
        gfx.applyBindings(bnd);
        const uniform: [4]f32 = .{ @as(f32, @floatFromInt(mul[0])) / 255, @as(f32, @floatFromInt(mul[1])) / 255, @as(f32, @floatFromInt(mul[2])) / 255, @as(f32, @floatFromInt(mul[3])) / 255 };
        gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &uniform));
        gfx.draw(0, 6, 1);
        gfx.endPass();
        var expected: Pixels = undefined;
        for (0..height) |y| for (0..width) |x| {
            expected[y * width + x] = expectedPixel(x, y, mul);
        };
        var name_buf: [96]u8 = undefined;
        try finish(ctx, try std.fmt.bufPrint(&name_buf, "0 baseline compute+uniform+texture frame {d}", .{frame}), &expected);
    }
}

const scenarios = [_]struct { name: []const u8, run: *const fn (*Ctx) anyerror!void }{
    .{ .name = "0", .run = scenarioBaseline },
    .{ .name = "1", .run = scenarioTransient },
    .{ .name = "2", .run = scenarioImageTransient },
    .{ .name = "3", .run = scenarioUnsealed },
    .{ .name = "4", .run = scenarioCopies },
    .{ .name = "5", .run = scenarioDepthStencil },
    .{ .name = "6", .run = scenarioMsaa },
    .{ .name = "8", .run = scenarioStorageImage },
    .{ .name = "9", .run = scenarioRecreate },
    .{ .name = "10", .run = scenarioBlendScissor },
    .{ .name = "11", .run = scenarioReadback },
};

// 11. readback through the raw API: gfx.readImage / gfx.readBuffer
const sb_write_cs = @embedFile("shaders/sbwrite.comp.spv");
var sb_write_code: [sb_write_cs.len]u8 align(4) = sb_write_cs.*;

fn expectReadback(name: []const u8, ok: bool) !void {
    if (!ok) {
        std.debug.print("FAIL {s}: readImage/readBuffer returned false\n", .{name});
        return error.ReadFailed;
    }
}

fn scenarioReadback(ctx: *Ctx) !void {
    _ = ctx;
    const shd = colorShader();
    const pip = try colorPipeline(shd, no_depth, rgba_target, 1);

    // (a) full image: blue background, red left half, green top-left quadrant
    const img = gfx.makeImage(.{ .width = width, .height = height, .pixel_format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    try valid(gfx.queryImageState(img), "readback image");
    const cv = gfx.makeView(.{ .color_attachment = .{ .image = img } });
    var verts: [3 * 28]f32 = undefined;
    fillColorQuad(verts[0..28], -1, -1, 1, 1, 0.5, .{ 0, 0, 1, 1 });
    fillColorQuad(verts[28..56], -1, -1, 0, 1, 0.3, .{ 1, 0, 0, 1 });
    fillColorQuad(verts[56..84], -1, 0, 0, 1, 0.1, .{ 0, 1, 0, 1 });
    var indices: [18]u16 = undefined;
    for (0..3) |q| for (0..6) |i| {
        indices[q * 6 + i] = @intCast(quad_idx[i] + q * 4);
    };
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &verts) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &indices) });
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = cv;
    pass.action.colors[0] = .{ .load_action = .clear, .store_action = .store, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
    gfx.beginPass(pass);
    drawWith(pip, vb, ib, 0, 6);
    drawWith(pip, vb, ib, 6, 6);
    drawWith(pip, vb, ib, 12, 6);
    gfx.endPass();

    // (b) a storage buffer written by compute, read at an offset
    const sbuf = gfx.makeBuffer(.{ .size = 64, .usage = .{ .storage_buffer = true, .copy_src = true } });
    var cdesc: gfx.ShaderDesc = .{ .compute_func = .{ .bytecode = gfx.Range.fromSlice(u8, &sb_write_code), .entry = "main" } };
    cdesc.views[1].storage_buffer = .{ .stage = .compute, .readonly = false, .spirv_set1_binding_n = 2 };
    const cshd = gfx.makeShader(cdesc);
    const cpip = gfx.makePipeline(.{ .compute = true, .shader = cshd });
    try valid(gfx.queryPipelineState(cpip), "readback compute");
    const sview = gfx.makeView(.{ .storage_buffer = .{ .buffer = sbuf } });
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(cpip);
    var cbnd: gfx.Bindings = .{};
    cbnd.views[1] = sview;
    gfx.applyBindings(cbnd);
    gfx.dispatch(1, 1, 1);
    gfx.endPass();

    // (c) an array image: layer 1 mip 0 magenta, mip 1 yellow, layer 0 mip 0 black
    const arr = gfx.makeImage(.{ .type = .array, .width = width, .height = height, .num_slices = 2, .num_mipmaps = 2, .pixel_format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    try valid(gfx.queryImageState(arr), "array readback image");
    const clears = [_]struct { mip: i32, slice: i32, c: [4]f32 }{
        .{ .mip = 0, .slice = 0, .c = .{ 0, 0, 0, 1 } },
        .{ .mip = 0, .slice = 1, .c = .{ 1, 0, 1, 1 } },
        .{ .mip = 1, .slice = 0, .c = .{ 1, 1, 0, 1 } },
    };
    for (clears) |cl| {
        const v = gfx.makeView(.{ .color_attachment = .{ .image = arr, .mip_level = cl.mip, .slice = cl.slice } });
        var p: gfx.Pass = .{};
        p.attachments.colors[0] = v;
        p.action.colors[0] = .{ .load_action = .clear, .store_action = .store, .clear_value = .{ .r = cl.c[0], .g = cl.c[1], .b = cl.c[2], .a = cl.c[3] } };
        gfx.beginPass(p);
        gfx.endPass();
    }

    // (d) a transient buffer written with writeBufferTransient
    const tbuf = gfx.makeBuffer(.{ .size = 16, .usage = .{ .write_transient = true, .copy_src = true } });
    const tdata = [4]u32{ 0x11, 0x22, 0x33, 0x44 };
    gfx.writeBufferTransient(.{ .src = .{ .data = gfx.Range.fromSlice(u32, &tdata), .offset = 0 }, .dst = .{ .buffer = tbuf, .offset = 0 }, .size = 16 });

    gfx.commit();

    // (a) full image
    var full: Pixels = undefined;
    try expectReadback("11a full image", gfx.readImage(.{ .image = img }, std.mem.sliceAsBytes(&full)));
    var expected: Pixels = undefined;
    for (0..height) |y| for (0..width) |x| {
        expected[y * width + x] = if (x < 32 and y < 32) .{ 0, 255, 0, 255 } else if (x < 32) .{ 255, 0, 0, 255 } else .{ 0, 0, 255, 255 };
    };
    try check("11a readImage full image", &full, &expected);

    // (a2) sub-region with padded row and slice pitches; the padding must stay untouched
    const bpr: usize = 20 * 4 + 12;
    const bps: usize = bpr * 7 + 8;
    var sub: [bps]u8 = @splat(0xAA);
    try expectReadback("11a2 sub-region", gfx.readImage(.{ .image = img, .x = 10, .y = 5, .width = 20, .height = 7, .num_slices = 1, .bytes_per_row = bpr, .bytes_per_slice = bps }, &sub));
    var sub_bad: u32 = 0;
    for (0..7) |r| {
        for (0..20) |c| {
            const px = expected[(5 + r) * width + (10 + c)];
            if (!std.mem.eql(u8, sub[r * bpr + c * 4 ..][0..4], &px)) sub_bad += 1;
        }
        for (r * bpr + 80..(r + 1) * bpr) |i| {
            if (sub[i] != 0xAA) sub_bad += 1;
        }
    }
    for (bpr * 7..bps) |i| {
        if (sub[i] != 0xAA) sub_bad += 1;
    }
    if (sub_bad != 0) {
        std.debug.print("FAIL 11a2 sub-region: {d} bad bytes\n", .{sub_bad});
        return error.PixelMismatch;
    }
    std.debug.print("pass 11a2 readImage sub-region with padded pitches\n", .{});

    // (b) storage buffer, whole and at offset 16
    var sbytes: [64]u8 = undefined;
    try expectReadback("11b storage buffer", gfx.readBuffer(sbuf, 0, &sbytes));
    var sbytes2: [32]u8 = undefined;
    try expectReadback("11b storage buffer offset", gfx.readBuffer(sbuf, 16, &sbytes2));
    var floats: [16]f32 = undefined;
    @memcpy(std.mem.sliceAsBytes(&floats), &sbytes);
    for (0..4) |i| {
        const want = [4]f32{ @floatFromInt(i), 2, 3, 4 };
        if (!std.mem.eql(f32, floats[i * 4 ..][0..4], &want)) {
            std.debug.print("FAIL 11b storage buffer: vec4 {d} is {any}\n", .{ i, floats[i * 4 ..][0..4] });
            return error.PixelMismatch;
        }
    }
    if (!std.mem.eql(u8, &sbytes2, sbytes[16..48])) {
        std.debug.print("FAIL 11b storage buffer offset read\n", .{});
        return error.PixelMismatch;
    }
    std.debug.print("pass 11b readBuffer of a compute-written storage buffer\n", .{});

    // (c) array layer 1 and mip 1, plus layer 0 mip 0
    var layer1: Pixels = undefined;
    try expectReadback("11c layer 1", gfx.readImage(.{ .image = arr, .mip_level = 0, .slice = 1, .num_slices = 1 }, std.mem.sliceAsBytes(&layer1)));
    try check("11c readImage array layer 1 mip 0", &layer1, &solid(.{ 255, 0, 255, 255 }));
    var layer0: Pixels = undefined;
    try expectReadback("11c layer 0", gfx.readImage(.{ .image = arr, .mip_level = 0, .slice = 0, .num_slices = 1 }, std.mem.sliceAsBytes(&layer0)));
    try check("11c readImage array layer 0 mip 0", &layer0, &solid(.{ 0, 0, 0, 255 }));
    var mip1: [32 * 32][4]u8 = undefined;
    try expectReadback("11c mip 1", gfx.readImage(.{ .image = arr, .mip_level = 1, .slice = 0, .num_slices = 1 }, std.mem.sliceAsBytes(&mip1)));
    for (mip1) |px| {
        if (!std.mem.eql(u8, &px, &[4]u8{ 255, 255, 0, 255 })) {
            std.debug.print("FAIL 11c mip 1: pixel {any}\n", .{px});
            return error.PixelMismatch;
        }
    }
    std.debug.print("pass 11c readImage array layer and mip level\n", .{});

    // (d) transient buffer
    var tout: [16]u8 = undefined;
    try expectReadback("11d transient", gfx.readBuffer(tbuf, 0, &tout));
    const want_t = std.mem.sliceAsBytes(&tdata);
    if (!std.mem.eql(u8, &tout, want_t)) {
        std.debug.print("FAIL 11d transient buffer: {any}\n", .{tout});
        return error.PixelMismatch;
    }
    std.debug.print("pass 11d readBuffer of a transient buffer\n", .{});
}

/// Finds the memory type index that satisfies `type_bits` and `flags`.
fn findMemoryType(props: *const PhysicalDeviceMemoryProperties, type_bits: u32, flags: u32) !u32 {
    for (0..props.memoryTypeCount) |i| {
        if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and props.memoryTypes[i].propertyFlags & flags == flags) return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var lib = try std.DynLib.open("libvulkan.so.1");
    defer lib.close();
    const get_instance = lib.lookup(GetInstanceProcAddr, "vkGetInstanceProcAddr") orelse return error.MissingVulkanLoader;
    var global: Vk = .{};
    try loadVk(&global, get_instance, @as(Instance, null));

    // ---- instance, with validation when the layer is installed
    var layer_count: u32 = 0;
    _ = global.vkEnumerateInstanceLayerProperties(&layer_count, null);
    var layers: [64]LayerProperties = undefined;
    _ = global.vkEnumerateInstanceLayerProperties(&layer_count, &layers);
    var validation = false;
    for (layers[0..layer_count]) |*layer| {
        if (std.mem.eql(u8, std.mem.sliceTo(&layer.layerName, 0), "VK_LAYER_KHRONOS_validation")) validation = true;
    }
    const validation_layer = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    // VK_KHR_surface is required by VK_KHR_swapchain, which the device enables for the swapchain-style pass
    const instance_ext = [_][*:0]const u8{ "VK_KHR_surface", "VK_EXT_debug_utils" };
    const app_info: ApplicationInfo = .{ .pApplicationName = "sokol_gfx vk smoke", .apiVersion = API_VERSION_1_3 };
    const instance_info: InstanceCreateInfo = .{
        .pApplicationInfo = &app_info,
        .enabledLayerCount = if (validation) 1 else 0,
        .ppEnabledLayerNames = if (validation) &validation_layer else null,
        .enabledExtensionCount = if (validation) 2 else 1,
        .ppEnabledExtensionNames = &instance_ext,
    };
    var instance: Instance = null;
    if (global.vkCreateInstance(&instance_info, null, &instance) != SUCCESS) return error.VulkanInitFailed;
    var vk: Vk = .{};
    try loadVk(&vk, get_instance, instance);
    var messenger: DebugUtilsMessengerEXT = 0;
    if (validation) {
        const messenger_info: DebugUtilsMessengerCreateInfoEXT = .{
            .messageSeverity = DEBUG_SEVERITY_ERROR | DEBUG_SEVERITY_WARNING | 0x1,
            .messageType = DEBUG_TYPE_ALL,
            .pfnUserCallback = debugCallback,
        };
        if (vk.vkCreateDebugUtilsMessengerEXT(instance, &messenger_info, null, &messenger) != SUCCESS) return error.VulkanInitFailed;
        std.debug.print("validation layer enabled\n", .{});
    } else {
        std.debug.print("validation layer not installed\n", .{});
    }

    // ---- physical device and queue family with graphics, compute and transfer
    var phys_count: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(instance, &phys_count, null);
    var phys: [16]PhysicalDevice = undefined;
    _ = vk.vkEnumeratePhysicalDevices(instance, &phys_count, &phys);
    var physical: PhysicalDevice = null;
    var family: u32 = 0;
    for (phys[0..phys_count]) |candidate| {
        var fam_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &fam_count, null);
        var families: [32]QueueFamilyProperties = undefined;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(candidate, &fam_count, &families);
        for (families[0..fam_count], 0..) |*fam, i| {
            if (fam.queueFlags & QUEUE_GRAPHICS_COMPUTE_TRANSFER == QUEUE_GRAPHICS_COMPUTE_TRANSFER) {
                physical = candidate;
                family = @intCast(i);
                break;
            }
        }
        if (physical != null) break;
    }
    if (physical == null) return error.MissingVulkanDevice;
    var mem_props: PhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical, &mem_props);

    // ---- logical device with Vulkan 1.3 features and VK_EXT_descriptor_buffer
    const priority: f32 = 1.0;
    const queue_info: DeviceQueueCreateInfo = .{ .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = @ptrCast(&priority) };
    var dbuf_features: PhysicalDeviceDescriptorBufferFeaturesEXT = .{ .sType = 1000316002, .descriptorBuffer = TRUE };
    var features13: PhysicalDeviceVulkan13Features = .{ .sType = 53, .pNext = &dbuf_features, .dynamicRendering = TRUE, .synchronization2 = TRUE };
    var features12: PhysicalDeviceVulkan12Features = .{ .sType = 51, .pNext = &features13, .bufferDeviceAddress = TRUE };
    var features2: PhysicalDeviceFeatures2 = .{ .sType = 1000059000, .pNext = &features12 };
    const device_extensions = [_][*:0]const u8{ "VK_EXT_descriptor_buffer", "VK_KHR_swapchain" };
    const device_info: DeviceCreateInfo = .{
        .pNext = &features2,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = @ptrCast(&queue_info),
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
    };
    var device: Device = null;
    if (vk.vkCreateDevice(physical, &device_info, null, &device) != SUCCESS) return error.VulkanInitFailed;
    // instance-level getters also resolve device functions, and they do not warn when used with a device
    var device_fns: Vk = vk;
    var queue: Queue = null;
    device_fns.vkGetDeviceQueue(device, family, 0, &queue);
    std.debug.print("device created, queue family {d}\n", .{family});

    // ---- sokol_gfx on top of the application's instance and device
    try gfx.setup(std.heap.page_allocator, .vulkan, .{
        .buffer_pool_size = 64,
        .image_pool_size = 64,
        .sampler_pool_size = 16,
        .shader_pool_size = 16,
        .pipeline_pool_size = 16,
        .view_pool_size = 64,
        .uniform_buffer_size = 64 * 1024,
        .vulkan = .{ .copy_staging_buffer_size = 1 << 20, .transient_staging_buffer_size = 1 << 20, .descriptor_buffer_size = 1 << 20 },
        .logger = .{ .func = gfxLogger },
        .environment = .{ .vulkan = .{
            .instance = instance,
            .physical_device = physical,
            .device = device,
            .queue = queue,
            .queue_family_index = family,
            .get_instance_proc_addr = @ptrCast(get_instance),
        } },
    });
    defer gfx.shutdown();

    // ---- app-provided render target, semaphores and readback objects
    const target_info: ImageCreateInfo = .{
        .imageType = 1,
        .format = FORMAT_R8G8B8A8_UNORM,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = 1,
        .tiling = 0,
        .usage = IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = 0,
        .initialLayout = IMAGE_LAYOUT_UNDEFINED,
    };
    var target: u64 = 0;
    if (device_fns.vkCreateImage(device, &target_info, null, &target) != SUCCESS) return error.VulkanInitFailed;
    var target_reqs: MemoryRequirements = undefined;
    device_fns.vkGetImageMemoryRequirements(device, target, &target_reqs);
    const target_mem_info: MemoryAllocateInfo = .{
        .allocationSize = target_reqs.size,
        .memoryTypeIndex = try findMemoryType(&mem_props, target_reqs.memoryTypeBits, MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    };
    var target_mem: u64 = 0;
    if (device_fns.vkAllocateMemory(device, &target_mem_info, null, &target_mem) != SUCCESS) return error.VulkanInitFailed;
    if (device_fns.vkBindImageMemory(device, target, target_mem, 0) != SUCCESS) return error.VulkanInitFailed;
    const view_info: ImageViewCreateInfo = .{
        .image = target,
        .viewType = 1,
        .format = FORMAT_R8G8B8A8_UNORM,
        .components = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .subresourceRange = .{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
    };
    var target_view: u64 = 0;
    if (device_fns.vkCreateImageView(device, &view_info, null, &target_view) != SUCCESS) return error.VulkanInitFailed;

    const sem_info: SemaphoreCreateInfo = .{};
    var present_sem: u64 = 0;
    var render_sem: u64 = 0;
    if (device_fns.vkCreateSemaphore(device, &sem_info, null, &present_sem) != SUCCESS) return error.VulkanInitFailed;
    if (device_fns.vkCreateSemaphore(device, &sem_info, null, &render_sem) != SUCCESS) return error.VulkanInitFailed;
    const fence_info: FenceCreateInfo = .{};
    var fence: u64 = 0;
    if (device_fns.vkCreateFence(device, &fence_info, null, &fence) != SUCCESS) return error.VulkanInitFailed;

    const pool_info: CommandPoolCreateInfo = .{ .flags = COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = family };
    var pool: u64 = 0;
    if (device_fns.vkCreateCommandPool(device, &pool_info, null, &pool) != SUCCESS) return error.VulkanInitFailed;
    const cmd_alloc: CommandBufferAllocateInfo = .{ .commandPool = pool, .level = 0, .commandBufferCount = 1 };
    var cmd: CommandBuffer = null;
    if (device_fns.vkAllocateCommandBuffers(device, &cmd_alloc, &cmd) != SUCCESS) return error.VulkanInitFailed;

    const readback_size: u64 = width * height * 4;
    const readback_info: BufferCreateInfo = .{ .size = readback_size, .usage = BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = 0 };
    var readback_buf: u64 = 0;
    if (device_fns.vkCreateBuffer(device, &readback_info, null, &readback_buf) != SUCCESS) return error.VulkanInitFailed;
    var readback_reqs: MemoryRequirements = undefined;
    device_fns.vkGetBufferMemoryRequirements(device, readback_buf, &readback_reqs);
    const readback_mem_info: MemoryAllocateInfo = .{
        .allocationSize = readback_reqs.size,
        .memoryTypeIndex = try findMemoryType(&mem_props, readback_reqs.memoryTypeBits, MEMORY_PROPERTY_HOST_VISIBLE_BIT | MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    var readback_mem: u64 = 0;
    if (device_fns.vkAllocateMemory(device, &readback_mem_info, null, &readback_mem) != SUCCESS) return error.VulkanInitFailed;
    if (device_fns.vkBindBufferMemory(device, readback_buf, readback_mem, 0) != SUCCESS) return error.VulkanInitFailed;

    var ctx: Ctx = .{
        .device = device,
        .queue = queue,
        .fns = device_fns,
        .mem_props = mem_props,
        .target = target,
        .target_view = target_view,
        .present_sem = present_sem,
        .render_sem = render_sem,
        .fence = fence,
        .cmd = cmd,
        .readback = readback_buf,
        .readback_mem = readback_mem,
    };
    var failures: u32 = 0;
    for (scenarios) |s| {
        s.run(&ctx) catch |err| {
            std.debug.print("FAIL scenario {s}: {s}\n", .{ s.name, @errorName(err) });
            failures += 1;
        };
    }
    _ = device_fns.vkDeviceWaitIdle(device);
    if (error_count != 0) {
        std.debug.print("{d} validation errors\n", .{error_count});
        return error.ValidationFailed;
    }
    if (failures != 0) return error.SmokeFailed;
    std.debug.print("vulkan smoke test passed: {d} scenarios\n", .{scenarios.len});
}
