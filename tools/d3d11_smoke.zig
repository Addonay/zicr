//! Native Windows D3D11 smoke test; all rendering goes through sokol_gfx.
const std = @import("std");
const gfx = @import("zicr").gpu.raw;
const sdk = gfx.native.d3d11;
const Library = gfx.native.WindowsLibrary;

fn logger(_: ?[*:0]const u8, level: u32, item: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    std.debug.print("D3D11 log {d}/{d}: {s}\n", .{ level, item, if (message) |text| std.mem.span(text) else "" });
}
pub fn main() !void {
    const library = try Library.open("d3d11.dll");
    defer library.close();
    const CreateDevice = *const fn (?*anyopaque, u32, ?*anyopaque, u32, ?[*]const u32, u32, u32, *?*sdk.Object, *u32, *?*sdk.Object) callconv(sdk.call_conv) i32;
    const create = library.lookup(CreateDevice, "D3D11CreateDevice") orelse return error.MissingDeviceEntry;
    var device: ?*sdk.Object = null;
    var context: ?*sdk.Object = null;
    var level: u32 = 0;
    const levels = [_]u32{ 0xb100, 0xb000 };
    var status = create(null, 1, null, 0x20, &levels, levels.len, 7, &device, &level, &context);
    if (status < 0) status = create(null, 5, null, 0x20, &levels, levels.len, 7, &device, &level, &context);
    if (status < 0 or device == null or context == null) {
        std.debug.print("D3D11CreateDevice failed: 0x{x}\n", .{@as(u32, @bitCast(status))});
        return error.DeviceCreationFailed;
    }
    defer sdk.release(context);
    defer sdk.release(device);
    std.debug.print("D3D11 feature level 0x{x}\n", .{level});
    try gfx.setup(std.heap.page_allocator, .d3d11, .{
        .environment = .{ .d3d11 = .{ .device = device, .device_context = context }, .defaults = .{ .color_format = .rgba8, .depth_format = .none } },
        .logger = .{ .func = logger },
    });
    defer gfx.shutdown();
    const image = gfx.makeImage(.{ .width = 64, .height = 64, .usage = .{ .color_attachment = true } });
    const view = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    if (gfx.queryImageState(image) != .valid or gfx.queryViewState(view) != .valid) return error.AttachmentFailed;
    const vertex = "float4 main(uint id:SV_VertexID):SV_Position { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[id],0,1); }";
    const fragment = "cbuffer Params:register(b0) {float4 color;} float4 main():SV_Target0 {return color;}";
    var shader_desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    shader_desc.uniform_blocks[0] = .{ .stage = .fragment, .size = 16 };
    const shader = gfx.makeShader(shader_desc);
    if (gfx.queryShaderState(shader) != .valid) return error.ShaderFailed;
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none } });
    if (gfx.queryPipelineState(pipeline) != .valid) return error.PipelineFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = view;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    const color = [_]f32{ 0.25, 0.5, 0.75, 1 };
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &color));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    var staging: ?*sdk.Object = null;
    const staging_desc: sdk.Texture2DDesc = .{ .width = 64, .height = 64, .mip_levels = 1, .array_size = 1, .format = 28, .sample_desc = .{ .count = 1 }, .usage = 3, .cpu_access_flags = 0x20000 };
    if (sdk.createTexture2D(device.?, @ptrCast(&staging_desc), null, &staging) < 0 or staging == null) return error.StagingTextureFailed;
    defer sdk.release(staging);
    const source = sdk.fromOpaque(gfx.d3d11QueryImageInfo(image).res.?);
    sdk.copySubresourceRegion(context.?, staging, 0, 0, 0, 0, source, 0, null);
    var mapped: sdk.MappedSubresource = .{};
    if (sdk.map(context.?, staging, 0, 1, 0, @ptrCast(&mapped)) < 0 or mapped.data == null) return error.ReadbackMapFailed;
    const bytes: [*]const u8 = @ptrCast(mapped.data.?);
    const offset = @as(usize, mapped.row_pitch) * 32 + 32 * 4;
    const pixel: [4]u8 = bytes[offset..][0..4].*;
    sdk.unmap(context.?, staging, 0);
    const expected = [_]i32{ 64, 128, 191, 255 };
    for (pixel, expected) |value, want| {
        if (@abs(@as(i32, value) - want) > 1) {
            std.debug.print("D3D11 pixel mismatch: {any}\n", .{pixel});
            return error.PixelMismatch;
        }
    }
    gfx.commit();
    const stats = gfx.queryStats();
    if (stats.prev_frame.num_draw != 1 or stats.prev_frame.d3d11.draw.num_draw != 1 or stats.prev_frame.d3d11.uniforms.num_update_subresource != 1) return error.FrameStatsMismatch;
    std.debug.print("D3D11 native triangle readback {any} passed\n", .{pixel});
    try indexed(device.?, context.?, image, view);
    try textureCopy(device.?, context.?, image, view, vertex);
    try multisample(device.?, context.?, shader);
    try compute(device.?, context.?);
    try readback(shader, pipeline);
}

fn checkImage(device: *sdk.Object, context: *sdk.Object, image: gfx.Image, expected: [4]i32) !void {
    var staging: ?*sdk.Object = null;
    const desc: sdk.Texture2DDesc = .{ .width = 64, .height = 64, .mip_levels = 1, .array_size = 1, .format = 28, .sample_desc = .{ .count = 1 }, .usage = 3, .cpu_access_flags = 0x20000 };
    if (sdk.createTexture2D(device, @ptrCast(&desc), null, &staging) < 0 or staging == null) return error.ReadbackTextureFailed;
    defer sdk.release(staging);
    sdk.copySubresourceRegion(context, staging, 0, 0, 0, 0, sdk.fromOpaque(gfx.d3d11QueryImageInfo(image).res.?), 0, null);
    var mapped: sdk.MappedSubresource = .{};
    if (sdk.map(context, staging, 0, 1, 0, @ptrCast(&mapped)) < 0 or mapped.data == null) return error.ReadbackMapFailed;
    const data: [*]const u8 = @ptrCast(mapped.data.?);
    const offset = @as(usize, mapped.row_pitch) * 32 + 32 * 4;
    const pixel = data[offset..][0..4].*;
    sdk.unmap(context, staging, 0);
    for (pixel, expected) |value, want| if (@abs(@as(i32, value) - want) > 1) {
        std.debug.print("D3D11 readback mismatch: {any}, expected {any}\n", .{ pixel, expected });
        return error.PixelMismatch;
    };
}

fn indexed(device: *sdk.Object, context: *sdk.Object, image: gfx.Image, target: gfx.View) !void {
    const positions = [_][2]f32{ .{ 0, 0 }, .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const indices = [_]u16{ 0, 1, 2 };
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice([2]f32, &positions) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &indices) });
    const vertex = "float4 main(float2 position:POSITION):SV_Position {return float4(position,0,1);}";
    const fragment = "float4 main():SV_Target0 {return float4(1,0,0,1);}";
    var shader_desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    shader_desc.attrs[0].hlsl_sem_name = "POSITION";
    const shader = gfx.makeShader(shader_desc);
    var desc: gfx.PipelineDesc = .{ .shader = shader, .index_type = .uint16, .depth = .{ .pixel_format = .none } };
    desc.layout.attrs[0].format = .float2;
    const pipeline = gfx.makePipeline(desc);
    if (gfx.queryBufferState(vb) != .valid or gfx.queryBufferState(ib) != .valid or gfx.queryPipelineState(pipeline) != .valid) return error.IndexedSetupFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = target;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{ .index_buffer = ib };
    bindings.vertex_buffers[0] = vb;
    bindings.vertex_buffer_offsets[0] = 8;
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 2);
    gfx.endPass();
    try checkImage(device, context, image, .{ 255, 0, 0, 255 });
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    bindings.vertex_buffer_offsets[0] = 0;
    gfx.applyBindings(bindings);
    gfx.drawEx(0, 3, 2, 1, 0);
    gfx.endPass();
    try checkImage(device, context, image, .{ 255, 0, 0, 255 });
    gfx.commit();
    std.debug.print("  indexed, instanced and base-vertex rendering passed\n", .{});
}

fn textureCopy(device: *sdk.Object, context: *sdk.Object, output: gfx.Image, target: gfx.View, vertex: [*:0]const u8) !void {
    const pixels: [16][4]u8 = @splat(.{ 23, 47, 89, 255 });
    const staging = gfx.makeBuffer(.{ .size = @sizeOf(@TypeOf(pixels)), .usage = .{ .staging_buffer = true, .copy_src = true, .write_transient = true } });
    gfx.writeBufferTransient(.{ .src = .{ .data = gfx.Range.fromSlice([4]u8, &pixels) }, .dst = .{ .buffer = staging } });
    const image = gfx.makeImage(.{ .width = 4, .height = 4, .usage = .{ .copy_dst = true } });
    gfx.copyBufferToImage(.{ .src = .{ .buffer = staging }, .dst = .{ .image = image } });
    const view = gfx.makeView(.{ .texture = .{ .image = image } });
    const sampler = gfx.makeSampler(.{});
    const fragment = "Texture2D<float4> source_texture:register(t0); SamplerState source_sampler:register(s0); float4 main():SV_Target0 {return source_texture.Sample(source_sampler,float2(0.5,0.5));}";
    var desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    desc.views[0].texture.stage = .fragment;
    desc.samplers[0].stage = .fragment;
    desc.texture_sampler_pairs[0].stage = .fragment;
    const shader = gfx.makeShader(desc);
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none } });
    if (gfx.queryViewState(view) != .valid or gfx.querySamplerState(sampler) != .valid or gfx.queryPipelineState(pipeline) != .valid) return error.TextureSetupFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = target;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = view;
    bindings.samplers[0] = sampler;
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try checkImage(device, context, output, .{ 23, 47, 89, 255 });
    gfx.commit();
    std.debug.print("  staging upload, buffer-to-image copy and sampler rendering passed\n", .{});
}

fn multisample(device: *sdk.Object, context: *sdk.Object, shader: gfx.Shader) !void {
    const image = gfx.makeImage(.{ .width = 64, .height = 64, .sample_count = 4, .usage = .{ .color_attachment = true } });
    const resolved = gfx.makeImage(.{ .width = 64, .height = 64, .usage = .{ .resolve_attachment = true } });
    const color = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    const resolve = gfx.makeView(.{ .resolve_attachment = .{ .image = resolved } });
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none }, .sample_count = 4 });
    if (gfx.queryViewState(color) != .valid or gfx.queryViewState(resolve) != .valid or gfx.queryPipelineState(pipeline) != .valid) return error.MsaaSetupFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = color;
    pass.attachments.resolves[0] = resolve;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    const uniform = [_]f32{ 0.25, 0.5, 0.75, 1 };
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &uniform));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try checkImage(device, context, resolved, .{ 64, 128, 191, 255 });
    gfx.commit();
    if (gfx.queryStats().prev_frame.d3d11.pass.num_resolve_subresource != 1) return error.ResolveStatsMismatch;
    std.debug.print("  multisample rendering and resolve readback passed\n", .{});
}

fn compute(device: *sdk.Object, context: *sdk.Object) !void {
    const source = gfx.makeBuffer(.{ .size = 16, .usage = .{ .storage_buffer = true, .copy_src = true } });
    const copy = gfx.makeBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } });
    const view = gfx.makeView(.{ .storage_buffer = .{ .buffer = source } });
    var desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = "RWByteAddressBuffer output_buffer:register(u0); [numthreads(1,1,1)] void main(uint3 id:SV_DispatchThreadID) {output_buffer.Store(id.x*4,100+3*id.x);}" } };
    desc.views[0].storage_buffer.stage = .compute;
    const shader = gfx.makeShader(desc);
    const pipeline = gfx.makePipeline(.{ .shader = shader, .compute = true });
    if (gfx.queryViewState(view) != .valid or gfx.queryPipelineState(pipeline) != .valid) return error.ComputeSetupFailed;
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = view;
    gfx.applyBindings(bindings);
    gfx.dispatch(4, 1, 1);
    gfx.endPass();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = source }, .dst = .{ .buffer = copy }, .size = 16 });
    var staging: ?*sdk.Object = null;
    const staging_desc: sdk.BufferDesc = .{ .byte_width = 16, .usage = 3, .cpu_access_flags = 0x20000 };
    if (sdk.createBuffer(device, @ptrCast(&staging_desc), null, &staging) < 0 or staging == null) return error.ComputeReadbackBufferFailed;
    defer sdk.release(staging);
    sdk.copySubresourceRegion(context, staging, 0, 0, 0, 0, sdk.fromOpaque(gfx.d3d11QueryBufferInfo(copy).buf.?), 0, null);
    var mapped: sdk.MappedSubresource = .{};
    if (sdk.map(context, staging, 0, 1, 0, @ptrCast(&mapped)) < 0 or mapped.data == null) return error.ComputeReadbackMapFailed;
    var values: [4]u32 = undefined;
    const bytes: [*]const u8 = @ptrCast(mapped.data.?);
    @memcpy(std.mem.asBytes(&values), bytes[0..16]);
    sdk.unmap(context, staging, 0);
    if (!std.mem.eql(u32, &values, &.{ 100, 103, 106, 109 })) {
        std.debug.print("compute mismatch {any}\n", .{values});
        return error.ComputeMismatch;
    }
    gfx.commit();
    std.debug.print("  compute storage buffer and GPU copy readback {any} passed\n", .{values});
}

/// Verifies the readback extension: rendered images, sub-regions with padded
/// rows, mip levels of array layers, immutable and transient buffers.
fn readback(shader: gfx.Shader, pipeline: gfx.Pipeline) !void {
    _ = shader;
    const image = gfx.makeImage(.{ .width = 16, .height = 8, .usage = .{ .color_attachment = true, .copy_src = true } });
    const view = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = view;
    pass.action.colors[0] = .{ .load_action = .clear, .clear_value = .{ .r = 1, .g = 0, .b = 0, .a = 1 } };
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    gfx.applyScissorRect(8, 0, 8, 8, true);
    const color = [_]f32{ 0, 1, 0, 1 };
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &color));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.commit();
    var pixels: [16 * 8 * 4]u8 = undefined;
    if (!gfx.readImage(.{ .image = image }, &pixels)) return error.ReadImageFailed;
    for (0..8) |y| for (0..16) |x| {
        const p = pixels[(y * 16 + x) * 4 ..][0..4];
        const want: [4]u8 = if (x < 8) .{ 255, 0, 0, 255 } else .{ 0, 255, 0, 255 };
        if (!std.mem.eql(u8, p, &want)) {
            std.debug.print("readback pixel ({d},{d}) = {any}, expected {any}\n", .{ x, y, p, want });
            return error.ReadImageMismatch;
        }
    };
    var region: [32 * 2]u8 = @splat(0xAA);
    if (!gfx.readImage(.{ .image = image, .x = 6, .y = 3, .width = 4, .height = 2, .bytes_per_row = 32 }, &region)) return error.ReadRegionFailed;
    for (0..2) |row| {
        const line = region[row * 32 ..][0..32];
        if (!std.mem.eql(u8, line[0..16], &[_]u8{ 255, 0, 0, 255, 255, 0, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255 })) return error.ReadRegionMismatch;
        for (line[16..]) |b| if (b != 0xAA) return error.ReadRegionPaddingOverwritten;
    }

    var mip0: [4 * 4 * 4 * 2]u8 = undefined;
    for (&mip0, 0..) |*b, i| b.* = @truncate(i);
    var mip1: [2 * 2 * 4 * 2]u8 = undefined;
    for (&mip1, 0..) |*b, i| b.* = @truncate(200 + i);
    var array_desc: gfx.ImageDesc = .{ .type = .array, .width = 4, .height = 4, .num_slices = 2, .num_mipmaps = 2, .usage = .{ .copy_src = true } };
    array_desc.data.mip_levels[0] = gfx.Range.fromSlice(u8, &mip0);
    array_desc.data.mip_levels[1] = gfx.Range.fromSlice(u8, &mip1);
    const array = gfx.makeImage(array_desc);
    var layer: [2 * 2 * 4]u8 = undefined;
    if (!gfx.readImage(.{ .image = array, .mip_level = 1, .slice = 1, .num_slices = 1 }, &layer)) return error.ReadMipFailed;
    if (!std.mem.eql(u8, &layer, mip1[16..32])) return error.ReadMipMismatch;

    const data = [_]u32{ 10, 20, 30, 40 };
    const immutable = gfx.makeBuffer(.{ .usage = .{ .copy_src = true }, .data = gfx.Range.fromSlice(u32, &data) });
    var two: [2]u32 = undefined;
    if (!gfx.readBuffer(immutable, 4, std.mem.asBytes(&two)) or !std.mem.eql(u32, &two, &.{ 20, 30 })) return error.ReadBufferMismatch;
    const transient = gfx.makeBuffer(.{ .size = 16, .usage = .{ .copy_src = true, .write_transient = true } });
    for (0..2) |frame| {
        const values = [_]u32{ 1 + @as(u32, @intCast(frame)), 2, 3, 4 };
        gfx.writeBufferTransient(.{ .src = .{ .data = gfx.Range.fromSlice(u32, &values) }, .dst = .{ .buffer = transient } });
        gfx.commit();
        var first: u32 = 0;
        if (!gfx.readBuffer(transient, 0, std.mem.asBytes(&first)) or first != values[0]) return error.ReadTransientMismatch;
    }
    std.debug.print("  readback of rendered images, padded regions, array mips and buffers passed\n", .{});
}
