//! Device memory, delete queues, shared (double-buffered) CPU-write buffers,
//! staging copies and streams, the uniform data system and the descriptor
//! buffer, sokol_gfx.h:21254-22195.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");
const c = @import("../../constants.zig");
const formats = @import("../../formats.zig");
const config = @import("../../config.zig");
const sdk = @import("sdk.zig");
const barrier = @import("barrier.zig");
const res = @import("resources.zig");
const Backend = @import("backend.zig").Backend;

const num_inflight = c.num_inflight_frames;

/// An array of `n` default-initialized values, for array field defaults.
pub fn fillDefault(comptime T: type, comptime n: usize) [n]T {
    var arr: [n]T = undefined;
    for (&arr) |*x| x.* = .{};
    return arr;
}
/// Returned by `SharedBuffer.alloc` when the buffer is full.
pub const overflow_result: u64 = 0xFFFF_FFFF;

pub const MemType = enum {
    storage_buffer,
    generic_buffer,
    image,
    staging_copy,
    staging_stream,
    uniforms,
    descriptors,
};

/// Destructors of the delete queue; the object is a raw handle or memory value.
pub const DestroyKind = enum {
    memory,
    buffer,
    image,
    image_view,
    sampler,
    shader_module,
    pipeline_layout,
    descriptor_set_layout,
    pipeline,
};

pub const DeleteItem = struct {
    kind: DestroyKind = .memory,
    obj: u64 = 0,
};

/// Objects that are destroyed once the frame that may still use them has finished.
pub const DeleteQueue = struct {
    index: u32 = 0,
    items: []DeleteItem = &.{},
};

/// A double-buffered CPU-write buffer, one allocation per in-flight frame.
pub const SharedBuffer = struct {
    size: u32 = 0,
    align_: u32 = 0,
    offset: u32 = 0,
    cur_buf: sdk.Buffer = 0,
    cur_mem_ptr: ?[*]u8 = null,
    /// Current buffer device address, may be 0.
    cur_dev_addr: u64 = 0,
    overflown: bool = false,
    slots: [num_inflight]Slot = fillDefault(Slot, num_inflight),

    pub const Slot = struct {
        buf: sdk.Buffer = 0,
        mem: sdk.DeviceMemory = 0,
        dev_addr: u64 = 0,
        mem_ptr: ?[*]u8 = null,
    };
};

/// Hazard tracking for buffers and images that are written in a pass.
pub const Track = struct {
    slots: []u32 = &.{},
    occupy: []bool = &.{},
    cur_slot: usize = 0,

    pub fn init(allocator: std.mem.Allocator, num_slots: usize) !Track {
        const slots = try allocator.alloc(u32, num_slots);
        errdefer allocator.free(slots);
        const occupy = try allocator.alloc(bool, num_slots);
        @memset(occupy, false);
        return .{ .slots = slots, .occupy = occupy };
    }

    pub fn deinit(self: *Track, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
        allocator.free(self.occupy);
        self.* = .{};
    }

    pub fn reset(self: *Track) void {
        self.cur_slot = 0;
        @memset(self.occupy, false);
    }

    pub fn add(self: *Track, id: u32) void {
        const idx = slotIndex(id);
        // don't record the same resource twice
        if (!self.occupy[idx]) {
            std.debug.assert(self.cur_slot < self.slots.len);
            self.slots[self.cur_slot] = id;
            self.cur_slot += 1;
            self.occupy[idx] = true;
        }
    }

    pub fn remove(self: *Track, id: u32) void {
        const idx = slotIndex(id);
        if (self.occupy[idx]) {
            self.occupy[idx] = false;
            for (self.slots[0..self.cur_slot], 0..) |slot_id, i| {
                if (slot_id == id) {
                    self.cur_slot -= 1;
                    self.slots[i] = self.slots[self.cur_slot];
                    break;
                }
            }
        }
    }
};

fn slotIndex(id: u32) usize {
    return @import("../../pool.zig").slotIndex(id);
}

// ---------------------------------------------------------------- labels

/// Attaches a debug name to a Vulkan object (debug builds only).
pub fn setObjectLabel(self: *Backend, obj_type: i32, handle: u64, label: ?[*:0]const u8) void {
    if (!config.debug) return;
    const set_name = self.fns.device.vkSetDebugUtilsObjectNameEXT orelse return;
    if (label) |l| {
        const name_info: sdk.DebugUtilsObjectNameInfoEXT = .{
            .sType = sdk.STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT,
            .pNext = null,
            .objectType = obj_type,
            .objectHandle = handle,
            .pObjectName = l,
        };
        _ = set_name(self.dev, &name_info);
    }
}

// ---------------------------------------------------------------- device memory

fn findMemoryTypeIndex(self: *Backend, type_filter: u32, props: u32) ?u32 {
    var mem_props: sdk.PhysicalDeviceMemoryProperties = std.mem.zeroes(sdk.PhysicalDeviceMemoryProperties);
    self.fns.instance.vkGetPhysicalDeviceMemoryProperties(self.phys_dev, &mem_props);
    for (0..mem_props.memoryTypeCount) |i| {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and (mem_props.memoryTypes[i].propertyFlags & props) == props) {
            return @intCast(i);
        }
    }
    return null;
}

/// Allocates device memory for a resource; returns 0 (after logging) on failure.
pub fn allocDeviceMemory(self: *Backend, mem_type: MemType, mem_reqs: *const sdk.MemoryRequirements) sdk.DeviceMemory {
    var prop_flags: u32 = 0;
    var alloc_flags: u32 = 0;
    switch (mem_type) {
        .generic_buffer, .image => prop_flags = sdk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        .storage_buffer => {
            prop_flags = sdk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT;
            alloc_flags = sdk.MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        },
        .staging_copy, .staging_stream => prop_flags = sdk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | sdk.MEMORY_PROPERTY_HOST_COHERENT_BIT,
        .uniforms, .descriptors => {
            prop_flags = sdk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | sdk.MEMORY_PROPERTY_HOST_COHERENT_BIT;
            alloc_flags = sdk.MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;
        },
    }
    const mem_type_index = findMemoryTypeIndex(self, mem_reqs.memoryTypeBits, prop_flags) orelse {
        core.logError(.vulkan_alloc_device_memory_no_suitable_memory_type);
        return 0;
    };
    const flags_info: sdk.MemoryAllocateFlagsInfo = .{
        .sType = sdk.STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
        .pNext = null,
        .flags = alloc_flags,
        .deviceMask = 0,
    };
    const alloc_info: sdk.MemoryAllocateInfo = .{
        .sType = sdk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = @constCast(@as(*const anyopaque, @ptrCast(&flags_info))),
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = mem_type_index,
    };
    var vk_dev_mem: sdk.DeviceMemory = 0;
    const r = self.fns.device.vkAllocateMemory(self.dev, &alloc_info, null, &vk_dev_mem);
    core.statsInc("vk.num_allocate_memory");
    core.statsAdd("vk.size_allocate_memory", @intCast(mem_reqs.size));
    if (r != sdk.SUCCESS) {
        core.logError(.vulkan_allocate_memory_failed);
        return 0;
    }
    std.debug.assert(vk_dev_mem != 0);
    return vk_dev_mem;
}

pub fn freeDeviceMemory(self: *Backend, mem: sdk.DeviceMemory) void {
    self.fns.device.vkFreeMemory(self.dev, mem, null);
    core.statsInc("vk.num_free_memory");
}

pub fn allocBufferDeviceMemory(self: *Backend, buf: *core.Buffer) bool {
    var reqs: sdk.MemoryRequirements = undefined;
    self.fns.device.vkGetBufferMemoryRequirements(self.dev, buf.native.vulkan.buf, &reqs);
    const mem_type: MemType = if (buf.cmn.usage.storage_buffer) .storage_buffer else .generic_buffer;
    buf.native.vulkan.mem = allocDeviceMemory(self, mem_type, &reqs);
    if (buf.native.vulkan.mem == 0) {
        core.logError(.vulkan_alloc_buffer_device_memory_failed);
        return false;
    }
    return true;
}

pub fn allocImageDeviceMemory(self: *Backend, img: *core.Image) bool {
    var reqs: sdk.MemoryRequirements = undefined;
    self.fns.device.vkGetImageMemoryRequirements(self.dev, img.native.vulkan.img, &reqs);
    img.native.vulkan.mem = allocDeviceMemory(self, .image, &reqs);
    if (img.native.vulkan.mem == 0) {
        core.logError(.vulkan_alloc_image_device_memory_failed);
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- delete queues

pub fn createDeleteQueues(self: *Backend, desc: *const t.Desc) !void {
    const num_items: usize = @intCast(2 * desc.buffer_pool_size +
        2 * desc.image_pool_size +
        1 * desc.sampler_pool_size +
        5 * desc.shader_pool_size +
        2 * desc.pipeline_pool_size +
        1 * desc.view_pool_size +
        256);
    for (&self.frame.slots) |*slot| {
        slot.delete_queue.items = try self.allocator.alloc(DeleteItem, num_items);
        slot.delete_queue.index = 0;
    }
}

fn deleteQueueDestroyItems(self: *Backend, queue: *DeleteQueue) void {
    for (queue.items[0..queue.index]) |item| {
        destroyObject(self, item);
    }
    core.statsAdd("vk.num_delete_queue_collected", queue.index);
    queue.index = 0;
}

pub fn destroyDeleteQueues(self: *Backend) void {
    for (&self.frame.slots) |*slot| {
        deleteQueueDestroyItems(self, &slot.delete_queue);
        self.allocator.free(slot.delete_queue.items);
        slot.delete_queue.items = &.{};
    }
}

fn destroyObject(self: *Backend, item: DeleteItem) void {
    const d = &self.fns.device;
    switch (item.kind) {
        .memory => freeDeviceMemory(self, item.obj),
        .buffer => d.vkDestroyBuffer(self.dev, item.obj, null),
        .image => d.vkDestroyImage(self.dev, item.obj, null),
        .image_view => d.vkDestroyImageView(self.dev, item.obj, null),
        .sampler => d.vkDestroySampler(self.dev, item.obj, null),
        .shader_module => d.vkDestroyShaderModule(self.dev, item.obj, null),
        .pipeline_layout => d.vkDestroyPipelineLayout(self.dev, item.obj, null),
        .descriptor_set_layout => d.vkDestroyDescriptorSetLayout(self.dev, item.obj, null),
        .pipeline => d.vkDestroyPipeline(self.dev, item.obj, null),
    }
}

/// Destroys the objects of the current frame slot that are no longer in flight.
pub fn deleteQueueCollect(self: *Backend) void {
    deleteQueueDestroyItems(self, &self.frame.slots[self.frame_slot].delete_queue);
}

/// Defers destruction of an object until the in-flight frames are done.
pub fn deleteQueueAdd(self: *Backend, kind: DestroyKind, obj: u64) void {
    std.debug.assert(obj != 0);
    const queue = &self.frame.slots[self.frame_slot].delete_queue;
    if (queue.index >= queue.items.len) {
        core.logPanic(.vulkan_delete_queue_exhausted);
    }
    queue.items[queue.index] = .{ .kind = kind, .obj = obj };
    queue.index += 1;
    core.statsInc("vk.num_delete_queue_added");
}

// ---------------------------------------------------------------- shared buffers

fn roundupPow2(val: u32, alignment: u32) u32 {
    return core.alignU32(val, alignment);
}

pub fn sharedBufferInit(self: *Backend, shbuf: *SharedBuffer, size: u32, alignment: u32, mem_type: MemType, label: ?[*:0]const u8) void {
    std.debug.assert(size > 0 and alignment > 0);
    var vk_usage: u32 = 0;
    var want_device_address = false;
    switch (mem_type) {
        .staging_stream => vk_usage = sdk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        .uniforms => {
            vk_usage = sdk.BUFFER_USAGE_UNIFORM_BUFFER_BIT | sdk.BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
            want_device_address = true;
        },
        .descriptors => {
            vk_usage = sdk.BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | sdk.BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT | sdk.BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
            want_device_address = true;
        },
        else => unreachable,
    }
    shbuf.size = roundupPow2(size, alignment);
    shbuf.align_ = alignment;
    for (&shbuf.slots) |*slot| {
        const create_info: sdk.BufferCreateInfo = .{
            .sType = sdk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = shbuf.size,
            .usage = vk_usage,
            .sharingMode = sdk.SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        if (self.fns.device.vkCreateBuffer(self.dev, &create_info, null, &slot.buf) != sdk.SUCCESS) {
            core.logPanic(.vulkan_create_shared_buffer_failed);
        }
        setObjectLabel(self, sdk.OBJECT_TYPE_BUFFER, slot.buf, label);

        var reqs: sdk.MemoryRequirements = undefined;
        self.fns.device.vkGetBufferMemoryRequirements(self.dev, slot.buf, &reqs);
        slot.mem = allocDeviceMemory(self, mem_type, &reqs);
        if (slot.mem == 0) core.logPanic(.vulkan_allocate_shared_buffer_memory_failed);
        if (self.fns.device.vkBindBufferMemory(self.dev, slot.buf, slot.mem, 0) != sdk.SUCCESS) {
            core.logPanic(.vulkan_bind_shared_buffer_memory_failed);
        }
        if (want_device_address) {
            const addr_info: sdk.BufferDeviceAddressInfo = .{
                .sType = sdk.STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
                .pNext = null,
                .buffer = slot.buf,
            };
            slot.dev_addr = self.fns.device.vkGetBufferDeviceAddress(self.dev, &addr_info);
            std.debug.assert(slot.dev_addr != 0);
        }
        var mem_ptr: ?*anyopaque = null;
        if (self.fns.device.vkMapMemory(self.dev, slot.mem, 0, sdk.WHOLE_SIZE, 0, &mem_ptr) != sdk.SUCCESS) {
            core.logPanic(.vulkan_map_shared_buffer_memory_failed);
        }
        slot.mem_ptr = @ptrCast(mem_ptr);
    }
}

pub fn sharedBufferDiscard(self: *Backend, shbuf: *SharedBuffer) void {
    for (&shbuf.slots) |*slot| {
        if (slot.mem != 0) self.fns.device.vkUnmapMemory(self.dev, slot.mem);
        slot.mem_ptr = null;
        freeDeviceMemory(self, slot.mem);
        slot.mem = 0;
        self.fns.device.vkDestroyBuffer(self.dev, slot.buf, null);
        slot.buf = 0;
        slot.dev_addr = 0;
    }
    shbuf.size = 0;
    shbuf.offset = 0;
    shbuf.cur_buf = 0;
    shbuf.cur_dev_addr = 0;
    shbuf.overflown = false;
}

pub fn sharedBufferAfterAcquire(self: *Backend, shbuf: *SharedBuffer) void {
    const slot = &shbuf.slots[self.frame_slot];
    shbuf.offset = 0;
    shbuf.cur_buf = slot.buf;
    shbuf.cur_mem_ptr = slot.mem_ptr;
    shbuf.cur_dev_addr = slot.dev_addr; // NOTE: may be 0
    shbuf.overflown = false;
    std.debug.assert(shbuf.cur_buf != 0 and shbuf.cur_mem_ptr != null);
}

pub fn sharedBufferBeforeSubmit(shbuf: *SharedBuffer) void {
    // NOTE: if the buffer wouldn't be cache-coherent, this would be the place to do a flush
    shbuf.cur_buf = 0;
    shbuf.cur_mem_ptr = null;
    shbuf.cur_dev_addr = 0;
}

pub fn sharedBufferAlloc(shbuf: *SharedBuffer, num_bytes: u32) u64 {
    std.debug.assert(num_bytes > 0);
    if (shbuf.overflown) return overflow_result;
    if (shbuf.offset + num_bytes > shbuf.size) {
        shbuf.overflown = true;
        return overflow_result;
    }
    std.debug.assert((shbuf.offset & (shbuf.align_ - 1)) == 0);
    const offset = shbuf.offset;
    shbuf.offset = roundupPow2(shbuf.offset + num_bytes, shbuf.align_);
    return offset;
}

pub fn sharedBufferPtr(shbuf: *SharedBuffer, offset: u64) [*]u8 {
    std.debug.assert(shbuf.cur_mem_ptr != null and !shbuf.overflown and offset < shbuf.size);
    return shbuf.cur_mem_ptr.? + @as(usize, @intCast(offset));
}

pub fn sharedBufferMemcpy(shbuf: *SharedBuffer, src: [*]const u8, num_bytes: u32) u64 {
    const offset = sharedBufferAlloc(shbuf, num_bytes);
    if (offset != overflow_result) {
        @memcpy(sharedBufferPtr(shbuf, offset)[0..num_bytes], src[0..num_bytes]);
    }
    return offset;
}

// ---------------------------------------------------------------- copy staging

pub fn stagingCopyInit(self: *Backend, desc: *const t.Desc) !void {
    std.debug.assert(desc.vulkan.copy_staging_buffer_size > 0);
    const pool_info: sdk.CommandPoolCreateInfo = .{
        .sType = sdk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = sdk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT | sdk.COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = self.queue_family_index,
    };
    if (self.fns.device.vkCreateCommandPool(self.dev, &pool_info, null, &self.stage.copy.cmd_pool) != sdk.SUCCESS) return error.VulkanInitFailed;
    setObjectLabel(self, sdk.OBJECT_TYPE_COMMAND_POOL, self.stage.copy.cmd_pool, "copy-staging cmd pool");

    const alloc_info: sdk.CommandBufferAllocateInfo = .{
        .sType = sdk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = self.stage.copy.cmd_pool,
        .level = sdk.COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    if (self.fns.device.vkAllocateCommandBuffers(self.dev, &alloc_info, &self.stage.copy.cmd_buf) != sdk.SUCCESS) return error.VulkanInitFailed;
    setObjectLabel(self, sdk.OBJECT_TYPE_COMMAND_BUFFER, @intFromPtr(self.stage.copy.cmd_buf), "copy-staging cmd buffer");

    self.stage.copy.size = @intCast(desc.vulkan.copy_staging_buffer_size);
    const buf_info: sdk.BufferCreateInfo = .{
        .sType = sdk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = self.stage.copy.size,
        .usage = sdk.BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = sdk.SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    if (self.fns.device.vkCreateBuffer(self.dev, &buf_info, null, &self.stage.copy.buf) != sdk.SUCCESS) {
        core.logPanic(.vulkan_staging_create_buffer_failed);
    }
    setObjectLabel(self, sdk.OBJECT_TYPE_BUFFER, self.stage.copy.buf, "copy-staging staging buffer");

    var reqs: sdk.MemoryRequirements = undefined;
    self.fns.device.vkGetBufferMemoryRequirements(self.dev, self.stage.copy.buf, &reqs);
    self.stage.copy.mem = allocDeviceMemory(self, .staging_copy, &reqs);
    if (self.stage.copy.mem == 0) core.logPanic(.vulkan_staging_allocate_memory_failed);
    if (self.fns.device.vkBindBufferMemory(self.dev, self.stage.copy.buf, self.stage.copy.mem, 0) != sdk.SUCCESS) {
        core.logPanic(.vulkan_staging_bind_buffer_memory_failed);
    }
}

pub fn stagingCopyDiscard(self: *Backend) void {
    freeDeviceMemory(self, self.stage.copy.mem);
    self.stage.copy.mem = 0;
    self.fns.device.vkDestroyBuffer(self.dev, self.stage.copy.buf, null);
    self.stage.copy.buf = 0;
    self.fns.device.vkDestroyCommandPool(self.dev, self.stage.copy.cmd_pool, null);
    self.stage.copy.cmd_pool = 0;
    self.stage.copy.cmd_buf = null;
    self.stage.copy.size = 0;
}

pub fn stagingCopyBegin(self: *Backend) sdk.CommandBuffer {
    const cmd_buf = self.stage.copy.cmd_buf;
    const begin_info: sdk.CommandBufferBeginInfo = .{
        .sType = sdk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = sdk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    const r = self.fns.device.vkBeginCommandBuffer(cmd_buf, &begin_info);
    std.debug.assert(r == sdk.SUCCESS);
    return cmd_buf;
}

/// Submits the copy command buffer and waits for the queue to become idle.
pub fn stagingCopyEnd(self: *Backend, cmd_buf: sdk.CommandBuffer) void {
    _ = self.fns.device.vkEndCommandBuffer(cmd_buf);
    var cmd = cmd_buf;
    const submit_info: sdk.SubmitInfo = .{
        .sType = sdk.STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = @ptrCast(&cmd),
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    var r = self.fns.device.vkQueueSubmit(self.queue, 1, @ptrCast(&submit_info), 0);
    std.debug.assert(r == sdk.SUCCESS);
    r = self.fns.device.vkQueueWaitIdle(self.queue);
    std.debug.assert(r == sdk.SUCCESS);
    r = self.fns.device.vkResetCommandBuffer(cmd_buf, 0);
    std.debug.assert(r == sdk.SUCCESS);
}

fn stagingMapMemcpyUnmap(self: *Backend, mem: sdk.DeviceMemory, src: [*]const u8, num_bytes: usize) void {
    var dst_ptr: ?*anyopaque = null;
    const r = self.fns.device.vkMapMemory(self.dev, mem, 0, sdk.WHOLE_SIZE, 0, &dst_ptr);
    std.debug.assert(r == sdk.SUCCESS and dst_ptr != null);
    const dst: [*]u8 = @ptrCast(dst_ptr.?);
    @memcpy(dst[0..num_bytes], src[0..num_bytes]);
    self.fns.device.vkUnmapMemory(self.dev, mem);
}

/// Blocking buffer update through the copy staging buffer (sokol_gfx.h:21695).
pub fn stagingCopyBufferData(self: *Backend, buf: *core.Buffer, src: *const t.Range, src_offset: usize, dst_offset: usize, copy_size: usize, initial_wait: bool) void {
    std.debug.assert(copy_size > 0);
    std.debug.assert(src.ptr != null and src.size > 0);
    std.debug.assert(src_offset + copy_size <= src.size);
    std.debug.assert(dst_offset + copy_size <= buf.cmn.size);
    // an initial wait is only needed for updating existing resources
    if (initial_wait) {
        _ = self.fns.device.vkQueueWaitIdle(self.queue);
    }
    const stage_mem = self.stage.copy.mem;
    const src_buf = self.stage.copy.buf;
    const dst_buf = buf.native.vulkan.buf;
    var src_ptr: [*]const u8 = @as([*]const u8, @ptrCast(src.ptr.?)) + src_offset;
    const dst_size: usize = self.stage.copy.size;
    var bytes_remaining = copy_size;
    var region: sdk.BufferCopy = .{ .srcOffset = 0, .dstOffset = dst_offset, .size = 0 };
    while (bytes_remaining > 0) {
        var bytes_to_copy: usize = undefined;
        if (bytes_remaining > dst_size) {
            bytes_to_copy = dst_size;
            bytes_remaining -= dst_size;
        } else {
            bytes_to_copy = bytes_remaining;
            bytes_remaining = 0;
        }
        region.size = bytes_to_copy;
        stagingMapMemcpyUnmap(self, stage_mem, src_ptr, bytes_to_copy);
        const cmd_buf = stagingCopyBegin(self);
        self.fns.device.vkCmdCopyBuffer(cmd_buf, src_buf, dst_buf, 1, @ptrCast(&region));
        core.statsInc("vk.num_cmd_copy_buffer");
        stagingCopyEnd(self, cmd_buf);
        src_ptr += bytes_to_copy;
        region.dstOffset += bytes_to_copy;
    }
    buf.native.vulkan.cur_access = barrier.defaultBufferAccessMask(buf.cmn.usage);
}

pub fn initVkImageStagingStructs(img: *const core.Image, vk_buf: sdk.Buffer, region: *sdk.BufferImageCopy2, copy_info: *sdk.CopyBufferToImageInfo2) void {
    region.* = std.mem.zeroes(sdk.BufferImageCopy2);
    region.sType = sdk.STRUCTURE_TYPE_BUFFER_IMAGE_COPY_2;
    if (core.isDepthOrDepthStencilFormat(img.cmn.pixel_format)) {
        region.imageSubresource.aspectMask = sdk.IMAGE_ASPECT_DEPTH_BIT;
        if (core.isDepthStencilFormat(img.cmn.pixel_format)) {
            region.imageSubresource.aspectMask = sdk.IMAGE_ASPECT_STENCIL_BIT;
        }
    } else {
        region.imageSubresource.aspectMask = sdk.IMAGE_ASPECT_COLOR_BIT;
    }
    region.imageSubresource.layerCount = 1;
    region.imageExtent.depth = 1;

    copy_info.* = std.mem.zeroes(sdk.CopyBufferToImageInfo2);
    copy_info.sType = sdk.STRUCTURE_TYPE_COPY_BUFFER_TO_IMAGE_INFO_2;
    copy_info.srcBuffer = vk_buf;
    copy_info.dstImage = img.native.vulkan.img;
    copy_info.dstImageLayout = sdk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    copy_info.regionCount = 1;
    copy_info.pRegions = region;
}

pub const MipSource = struct {
    ptr: [*]const u8,
    size: usize,
    offset: usize = 0,
    bytes_per_row: i32,
    bytes_per_slice: i32,
};

pub const MipRegion = struct {
    mip_level: i32,
    x: i32,
    y: i32,
    slice: i32,
    width: i32,
    height: i32,
    num_slices: i32,
};

/// Blocking copy of one mip level through the copy staging buffer (sokol_gfx.h:21765).
pub fn stagingCopyMiplevelData(self: *Backend, img: *core.Image, src: MipSource, reg: MipRegion, initial_wait: bool) void {
    std.debug.assert(img.native.vulkan.img != 0);
    if (initial_wait) _ = self.fns.device.vkQueueWaitIdle(self.queue);
    const mem = self.stage.copy.mem;
    var region: sdk.BufferImageCopy2 = undefined;
    var copy_info: sdk.CopyBufferToImageInfo2 = undefined;
    initVkImageStagingStructs(img, self.stage.copy.buf, &region, &copy_info);
    const block_dim = formats.blockDimension(img.cmn.pixel_format);
    const block_bytesize = formats.blockSize(img.cmn.pixel_format);
    region.bufferRowLength = @intCast(@divTrunc(src.bytes_per_row, block_bytesize) * block_dim);
    region.bufferImageHeight = @intCast(@divTrunc(src.bytes_per_slice, src.bytes_per_row) * block_dim);
    region.imageSubresource.mipLevel = @intCast(reg.mip_level);
    region.imageOffset.x = reg.x;
    region.imageExtent.width = @intCast(reg.width);

    // NOTE: each array and depth slice is copied individually, this simplifies
    // copying through a smallish staging buffer which may be smaller than a slice
    const max_rows: i32 = @intCast(@divTrunc(self.stage.copy.size, @as(u32, @intCast(src.bytes_per_row))));
    if (max_rows == 0) {
        core.logError(.vulkan_staging_image_row_pitch_greater_staging_buffer);
        return;
    }
    // actual number of slice-rows to copy (cannot use bytes_per_slice, the source may have gaps)
    const num_rows = formats.numRows(img.cmn.pixel_format, reg.height);
    var i: i32 = 0;
    while (i < reg.num_slices) : (i += 1) {
        var cur_ptr: [*]const u8 = src.ptr + src.offset + @as(usize, @intCast(i)) * @as(usize, @intCast(src.bytes_per_slice));
        const cur_slice = i + reg.slice;
        if (img.cmn.type == .@"3d") {
            region.imageOffset.z = cur_slice;
        } else {
            region.imageSubresource.baseArrayLayer = @intCast(cur_slice);
        }
        var rows_remaining = num_rows;
        var cur_row: i32 = 0;
        while (rows_remaining > 0) {
            var rows_to_copy: i32 = undefined;
            if (rows_remaining > max_rows) {
                rows_to_copy = max_rows;
                rows_remaining -= max_rows;
            } else {
                rows_to_copy = rows_remaining;
                rows_remaining = 0;
            }
            const bytes_to_copy: usize = @intCast(rows_to_copy * src.bytes_per_row);
            stagingMapMemcpyUnmap(self, mem, cur_ptr, bytes_to_copy);
            cur_ptr += bytes_to_copy;
            const cmd_buf = stagingCopyBegin(self);
            barrier.imageBarrier(&self.fns.device, cmd_buf, img, barrier.copy_dst);
            region.imageOffset.y = reg.y + cur_row * block_dim;
            region.imageExtent.height = @intCast(@min(reg.height, rows_to_copy * block_dim));
            self.fns.device.vkCmdCopyBufferToImage2(cmd_buf, &copy_info);
            core.statsInc("vk.num_cmd_copy_buffer_to_image");
            barrier.imageBarrier(&self.fns.device, cmd_buf, img, barrier.defaultImageAccessMask());
            stagingCopyEnd(self, cmd_buf);
            cur_row += rows_to_copy;
        }
    }
}

/// Blocking image update with all mip levels (sokol_gfx.h:21865).
pub fn stagingCopyImageData(self: *Backend, img: *core.Image, data: *const t.ImageData, initial_wait: bool) void {
    const fmt = img.cmn.pixel_format;
    var mip_level: i32 = 0;
    while (mip_level < img.cmn.num_mipmaps) : (mip_level += 1) {
        const level = data.mip_levels[@intCast(mip_level)];
        std.debug.assert(level.ptr != null and level.size > 0);
        const mip_width = core.miplevelDim(img.cmn.width, mip_level);
        const mip_height = core.miplevelDim(img.cmn.height, mip_level);
        const mip_depth_or_slices: i32 = if (img.cmn.type == .@"3d") core.miplevelDim(img.cmn.num_slices, mip_level) else img.cmn.num_slices;
        const bytes_per_row = formats.rowPitch(fmt, mip_width, 1);
        const bytes_per_slice = formats.surfacePitch(fmt, mip_width, mip_height, 1);
        stagingCopyMiplevelData(self, img, .{
            .ptr = @ptrCast(level.ptr.?),
            .size = level.size,
            .offset = 0,
            .bytes_per_row = bytes_per_row,
            .bytes_per_slice = bytes_per_slice,
        }, .{
            .mip_level = mip_level,
            .x = 0,
            .y = 0,
            .slice = 0,
            .width = mip_width,
            .height = mip_height,
            .num_slices = mip_depth_or_slices,
        }, if (mip_level == 0) initial_wait else false);
    }
}

// ---------------------------------------------------------------- streaming staging

pub fn stagingStreamInit(self: *Backend, desc: *const t.Desc) void {
    std.debug.assert(desc.vulkan.transient_staging_buffer_size > 0);
    sharedBufferInit(self, &self.stage.stream, @intCast(desc.vulkan.transient_staging_buffer_size), 16, .staging_stream, "shared-stream-buffer");
}

pub fn stagingStreamBufferData(self: *Backend, buf: *core.Buffer, src: *const t.Range, src_offset: usize, dst_offset: usize, copy_size: usize) void {
    std.debug.assert(self.stage.stream.cur_buf != 0);
    std.debug.assert(src.ptr != null and src.size > 0);
    std.debug.assert(src_offset + copy_size <= src.size);
    std.debug.assert(dst_offset + copy_size <= buf.cmn.size);
    const src_ptr: [*]const u8 = @as([*]const u8, @ptrCast(src.ptr.?)) + src_offset;
    const stage_offset = sharedBufferMemcpy(&self.stage.stream, src_ptr, @intCast(copy_size));
    if (stage_offset == overflow_result) {
        core.logError(.vulkan_staging_transient_buffer_overflow);
        return;
    }
    const cmd_buf = self.frame.stream_cmd_buf;
    const region: sdk.BufferCopy = .{ .srcOffset = stage_offset, .dstOffset = dst_offset, .size = copy_size };
    barrier.bufferBarrier(&self.fns.device, cmd_buf, buf, barrier.copy_dst);
    self.fns.device.vkCmdCopyBuffer(cmd_buf, self.stage.stream.cur_buf, buf.native.vulkan.buf, 1, @ptrCast(&region));
    core.statsInc("vk.num_cmd_copy_buffer");
    // FIXME: not great to issue a barrier right here, rethink buffer barrier strategy?
    barrier.bufferBarrier(&self.fns.device, cmd_buf, buf, barrier.defaultBufferAccessMask(buf.cmn.usage));
}

pub fn stagingStreamMiplevelData(self: *Backend, img: *core.Image, src: MipSource, reg: MipRegion) void {
    std.debug.assert(self.frame.stream_cmd_buf != null);
    std.debug.assert(img.native.vulkan.img != 0);
    const cmd_buf = self.frame.stream_cmd_buf;
    const block_dim = formats.blockDimension(img.cmn.pixel_format);
    const block_bytesize = formats.blockSize(img.cmn.pixel_format);
    const vk_copy_size = formats.imageCopySize(img.cmn.pixel_format, src.bytes_per_row, src.bytes_per_slice, reg.width, reg.height, reg.num_slices);
    var region: sdk.BufferImageCopy2 = undefined;
    var copy_info: sdk.CopyBufferToImageInfo2 = undefined;
    initVkImageStagingStructs(img, self.stage.stream.cur_buf, &region, &copy_info);
    region.bufferRowLength = @intCast(@divTrunc(src.bytes_per_row, block_bytesize) * block_dim);
    region.bufferImageHeight = @intCast(@divTrunc(src.bytes_per_slice, src.bytes_per_row) * block_dim);
    region.imageSubresource.mipLevel = @intCast(reg.mip_level);
    region.imageOffset.x = reg.x;
    region.imageOffset.y = reg.y;
    region.imageExtent.width = @intCast(reg.width);
    region.imageExtent.height = @intCast(reg.height);
    if (img.cmn.type == .@"3d") {
        region.imageOffset.z = reg.slice;
        region.imageExtent.depth = @intCast(reg.num_slices);
    } else {
        region.imageSubresource.baseArrayLayer = @intCast(reg.slice);
        region.imageSubresource.layerCount = @intCast(reg.num_slices);
    }
    const vk_src_ptr: [*]const u8 = src.ptr + src.offset;
    const vk_src_offset = sharedBufferMemcpy(&self.stage.stream, vk_src_ptr, @intCast(vk_copy_size));
    if (vk_src_offset == overflow_result) {
        core.logError(.vulkan_staging_transient_buffer_overflow);
        return;
    }
    region.bufferOffset = vk_src_offset;
    self.fns.device.vkCmdCopyBufferToImage2(cmd_buf, &copy_info);
    core.statsInc("vk.num_cmd_copy_buffer_to_image");
}

// ---------------------------------------------------------------- uniforms

pub fn uniformInit(self: *Backend, desc: *const t.Desc) !void {
    std.debug.assert(desc.uniform_buffer_size > 0);
    sharedBufferInit(self, &self.uniforms.dbuf, @intCast(desc.uniform_buffer_size), @intCast(self.dev_props.properties.limits.minUniformBufferOffsetAlignment), .uniforms, "shared-uniform-buffer");
    for (&self.uniforms.addr_info, &self.uniforms.get_info) |*addr, *get| {
        addr.sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_ADDRESS_INFO_EXT;
        get.sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_GET_INFO_EXT;
        get.type = sdk.DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    }
    // NOTE: the max alignment of uniform buffer descriptors is assumed to be the max descriptor size
    self.uniforms.dset_cache_size = c.max_uniformblock_bindslots * res.max_descriptor_data_size;
    self.uniforms.dset_cache = try self.allocator.alloc(u8, self.uniforms.dset_cache_size);
    @memset(self.uniforms.dset_cache, 0);
}

pub fn uniformDiscard(self: *Backend) void {
    self.allocator.free(self.uniforms.dset_cache);
    self.uniforms.dset_cache = &.{};
    sharedBufferDiscard(self, &self.uniforms.dbuf);
}

/// Called from the frame acquire, resets the per-frame uniform tracking.
pub fn uniformAfterAcquire(self: *Backend) void {
    sharedBufferAfterAcquire(self, &self.uniforms.dbuf);
    for (&self.uniforms.addr_info) |*info| {
        info.address = 0;
        info.range = 0;
    }
}

pub fn uniformBeforeSubmit(self: *Backend) void {
    sharedBufferBeforeSubmit(&self.uniforms.dbuf);
}

/// Copies uniform data into the uniform buffer, returns the offset of the snippet.
pub fn uniformCopy(self: *Backend, data: *const t.Range) u64 {
    std.debug.assert(data.ptr != null and data.size > 0);
    return sharedBufferMemcpy(&self.uniforms.dbuf, @ptrCast(data.ptr.?), @intCast(data.size));
}

// ---------------------------------------------------------------- descriptor buffer

pub fn bindInit(self: *Backend, desc: *const t.Desc) void {
    std.debug.assert(desc.vulkan.descriptor_buffer_size > 0);
    sharedBufferInit(self, &self.bind, @intCast(desc.vulkan.descriptor_buffer_size), @intCast(self.descriptor_buffer_props.descriptorBufferOffsetAlignment), .descriptors, "shared-descriptor-buffer");
}

pub fn bindDiscard(self: *Backend) void {
    sharedBufferDiscard(self, &self.bind);
}

/// Binds the current frame's descriptor buffer (sokol_gfx.h:22079).
pub fn bindAfterAcquire(self: *Backend) void {
    sharedBufferAfterAcquire(self, &self.bind);
    std.debug.assert(self.frame.cmd_buf != null and self.bind.cur_buf != 0 and self.bind.cur_dev_addr != 0);
    const bind_info: sdk.DescriptorBufferBindingInfoEXT = .{
        .sType = sdk.STRUCTURE_TYPE_DESCRIPTOR_BUFFER_BINDING_INFO_EXT,
        .pNext = null,
        .address = self.bind.cur_dev_addr,
        .usage = sdk.BUFFER_USAGE_RESOURCE_DESCRIPTOR_BUFFER_BIT_EXT | sdk.BUFFER_USAGE_SAMPLER_DESCRIPTOR_BUFFER_BIT_EXT,
    };
    self.fns.device.vkCmdBindDescriptorBuffersEXT.?(self.frame.cmd_buf, 1, @ptrCast(&bind_info));
}

pub fn bindBeforeSubmit(self: *Backend) void {
    sharedBufferBeforeSubmit(&self.bind);
}
