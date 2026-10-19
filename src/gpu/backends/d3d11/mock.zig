//! Functional COM device double for native resource ownership and failure tests.
const std = @import("std");
const sdk = @import("sdk.zig");
const c = @import("../dxgi/constants.zig");

pub const Kind = enum(u32) { device, context, buffer, image, sampler, shader, layout, rasterizer, depth, blend, view, blob };
const NativeObject = extern struct {
    table: [*]const ?*const anyopaque,
    owner: *Mock,
    refs: u32 = 1,
    kind: Kind,
    parent: ?*sdk.Object = null,
    data: [4096]u8 = @splat(0),
    length: usize = 0,
};
pub const Mock = struct {
    table: [120]?*const anyopaque = @splat(null),
    context_table: [120]?*const anyopaque = @splat(null),
    child_table: [16]?*const anyopaque = @splat(null),
    device: NativeObject = undefined,
    context: NativeObject = undefined,
    objects: [128]NativeObject = undefined,
    used: usize = 0,
    destroyed: usize = 0,
    attempts: usize = 0,
    fail_at: ?usize = null,
    level: u32 = c.feature_level_11_1,
    buffer_desc: sdk.BufferDesc = .{},
    texture_desc: sdk.Texture2DDesc = .{},
    texture3d_desc: sdk.Texture3DDesc = .{},
    sampler_desc: sdk.SamplerDesc = .{},
    rasterizer_desc: sdk.RasterizerDesc = .{},
    depth_desc: sdk.DepthStencilDesc = .{},
    blend_desc: sdk.BlendDesc = .{},
    srv_desc: sdk.ShaderResourceViewDesc = .{},
    uav_desc: sdk.UnorderedAccessViewDesc = .{},
    rtv_desc: sdk.RenderTargetViewDesc = .{},
    dsv_desc: sdk.DepthStencilViewDesc = .{},
    initial: [32]sdk.SubresourceData = @splat(.{}),
    initial_count: usize = 0,
    semantic: [32]u8 = @splat(0),
    compile_flags: u32 = 0,
    compile_count: usize = 0,
    compile_failed: bool = false,
    compile_warning: bool = false,
    label_calls: usize = 0,
    map_count: usize = 0,
    unmap_count: usize = 0,
    update_count: usize = 0,
    clear_count: usize = 0,
    last_map: u32 = 0,
    last_subresource: u32 = 0,
    last_box: sdk.Box = .{},
    viewport: sdk.Viewport = .{},
    rect: sdk.Rect = .{},
    events: [128]Event = undefined,
    event_count: usize = 0,
    pub const Event = enum { cs_srv, cs_uav, cs_sampler, draw, indexed, instanced, indexed_instanced, dispatch };

    pub fn init(self: *Mock) void {
        self.* = .{};
        self.child_table[1] = @ptrCast(&addRef);
        self.child_table[2] = @ptrCast(&release);
        self.child_table[3] = @ptrCast(&blobPointer);
        self.child_table[4] = @ptrCast(&blobSize);
        self.child_table[5] = @ptrCast(&setPrivateData);
        self.child_table[7] = @ptrCast(&getResource);
        self.table[1] = @ptrCast(&addRef);
        self.table[2] = @ptrCast(&release);
        self.table[sdk.indices.getFeatureLevel] = @ptrCast(&featureLevel);
        self.table[sdk.indices.checkFormatSupport] = @ptrCast(&formatSupport);
        self.table[sdk.indices.createBuffer] = @ptrCast(&createBuffer);
        self.table[sdk.indices.createTexture2D] = @ptrCast(&createTexture2D);
        self.table[sdk.indices.createTexture3D] = @ptrCast(&createTexture3D);
        self.table[sdk.indices.createSamplerState] = @ptrCast(&createSampler);
        self.table[sdk.indices.createVertexShader] = @ptrCast(&createVertex);
        self.table[sdk.indices.createPixelShader] = @ptrCast(&createPixel);
        self.table[sdk.indices.createComputeShader] = @ptrCast(&createCompute);
        self.table[sdk.indices.createInputLayout] = @ptrCast(&createLayout);
        self.table[sdk.indices.createRasterizerState] = @ptrCast(&createRasterizer);
        self.table[sdk.indices.createDepthStencilState] = @ptrCast(&createDepth);
        self.table[sdk.indices.createBlendState] = @ptrCast(&createBlend);
        self.table[sdk.indices.createShaderResourceView] = @ptrCast(&createSrv);
        self.table[sdk.indices.createUnorderedAccessView] = @ptrCast(&createUav);
        self.table[sdk.indices.createRenderTargetView] = @ptrCast(&createRtv);
        self.table[sdk.indices.createDepthStencilView] = @ptrCast(&createDsv);
        self.device = .{ .table = &self.table, .owner = self, .kind = .device };
        self.context_table[sdk.indices.map] = @ptrCast(&map);
        self.context_table[sdk.indices.unmap] = @ptrCast(&unmap);
        self.context_table[sdk.indices.updateSubresource] = @ptrCast(&update);
        self.context_table[sdk.indices.clearState] = @ptrCast(&clear);
        self.context_table[sdk.indices.rsSetViewports] = @ptrCast(&setViewports);
        self.context_table[sdk.indices.rsSetScissorRects] = @ptrCast(&setRects);
        self.context_table[sdk.indices.csSetShaderResources] = @ptrCast(&csSrv);
        self.context_table[sdk.indices.csSetUnorderedAccessViews] = @ptrCast(&csUav);
        self.context_table[sdk.indices.csSetSamplers] = @ptrCast(&csSampler);
        self.context_table[sdk.indices.draw] = @ptrCast(&draw);
        self.context_table[sdk.indices.drawIndexed] = @ptrCast(&drawIndexed);
        self.context_table[sdk.indices.drawInstanced] = @ptrCast(&drawInstanced);
        self.context_table[sdk.indices.drawIndexedInstanced] = @ptrCast(&drawIndexedInstanced);
        self.context_table[sdk.indices.dispatch] = @ptrCast(&dispatchCommand);
        self.context = .{ .table = &self.context_table, .owner = self, .kind = .context };
    }
    pub fn devicePointer(self: *Mock) *sdk.Object {
        return @ptrCast(&self.device);
    }
    pub fn contextPointer(self: *Mock) *sdk.Object {
        return @ptrCast(&self.context);
    }
    pub fn native(pointer: *sdk.Object) *NativeObject {
        return @ptrCast(@alignCast(pointer));
    }
    pub fn allocate(self: *Mock, kind: Kind) *sdk.Object {
        const entry = &self.objects[self.used];
        self.used += 1;
        entry.* = .{ .table = &self.child_table, .owner = self, .kind = kind };
        return @ptrCast(entry);
    }
    fn make(self: *Mock, kind: Kind, output: *?*sdk.Object) i32 {
        const attempt = self.attempts;
        self.attempts += 1;
        output.* = null;
        if (self.fail_at == attempt) return @bitCast(@as(u32, 0x80004005));
        output.* = self.allocate(kind);
        return 0;
    }
    fn addRef(object: *sdk.Object) callconv(sdk.call_conv) u32 {
        native(object).refs += 1;
        return native(object).refs;
    }
    fn release(object: *sdk.Object) callconv(sdk.call_conv) u32 {
        const entry = native(object);
        std.debug.assert(entry.refs > 0);
        entry.refs -= 1;
        if (entry.refs == 0) {
            entry.owner.destroyed += 1;
            sdk.release(entry.parent);
        }
        return entry.refs;
    }
    fn setPrivateData(object: *sdk.Object, guid: *const sdk.Guid, size: u32, data: ?*const anyopaque) callconv(sdk.call_conv) i32 {
        std.debug.assert(guid.data1 == 0x429b8c22 and (size == 0 or data != null));
        native(object).owner.label_calls += 1;
        return 0;
    }
    fn featureLevel(object: *sdk.Object) callconv(sdk.call_conv) u32 {
        return native(object).owner.level;
    }
    fn formatSupport(_: *sdk.Object, format: u32, output: ?[*]u32) callconv(sdk.call_conv) i32 {
        var value = c.format_support_texture2d | c.format_support_shader_sample | c.format_support_multisample_rendertarget | c.format_support_typed_unordered_access_view;
        if (format == c.format_d32_float or format == c.format_d32_float_s8x24_uint) value |= c.format_support_depth_stencil else value |= c.format_support_render_target | c.format_support_blendable;
        output.?[0] = value;
        return 0;
    }
    fn createBuffer(object: *sdk.Object, desc: ?[*]const sdk.BufferDesc, initial: ?[*]const sdk.SubresourceData, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        const self = native(object).owner;
        self.buffer_desc = desc.?[0];
        const status = self.make(.buffer, output);
        if (status >= 0) native(output.*.?).length = @min(self.buffer_desc.byte_width, native(output.*.?).data.len);
        if (status >= 0 and initial != null) {
            const entry = native(output.*.?);
            const source: [*]const u8 = @ptrCast(initial.?[0].data.?);
            @memcpy(entry.data[0..entry.length], source[0..entry.length]);
        }
        return status;
    }
    fn createTexture2D(object: *sdk.Object, desc: ?[*]const sdk.Texture2DDesc, initial: ?[*]const sdk.SubresourceData, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        const self = native(object).owner;
        self.texture_desc = desc.?[0];
        self.initial_count = if (initial != null) @intCast(desc.?[0].array_size * desc.?[0].mip_levels) else 0;
        if (initial) |data| @memcpy(self.initial[0..self.initial_count], data[0..self.initial_count]);
        return self.make(.image, output);
    }
    fn createTexture3D(object: *sdk.Object, desc: ?[*]const sdk.Texture3DDesc, initial: ?[*]const sdk.SubresourceData, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        const self = native(object).owner;
        self.texture3d_desc = desc.?[0];
        self.initial_count = if (initial != null) @intCast(desc.?[0].mip_levels) else 0;
        if (initial) |data| @memcpy(self.initial[0..self.initial_count], data[0..self.initial_count]);
        return self.make(.image, output);
    }
    fn createSampler(object: *sdk.Object, desc: ?[*]const sdk.SamplerDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.sampler_desc = desc.?[0];
        return native(object).owner.make(.sampler, output);
    }
    fn shader(object: *sdk.Object, bytes: ?*const anyopaque, length: usize, linkage: ?*sdk.Object, output: *?*sdk.Object) i32 {
        std.debug.assert(bytes != null and length > 0 and linkage == null);
        return native(object).owner.make(.shader, output);
    }
    fn createVertex(object: *sdk.Object, bytes: ?*const anyopaque, length: usize, linkage: ?*sdk.Object, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        return shader(object, bytes, length, linkage, output);
    }
    fn createPixel(object: *sdk.Object, bytes: ?*const anyopaque, length: usize, linkage: ?*sdk.Object, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        return shader(object, bytes, length, linkage, output);
    }
    fn createCompute(object: *sdk.Object, bytes: ?*const anyopaque, length: usize, linkage: ?*sdk.Object, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        return shader(object, bytes, length, linkage, output);
    }
    fn createLayout(object: *sdk.Object, elements: ?[*]const sdk.InputElementDesc, count: u32, bytes: ?*const anyopaque, length: usize, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        std.debug.assert(elements != null and count > 0 and bytes != null and length > 0);
        const self = native(object).owner;
        const text = std.mem.span(elements.?[0].semantic_name.?);
        @memcpy(self.semantic[0..text.len], text);
        return self.make(.layout, output);
    }
    fn createRasterizer(object: *sdk.Object, desc: ?[*]const sdk.RasterizerDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.rasterizer_desc = desc.?[0];
        return native(object).owner.make(.rasterizer, output);
    }
    fn createDepth(object: *sdk.Object, desc: ?[*]const sdk.DepthStencilDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.depth_desc = desc.?[0];
        return native(object).owner.make(.depth, output);
    }
    fn createBlend(object: *sdk.Object, desc: ?[*]const sdk.BlendDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.blend_desc = desc.?[0];
        return native(object).owner.make(.blend, output);
    }
    fn view(object: *sdk.Object, parent: ?*sdk.Object, output: *?*sdk.Object) i32 {
        const self = native(object).owner;
        const status = self.make(.view, output);
        if (status >= 0) {
            native(output.*.?).parent = parent;
            _ = addRef(parent.?);
        }
        return status;
    }
    fn createSrv(object: *sdk.Object, parent: ?*sdk.Object, desc: ?[*]const sdk.ShaderResourceViewDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.srv_desc = desc.?[0];
        return view(object, parent, output);
    }
    fn createUav(object: *sdk.Object, parent: ?*sdk.Object, desc: ?[*]const sdk.UnorderedAccessViewDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.uav_desc = desc.?[0];
        return view(object, parent, output);
    }
    fn createRtv(object: *sdk.Object, parent: ?*sdk.Object, desc: ?[*]const sdk.RenderTargetViewDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.rtv_desc = desc.?[0];
        return view(object, parent, output);
    }
    fn createDsv(object: *sdk.Object, parent: ?*sdk.Object, desc: ?[*]const sdk.DepthStencilViewDesc, output: *?*sdk.Object) callconv(sdk.call_conv) i32 {
        native(object).owner.dsv_desc = desc.?[0];
        return view(object, parent, output);
    }
    fn getResource(object: *sdk.Object, output: *?*sdk.Object) callconv(sdk.call_conv) void {
        output.* = native(object).parent;
        if (output.*) |resource| _ = addRef(resource);
    }
    fn blobPointer(object: *sdk.Object) callconv(sdk.call_conv) ?*anyopaque {
        return &native(object).data;
    }
    fn blobSize(object: *sdk.Object) callconv(sdk.call_conv) usize {
        return native(object).length;
    }

    fn record(self: *Mock, event: Event) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
    fn map(context: *sdk.Object, resource: ?*sdk.Object, _: u32, kind: u32, _: u32, output: ?[*]sdk.MappedSubresource) callconv(sdk.call_conv) i32 {
        const self = native(context).owner;
        self.map_count += 1;
        self.last_map = kind;
        output.?[0] = .{ .data = &native(resource.?).data };
        return 0;
    }
    fn unmap(context: *sdk.Object, _: ?*sdk.Object, _: u32) callconv(sdk.call_conv) void {
        native(context).owner.unmap_count += 1;
    }
    fn update(context: *sdk.Object, resource: ?*sdk.Object, subresource: u32, box: ?[*]const sdk.Box, data: ?*const anyopaque, _: u32, _: u32) callconv(sdk.call_conv) void {
        const self = native(context).owner;
        self.update_count += 1;
        self.last_subresource = subresource;
        const target = native(resource.?);
        const source: [*]const u8 = @ptrCast(data.?);
        const start = if (box) |value| value[0].left else 0;
        const count_bytes = if (box) |value| value[0].right - value[0].left else target.length;
        if (box) |value| self.last_box = value[0];
        @memcpy(target.data[start..][0..count_bytes], source[0..count_bytes]);
    }
    fn clear(context: *sdk.Object) callconv(sdk.call_conv) void {
        native(context).owner.clear_count += 1;
    }
    fn setViewports(context: *sdk.Object, count_views: u32, views: ?[*]const sdk.Viewport) callconv(sdk.call_conv) void {
        std.debug.assert(count_views == 1);
        native(context).owner.viewport = views.?[0];
    }
    fn setRects(context: *sdk.Object, count_rects: u32, rects: ?[*]const sdk.Rect) callconv(sdk.call_conv) void {
        std.debug.assert(count_rects == 1);
        native(context).owner.rect = rects.?[0];
    }
    fn csSrv(context: *sdk.Object, _: u32, _: u32, _: ?[*]const ?*sdk.Object) callconv(sdk.call_conv) void {
        native(context).owner.record(.cs_srv);
    }
    fn csUav(context: *sdk.Object, _: u32, _: u32, _: ?[*]const ?*sdk.Object, _: ?[*]const u32) callconv(sdk.call_conv) void {
        native(context).owner.record(.cs_uav);
    }
    fn csSampler(context: *sdk.Object, _: u32, _: u32, _: ?[*]const ?*sdk.Object) callconv(sdk.call_conv) void {
        native(context).owner.record(.cs_sampler);
    }
    fn draw(context: *sdk.Object, _: u32, _: u32) callconv(sdk.call_conv) void {
        native(context).owner.record(.draw);
    }
    fn drawIndexed(context: *sdk.Object, _: u32, _: u32, _: i32) callconv(sdk.call_conv) void {
        native(context).owner.record(.indexed);
    }
    fn drawInstanced(context: *sdk.Object, _: u32, _: u32, _: u32, _: u32) callconv(sdk.call_conv) void {
        native(context).owner.record(.instanced);
    }
    fn drawIndexedInstanced(context: *sdk.Object, _: u32, _: u32, _: u32, _: i32, _: u32) callconv(sdk.call_conv) void {
        native(context).owner.record(.indexed_instanced);
    }
    fn dispatchCommand(context: *sdk.Object, _: u32, _: u32, _: u32) callconv(sdk.call_conv) void {
        native(context).owner.record(.dispatch);
    }
};
