//! Win32 flip-model presentation host shared by the D3D11 and D3D12 tests.
const std = @import("std");
const gpu = @import("zicr").gpu;
const sdk = gpu.raw.native.d3d12;
const d11 = gpu.raw.native.d3d11;
const Library = gpu.raw.native.WindowsLibrary;
const NativeWindow = @import("win32.zig").Window;
const factory_iid: sdk.Guid = .{ .data1 = 0x50c83a1c, .data2 = 0xe072, .data3 = 0x4c48, .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
const swap_iid: sdk.Guid = .{ .data1 = 0x94d99bdb, .data2 = 0xf1f8, .data3 = 0x4ab0, .data4 = .{ 0xb2, 0x36, 0x7d, 0xa0, 0x17, 0x0e, 0xda, 0xb1 } };
const texture_iid: sdk.Guid = .{ .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89, .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };
const FullscreenDesc = extern struct { refresh_numerator: u32 = 60, refresh_denominator: u32 = 1, scanline: u32 = 0, scaling: u32 = 0, windowed: i32 = 1 };
const Desc = extern struct { width: u32 = 64, height: u32 = 64, format: u32 = 28, stereo: i32 = 0, sample: sdk.SampleDesc = .{}, usage: u32 = 0x20, buffer_count: u32 = 2, scaling: u32 = 0, swap_effect: u32 = 4, alpha_mode: u32 = 3, flags: u32 = 0 };
fn check(status: i32) !void {
    if (status < 0) return error.WindowsPresentationFailed;
}
pub const Window = struct {
    native: NativeWindow,
    dxgi: Library,
    swap: *sdk.Object,
    device: *sdk.Object,
    queue_or_context: *sdk.Object,
    d3d12: bool,
    buffers: [2]?*sdk.Object = @splat(null),
    views: [2]?*sdk.Object = @splat(null),
    index: u32 = 0,
    fence: ?*sdk.Object = null,
    event: sdk.Handle = null,
    serial: u64 = 0,

    pub fn create(device: *sdk.Object, queue_or_context: *sdk.Object, d3d12: bool) !Window {
        var native = try NativeWindow.create();
        errdefer native.deinit();
        const dxgi = try Library.open("dxgi.dll");
        errdefer dxgi.close();
        const CreateFactory = *const fn (u32, *const sdk.Guid, *?*sdk.Object) callconv(sdk.call_conv) i32;
        const create_factory = dxgi.lookup(CreateFactory, "CreateDXGIFactory2") orelse return error.MissingFactoryFunction;
        var factory: ?*sdk.Object = null;
        try check(create_factory(0, &factory_iid, &factory));
        defer sdk.release(factory);
        const CreateSwap = *const fn (*sdk.Object, *sdk.Object, *anyopaque, *const Desc, ?*const anyopaque, ?*sdk.Object, *?*sdk.Object) callconv(sdk.call_conv) i32;
        var first: ?*sdk.Object = null;
        try check(sdk.invoke(15, CreateSwap, factory.?, .{ if (d3d12) queue_or_context else device, native.handle, &Desc{}, @as(?*const anyopaque, &FullscreenDesc{}), @as(?*sdk.Object, null), &first }));
        defer sdk.release(first);
        var swap: ?*sdk.Object = null;
        try check(sdk.queryInterface(first.?, &swap_iid, &swap));
        errdefer sdk.release(swap);
        var result: Window = .{ .native = native, .dxgi = dxgi, .swap = swap.?, .device = device, .queue_or_context = queue_or_context, .d3d12 = d3d12 };
        errdefer {
            for (result.views) |view| sdk.release(view);
            for (result.buffers) |buffer| sdk.release(buffer);
        }
        const GetBuffer = *const fn (*sdk.Object, u32, *const sdk.Guid, *?*sdk.Object) callconv(sdk.call_conv) i32;
        for (0..@as(usize, if (d3d12) 2 else 1)) |i| {
            try check(sdk.invoke(9, GetBuffer, result.swap, .{ @as(u32, @intCast(i)), if (d3d12) &sdk.iid_resource else &texture_iid, &result.buffers[i] }));
            if (!d3d12) try check(d11.createRenderTargetView(device, result.buffers[i], null, &result.views[i]));
        }
        if (d3d12) {
            try check(sdk.createFence(device, 0, &result.fence));
            errdefer sdk.release(result.fence);
            result.event = sdk.createEvent() orelse return error.FenceEventFailed;
        }
        return result;
    }
    pub fn deinit(self: *Window) void {
        if (self.d3d12) self.waitQueue() catch @panic("cannot prove presentation queue completion");
        for (self.views) |view| sdk.release(view);
        for (self.buffers) |buffer| sdk.release(buffer);
        sdk.release(self.fence);
        if (self.event != null) sdk.closeEvent(self.event);
        sdk.release(self.swap);
        self.dxgi.close();
        self.native.deinit();
    }
    pub fn acquire(self: *Window) !gpu.Swapchain {
        self.native.pump();
        const Current = *const fn (*sdk.Object) callconv(sdk.call_conv) u32;
        // D3D11 exposes the rotating logical backbuffer as GetBuffer(0).
        // D3D12 exposes each physical buffer and requires the current index.
        self.index = if (self.d3d12) sdk.invoke(36, Current, self.swap, .{}) else 0;
        if (self.index >= 2) return error.InvalidBackBufferIndex;
        return .{ .width = 64, .height = 64, .color_format = .rgba8, .depth_format = .none, .native = if (self.d3d12) .{ .d3d12 = .{ .render_target = self.buffers[self.index].? } } else .{ .d3d11 = .{ .render_view = self.views[self.index].? } } };
    }
    pub fn present(self: *Window, verify: bool) !void {
        if (verify) {
            if (self.d3d12) try self.verify12() else try self.verify11();
        }
        const Present = *const fn (*sdk.Object, u32, u32) callconv(sdk.call_conv) i32;
        try check(sdk.invoke(8, Present, self.swap, .{ @as(u32, 0), @as(u32, 0) }));
        if (self.d3d12) try self.waitQueue();
    }
    fn waitQueue(self: *Window) !void {
        self.serial += 1;
        try check(sdk.queueSignal(self.queue_or_context, self.fence.?, self.serial));
        if (sdk.fenceCompletedValue(self.fence.?) < self.serial) {
            try check(sdk.fenceSetEventOnCompletion(self.fence.?, self.serial, self.event));
            sdk.waitEvent(self.event, 0xffffffff);
        }
        const completed = sdk.fenceCompletedValue(self.fence.?);
        if (completed < self.serial or completed == std.math.maxInt(u64)) return error.FenceWaitFailed;
    }
    fn verify11(self: *Window) !void {
        var staging: ?*sdk.Object = null;
        const desc: d11.Texture2DDesc = .{ .width = 1, .height = 1, .mip_levels = 1, .array_size = 1, .format = 28, .usage = 3, .cpu_access_flags = 0x20000 };
        try check(d11.createTexture2D(self.device, @ptrCast(&desc), null, &staging));
        defer sdk.release(staging);
        const box: d11.Box = .{ .left = 32, .top = 32, .front = 0, .right = 33, .bottom = 33, .back = 1 };
        d11.copySubresourceRegion(self.queue_or_context, staging, 0, 0, 0, 0, self.buffers[self.index], 0, @ptrCast(&box));
        var mapped: d11.MappedSubresource = .{};
        try check(d11.map(self.queue_or_context, staging, 0, 1, 0, @ptrCast(&mapped)));
        defer d11.unmap(self.queue_or_context, staging, 0);
        const pixel: *const [4]u8 = @ptrCast(mapped.data.?);
        if (!std.mem.eql(u8, pixel, &.{ 0, 0, 255, 255 })) return error.PresentationPixelMismatch;
    }
    fn verify12(self: *Window) !void {
        var staging: ?*sdk.Object = null;
        try check(sdk.createCommittedResource(self.device, &.{ .type = 3 }, 0, &.{ .dimension = 1, .width = 256, .height = 1, .depth_or_array_size = 1, .mip_levels = 1, .layout = 1 }, 0x400, &staging));
        defer sdk.release(staging);
        var allocator: ?*sdk.Object = null;
        try check(sdk.createCommandAllocator(self.device, 0, &allocator));
        defer sdk.release(allocator);
        var list: ?*sdk.Object = null;
        try check(sdk.createCommandList(self.device, 0, allocator.?, &list));
        defer sdk.release(list);
        var barrier: sdk.ResourceBarrier = .{ .payload = .{ .transition = .{ .resource = self.buffers[self.index], .subresource = 0xffffffff, .state_before = 0, .state_after = 0x800 } } };
        sdk.resourceBarrier(list.?, 1, @ptrCast(&barrier));
        const source: sdk.TextureCopyLocation = .{ .resource = self.buffers[self.index], .payload = .{ .subresource_index = 0 } };
        const destination: sdk.TextureCopyLocation = .{ .resource = staging, .type = 1, .payload = .{ .placed = .{ .footprint = .{ .format = 28, .width = 1, .height = 1, .depth = 1, .row_pitch = 256 } } } };
        const box: sdk.Box = .{ .left = 32, .top = 32, .front = 0, .right = 33, .bottom = 33, .back = 1 };
        sdk.copyTextureRegion(list.?, &destination, 0, 0, 0, &source, &box);
        barrier.payload.transition.state_before = 0x800;
        barrier.payload.transition.state_after = 0;
        sdk.resourceBarrier(list.?, 1, @ptrCast(&barrier));
        try check(sdk.listClose(list.?));
        sdk.queueExecuteCommandLists(self.queue_or_context, 1, @ptrCast(&list));
        self.waitQueue() catch @panic("cannot retire presentation copy without GPU completion");
        var mapped: ?*anyopaque = null;
        try check(sdk.resourceMap(staging.?, 0, &mapped));
        defer sdk.resourceUnmap(staging.?, 0);
        const pixel: *const [4]u8 = @ptrCast(mapped.?);
        if (!std.mem.eql(u8, pixel, &.{ 0, 0, 255, 255 })) return error.PresentationPixelMismatch;
    }
};
