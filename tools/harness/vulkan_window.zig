//! X11/Win32 Vulkan WSI smoke host. Queue-idle waits deliberately simplify this test;
//! they are not the renderer's recommended frame scheduling strategy.
const std = @import("std");
const gpu = @import("zicr").gpu;
const vk = gpu.raw.native.vulkan;
const builtin = @import("builtin");
const NativeWindow = if (builtin.os.tag == .windows) @import("win32.zig").Window else @import("x11.zig").Window;
const Extent = extern struct { width: u32, height: u32 };
const XlibSurfaceInfo = extern struct { sType: i32 = 1000004000, pNext: ?*const anyopaque = null, flags: u32 = 0, display: *anyopaque, window: c_ulong };
const Win32SurfaceInfo = extern struct { sType: i32 = 1000009000, pNext: ?*const anyopaque = null, flags: u32 = 0, hinstance: *anyopaque, hwnd: *anyopaque };
const SurfaceInfo = if (builtin.os.tag == .windows) Win32SurfaceInfo else XlibSurfaceInfo;
const Capabilities = extern struct { minImageCount: u32, maxImageCount: u32, currentExtent: Extent, minImageExtent: Extent, maxImageExtent: Extent, maxImageArrayLayers: u32, supportedTransforms: u32, currentTransform: u32, supportedCompositeAlpha: u32, supportedUsageFlags: u32 };
const Format = extern struct { format: i32, colorSpace: i32 };
const SwapInfo = extern struct {
    sType: i32 = 1000001000,
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    surface: u64,
    minImageCount: u32,
    imageFormat: i32,
    imageColorSpace: i32,
    imageExtent: Extent,
    imageArrayLayers: u32 = 1,
    imageUsage: u32 = 0x11,
    imageSharingMode: i32 = 0,
    queueFamilyIndexCount: u32 = 0,
    pQueueFamilyIndices: ?[*]const u32 = null,
    preTransform: u32,
    compositeAlpha: u32,
    presentMode: i32 = 2,
    clipped: u32 = 1,
    oldSwapchain: u64 = 0,
};
const SemaphoreInfo = extern struct { sType: i32 = 9, pNext: ?*const anyopaque = null, flags: u32 = 0 };
const PresentInfo = extern struct {
    sType: i32 = 1000001001,
    pNext: ?*const anyopaque = null,
    waitSemaphoreCount: u32 = 1,
    pWaitSemaphores: *const u64,
    swapchainCount: u32 = 1,
    pSwapchains: *const u64,
    pImageIndices: *const u32,
    pResults: ?*i32 = null,
};
const PresentFenceInfo = extern struct {
    sType: i32 = 1000275001,
    pNext: ?*const anyopaque = null,
    swapchainCount: u32 = 1,
    pFences: *const u64,
};
const Procs = struct {
    createSurface: *const fn (vk.Instance, *const SurfaceInfo, ?*const anyopaque, *u64) callconv(.c) i32,
    vkDestroySurfaceKHR: *const fn (vk.Instance, u64, ?*const anyopaque) callconv(.c) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: *const fn (vk.PhysicalDevice, u32, u64, *u32) callconv(.c) i32,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: *const fn (vk.PhysicalDevice, u64, *Capabilities) callconv(.c) i32,
    vkGetPhysicalDeviceSurfaceFormatsKHR: *const fn (vk.PhysicalDevice, u64, *u32, ?[*]Format) callconv(.c) i32,
    vkCreateSwapchainKHR: *const fn (vk.Device, *const SwapInfo, ?*const anyopaque, *u64) callconv(.c) i32,
    vkDestroySwapchainKHR: *const fn (vk.Device, u64, ?*const anyopaque) callconv(.c) void,
    vkGetSwapchainImagesKHR: *const fn (vk.Device, u64, *u32, ?[*]u64) callconv(.c) i32,
    vkCreateSemaphore: *const fn (vk.Device, *const SemaphoreInfo, ?*const anyopaque, *u64) callconv(.c) i32,
    vkDestroySemaphore: *const fn (vk.Device, u64, ?*const anyopaque) callconv(.c) void,
    vkAcquireNextImageKHR: *const fn (vk.Device, u64, u64, u64, u64, *u32) callconv(.c) i32,
    vkQueuePresentKHR: *const fn (vk.Queue, *const PresentInfo) callconv(.c) i32,
};
fn check(result: i32) !void {
    if (result != 0) return error.VulkanWindowOperationFailed;
}
pub const Window = struct {
    native: NativeWindow,
    instance: vk.Instance,
    device: vk.Device,
    queue: vk.Queue,
    family: u32,
    dispatch: vk.Dispatch,
    procs: Procs,
    surface: u64,
    swapchain: u64,
    images: [8]u64 = @splat(0),
    views: [8]u64 = @splat(0),
    count: u32 = 0,
    index: u32 = 0,
    acquired: u64 = 0,
    // Presentation may still own a semaphore after the submit fence signals.
    // Reuse a render-finished semaphore only when its image is acquired again.
    finished: [8]u64 = @splat(0),
    present_fences: [8]u64 = @splat(0),
    presented: [8]bool = @splat(false),
    format: gpu.PixelFormat,

    pub fn create(get: vk.GetInstanceProcAddr, instance: vk.Instance, physical: vk.PhysicalDevice, device: vk.Device, queue: vk.Queue, family: u32) !Window {
        var native = try NativeWindow.create();
        errdefer native.deinit();
        var procs: Procs = undefined;
        inline for (@typeInfo(Procs).@"struct".field_names) |name| @field(procs, name) = @ptrCast(@alignCast(get(instance, if (comptime std.mem.eql(u8, name, "createSurface")) (if (builtin.os.tag == .windows) "vkCreateWin32SurfaceKHR" else "vkCreateXlibSurfaceKHR") else name.ptr) orelse return error.MissingVulkanWindowFunction));
        var dispatch: vk.Dispatch = .{};
        try dispatch.load(get, instance, device);
        var surface: u64 = 0;
        const surface_info: SurfaceInfo = if (builtin.os.tag == .windows) .{ .hinstance = native.instance, .hwnd = native.handle } else .{ .display = native.display, .window = native.handle };
        try check(procs.createSurface(instance, &surface_info, null, &surface));
        errdefer procs.vkDestroySurfaceKHR(instance, surface, null);
        var supported: u32 = 0;
        try check(procs.vkGetPhysicalDeviceSurfaceSupportKHR(physical, family, surface, &supported));
        if (supported == 0) return error.GraphicsQueueCannotPresent;
        var caps: Capabilities = undefined;
        try check(procs.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps));
        if (caps.supportedUsageFlags & 0x11 != 0x11) return error.SwapchainReadbackUnsupported;
        var count: u32 = 0;
        try check(procs.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, null));
        if (count > 64) return error.TooManySurfaceFormats;
        var formats: [64]Format = undefined;
        try check(procs.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, &formats));
        const chosen = for (formats[0..count]) |format| {
            if ((format.format == 37 or format.format == 44) and format.colorSpace == 0) break format;
        } else return error.NoUnormSurfaceFormat;
        const extent: Extent = if (caps.currentExtent.width == 0xffffffff) .{ .width = 64, .height = 64 } else caps.currentExtent;
        if (extent.width != 64 or extent.height != 64) return error.UnexpectedWindowExtent;
        const image_count = if (caps.maxImageCount == 0) @max(caps.minImageCount, 2) else @min(caps.maxImageCount, @max(caps.minImageCount, 2));
        var swapchain: u64 = 0;
        try check(procs.vkCreateSwapchainKHR(device, &.{ .surface = surface, .minImageCount = image_count, .imageFormat = chosen.format, .imageColorSpace = chosen.colorSpace, .imageExtent = extent, .preTransform = caps.currentTransform, .compositeAlpha = @as(u32, 1) << @intCast(@ctz(caps.supportedCompositeAlpha)) }, null, &swapchain));
        errdefer procs.vkDestroySwapchainKHR(device, swapchain, null);
        var result: Window = .{ .native = native, .instance = instance, .device = device, .queue = queue, .family = family, .dispatch = dispatch, .procs = procs, .surface = surface, .swapchain = swapchain, .format = if (chosen.format == 37) .rgba8 else .bgra8 };
        try check(procs.vkGetSwapchainImagesKHR(device, swapchain, &result.count, null));
        if (result.count > result.images.len) return error.TooManySwapchainImages;
        try check(procs.vkGetSwapchainImagesKHR(device, swapchain, &result.count, &result.images));
        var created: usize = 0;
        errdefer for (0..created) |i| {
            if (result.present_fences[i] != 0) dispatch.device.vkDestroyFence(device, result.present_fences[i], null);
            if (result.finished[i] != 0) procs.vkDestroySemaphore(device, result.finished[i], null);
            dispatch.device.vkDestroyImageView(device, result.views[i], null);
        };
        for (result.images[0..result.count], 0..) |image, i| {
            try check(dispatch.device.vkCreateImageView(device, &.{ .sType = 15, .image = image, .viewType = 1, .format = chosen.format, .subresourceRange = .{ .aspectMask = 1, .levelCount = 1, .layerCount = 1 } }, null, &result.views[i]));
            created += 1;
            try check(procs.vkCreateSemaphore(device, &.{}, null, &result.finished[i]));
            try check(dispatch.device.vkCreateFence(device, &.{ .sType = 8 }, null, &result.present_fences[i]));
        }
        try check(procs.vkCreateSemaphore(device, &.{}, null, &result.acquired));
        errdefer procs.vkDestroySemaphore(device, result.acquired, null);
        return result;
    }
    pub fn deinit(self: *Window) void {
        const idle = self.dispatch.device.vkDeviceWaitIdle(self.device);
        if (idle != 0 and idle != -4) @panic("cannot prove window rendering completion");
        // Unlike queue-idle, maintenance1 fences cover presentation ownership.
        for (0..self.count) |i| {
            if (self.presented[i]) {
                const status = self.dispatch.device.vkWaitForFences(self.device, 1, @ptrCast(&self.present_fences[i]), 1, std.math.maxInt(u64));
                if (status != 0 and status != -4) @panic("cannot prove presentation completion");
            }
            self.dispatch.device.vkDestroyFence(self.device, self.present_fences[i], null);
        }
        for (self.views[0..self.count]) |view| self.dispatch.device.vkDestroyImageView(self.device, view, null);
        for (self.finished[0..self.count]) |semaphore| self.procs.vkDestroySemaphore(self.device, semaphore, null);
        self.procs.vkDestroySemaphore(self.device, self.acquired, null);
        self.procs.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        self.procs.vkDestroySurfaceKHR(self.instance, self.surface, null);
        self.native.deinit();
    }
    pub fn acquire(self: *Window) !gpu.Swapchain {
        if (comptime builtin.os.tag == .windows) self.native.pump();
        const status = self.procs.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.acquired, 0, &self.index);
        if (status != 1000001003) try check(status); // SUBOPTIMAL still acquires
        if (self.presented[self.index]) {
            try check(self.dispatch.device.vkWaitForFences(self.device, 1, @ptrCast(&self.present_fences[self.index]), 1, std.math.maxInt(u64)));
            self.presented[self.index] = false; // the completed use is proven before reset
            try check(self.dispatch.device.vkResetFences(self.device, 1, @ptrCast(&self.present_fences[self.index])));
        }
        return .{ .width = 64, .height = 64, .color_format = self.format, .depth_format = .none, .native = .{ .vulkan = .{ .render_image = @ptrFromInt(self.images[self.index]), .render_view = @ptrFromInt(self.views[self.index]), .render_finished_semaphore = @ptrFromInt(self.finished[self.index]), .present_complete_semaphore = @ptrFromInt(self.acquired) } } };
    }
    pub fn present(self: *Window, verify: bool, physical: vk.PhysicalDevice) !void {
        if (verify) try self.verifyPixel(physical);
        const fence_info: PresentFenceInfo = .{ .pFences = &self.present_fences[self.index] };
        const result = self.procs.vkQueuePresentKHR(self.queue, &.{ .pNext = &fence_info, .pWaitSemaphores = &self.finished[self.index], .pSwapchains = &self.swapchain, .pImageIndices = &self.index });
        if (result != 0 and result != 1000001003) {
            if (result == -4) return error.VulkanWindowDeviceLost;
            // Failed presentation can leave ownership uncertain; this test host
            // must not unwind and destroy synchronization objects speculatively.
            @panic("presentation failed without a completion proof");
        }
        self.presented[self.index] = true;
        try check(self.dispatch.device.vkQueueWaitIdle(self.queue));
    }
    fn verifyPixel(self: *Window, physical: vk.PhysicalDevice) !void {
        const d = &self.dispatch.device;
        try check(d.vkQueueWaitIdle(self.queue));
        var buffer: u64 = 0;
        try check(d.vkCreateBuffer(self.device, &.{ .sType = 12, .size = 4, .usage = 2 }, null, &buffer));
        defer d.vkDestroyBuffer(self.device, buffer, null);
        var req: vk.MemoryRequirements = .{};
        d.vkGetBufferMemoryRequirements(self.device, buffer, &req);
        var props: vk.PhysicalDeviceMemoryProperties = .{};
        self.dispatch.instance.vkGetPhysicalDeviceMemoryProperties(physical, &props);
        const memory_type = for (props.memoryTypes[0..props.memoryTypeCount], 0..) |memory, i| {
            if (req.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and memory.propertyFlags & 6 == 6) break i;
        } else return error.NoHostCoherentMemory;
        var memory: u64 = 0;
        try check(d.vkAllocateMemory(self.device, &.{ .sType = 5, .allocationSize = req.size, .memoryTypeIndex = @intCast(memory_type) }, null, &memory));
        defer d.vkFreeMemory(self.device, memory, null);
        try check(d.vkBindBufferMemory(self.device, buffer, memory, 0));
        var pool: u64 = 0;
        try check(d.vkCreateCommandPool(self.device, &.{ .sType = 39, .queueFamilyIndex = self.family }, null, &pool));
        defer d.vkDestroyCommandPool(self.device, pool, null);
        var cmd: vk.CommandBuffer = null;
        try check(d.vkAllocateCommandBuffers(self.device, &.{ .sType = 40, .commandPool = pool, .commandBufferCount = 1 }, &cmd));
        try check(d.vkBeginCommandBuffer(cmd, &.{ .sType = 42, .flags = 1 }));
        var barrier: vk.ImageMemoryBarrier2 = .{ .sType = 1000314002, .srcStageMask = 0x10000, .srcAccessMask = 0x10000, .dstStageMask = 0x1000, .dstAccessMask = 0x800, .oldLayout = 1000001002, .newLayout = 6, .srcQueueFamilyIndex = 0xffffffff, .dstQueueFamilyIndex = 0xffffffff, .image = self.images[self.index], .subresourceRange = .{ .aspectMask = 1, .levelCount = 1, .layerCount = 1 } };
        d.vkCmdPipelineBarrier2(cmd, &.{ .sType = 1000314003, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &barrier });
        const copy: vk.BufferImageCopy = .{ .imageSubresource = .{ .aspectMask = 1, .layerCount = 1 }, .imageOffset = .{ .x = 32, .y = 32, .z = 0 }, .imageExtent = .{ .width = 1, .height = 1, .depth = 1 } };
        d.vkCmdCopyImageToBuffer(cmd, self.images[self.index], 6, buffer, 1, @ptrCast(&copy));
        barrier.srcStageMask = 0x1000;
        barrier.srcAccessMask = 0x800;
        barrier.dstStageMask = 0;
        barrier.dstAccessMask = 0;
        barrier.oldLayout = 6;
        barrier.newLayout = 1000001002;
        const host: vk.BufferMemoryBarrier2 = .{ .sType = 1000314001, .srcStageMask = 0x1000, .srcAccessMask = 0x1000, .dstStageMask = 0x4000, .dstAccessMask = 0x2000, .srcQueueFamilyIndex = 0xffffffff, .dstQueueFamilyIndex = 0xffffffff, .buffer = buffer, .size = 4 };
        d.vkCmdPipelineBarrier2(cmd, &.{ .sType = 1000314003, .imageMemoryBarrierCount = 1, .pImageMemoryBarriers = &barrier, .bufferMemoryBarrierCount = 1, .pBufferMemoryBarriers = &host });
        try check(d.vkEndCommandBuffer(cmd));
        const submit: vk.SubmitInfo = .{ .sType = 4, .commandBufferCount = 1, .pCommandBuffers = &cmd };
        try check(d.vkQueueSubmit(self.queue, 1, @ptrCast(&submit), 0));
        try check(d.vkQueueWaitIdle(self.queue));
        var mapped: ?*anyopaque = null;
        try check(d.vkMapMemory(self.device, memory, 0, 4, 0, &mapped));
        defer d.vkUnmapMemory(self.device, memory);
        const pixel: *const [4]u8 = @ptrCast(mapped.?);
        const expected: [4]u8 = if (self.format == .rgba8) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
        if (!std.mem.eql(u8, pixel, &expected)) return error.PresentationPixelMismatch;
    }
};
