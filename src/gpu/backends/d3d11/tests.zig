const std = @import("std");
const sdk = @import("sdk.zig");
const c = @import("../dxgi/constants.zig");
const convert = @import("../dxgi/convert.zig");
const e = @import("../../enums.zig");
const t = @import("../../types.zig");
const Backend = @import("backend.zig").Backend;

test "D3D11 format conversions distinguish typeless storage, sampling and depth views" {
    try std.testing.expectEqual(c.format_r8g8b8a8_typeless, convert.textureFormat(.srgb8a8));
    try std.testing.expectEqual(c.format_r8g8b8a8_unorm_srgb, convert.srvFormat(.srgb8a8));
    try std.testing.expectEqual(c.format_r32g8x24_typeless, convert.textureFormat(.depth_stencil));
    try std.testing.expectEqual(c.format_r32_float_x8x24_typeless, convert.srvFormat(.depth_stencil));
    try std.testing.expectEqual(c.format_d32_float_s8x24_uint, convert.dsvFormat(.depth_stencil));
    try std.testing.expectEqual(c.format_unknown, convert.baseFormat(.astc_4x4_rgba));
    try std.testing.expectEqual(c.format_r10g10b10a2_unorm, convert.vertexFormat(.uint10_n2));
}

test "D3D11 filters and bind flags preserve native stage/resource capabilities" {
    try std.testing.expectEqual(@as(u32, 0x15), convert.filter(.linear, .linear, .linear, false, 1));
    try std.testing.expectEqual(@as(u32, 0xd5), convert.filter(.linear, .linear, .linear, true, 4));
    try std.testing.expectEqual(c.bind_shader_resource | c.bind_unordered_access, convert.bufferBindFlags(.{ .storage_buffer = true }));
    try std.testing.expectEqual(c.bind_shader_resource, convert.bufferBindFlags(.{ .storage_buffer = true, .write_transient = true }));
    try std.testing.expectEqual(c.bind_shader_resource | c.bind_render_target, convert.imageBindFlags(.{ .color_attachment = true }));
    try std.testing.expectEqual(@as(u8, 0), convert.colorMask(.none));
    try std.testing.expectEqual(@as(u32, 17), convert.subresource(2, 3, 5));
}

test "native D3D11 functions compile without a Sokol dependency" {
    @setEvalBranchQuota(100_000);
    inline for (.{ sdk, convert, Backend, @import("../dxgi/compiler.zig").Compiler }) |Namespace| {
        inline for (@typeInfo(Namespace).@"struct".decl_names) |name| {
            const declaration = @field(Namespace, name);
            if (@typeInfo(@TypeOf(declaration)) == .@"fn" and !@typeInfo(@TypeOf(declaration)).@"fn".is_generic) _ = &declaration;
        }
    }
}

const Mock = @import("mock.zig").Mock;
const r = @import("resources.zig");
const defaults = @import("../../defaults.zig");
fn backend(mock: *Mock, allocator: std.mem.Allocator) !Backend {
    return Backend.init(allocator, .{ .environment = .{ .d3d11 = .{ .device = mock.devicePointer(), .device_context = mock.contextPointer() } } }, null);
}

test "D3D11 capability queries honor feature levels and borrow the device/context" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    try std.testing.expectEqual(@as(i32, 32), native.limits.d3d11_max_unordered_access_views);
    try std.testing.expect(native.features.compute and native.features.origin_top_left and !native.features.copy_buffer_to_image_relaxed_buffer_type);
    try std.testing.expect(native.format_info[@backingInt(e.PixelFormat.depth_stencil)].depth);
    try std.testing.expect(!native.format_info[@backingInt(e.PixelFormat.astc_4x4_rgba)].sample);
    try std.testing.expectEqual(@as(u32, 1), Mock.native(mock.devicePointer()).refs);
    mock.level = c.feature_level_11_0;
    var level_11 = try backend(&mock, std.testing.allocator);
    defer level_11.deinit();
    try std.testing.expectEqual(@as(i32, 8), level_11.limits.d3d11_max_unordered_access_views);
}

test "D3D11 buffers distinguish staging storage, dynamic shader input and injected ownership" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    var buffer: r.Buffer = .{};
    try std.testing.expect(native.createBuffer(&buffer, .{ .size = 64, .usage = .{ .storage_buffer = true, .write_transient = true } }));
    try std.testing.expectEqual(c.usage_dynamic, mock.buffer_desc.usage);
    try std.testing.expectEqual(c.bind_shader_resource, mock.buffer_desc.bind_flags);
    try std.testing.expectEqual(c.cpu_access_write, mock.buffer_desc.cpu_access_flags);
    native.discardBuffer(&buffer);
    const used = mock.used;
    try std.testing.expect(native.createBuffer(&buffer, .{ .size = 64, .usage = .{ .staging_buffer = true } }));
    try std.testing.expectEqual(used, mock.used);
    try std.testing.expect(buffer.object == null and buffer.staging.?.len == 64);
    native.discardBuffer(&buffer);
    const injected = mock.allocate(.buffer);
    try std.testing.expect(native.createBuffer(&buffer, .{ .size = 64, .d3d11_buffer = injected }));
    try std.testing.expectEqual(@as(u32, 2), Mock.native(injected).refs);
    native.discardBuffer(&buffer);
    try std.testing.expectEqual(@as(u32, 1), Mock.native(injected).refs);
    sdk.release(injected);
    try std.testing.expectEqual(mock.used, mock.destroyed);
}

test "D3D11 image initialization orders slices then mip levels and balances aliases" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    const base: [32]u8 = @splat(7);
    const mip: [8]u8 = @splat(8);
    var desc: t.ImageDesc = .{ .type = .array, .width = 2, .height = 2, .num_slices = 2, .num_mipmaps = 2, .sample_count = 1, .pixel_format = .srgb8a8 };
    desc.data.mip_levels[0] = t.Range.fromSlice(u8, &base);
    desc.data.mip_levels[1] = t.Range.fromSlice(u8, &mip);
    var image: r.Image = .{};
    try std.testing.expect(native.createImage(&image, desc));
    try std.testing.expectEqual(c.format_r8g8b8a8_typeless, mock.texture_desc.format);
    try std.testing.expectEqual(@as(usize, 4), mock.initial_count);
    try std.testing.expectEqual(@intFromPtr(&base), @intFromPtr(mock.initial[0].data.?));
    try std.testing.expectEqual(@intFromPtr(&mip), @intFromPtr(mock.initial[1].data.?));
    try std.testing.expectEqual(@intFromPtr(&base) + 16, @intFromPtr(mock.initial[2].data.?));
    try std.testing.expectEqual(@intFromPtr(&mip) + 4, @intFromPtr(mock.initial[3].data.?));
    try std.testing.expectEqual(@as(u32, 2), Mock.native(image.resource.?).refs);
    native.discardImage(&image);
    try std.testing.expectEqual(mock.used, mock.destroyed);
    const injected = mock.allocate(.image);
    desc.d3d11_texture = injected;
    try std.testing.expect(native.createImage(&image, desc));
    try std.testing.expectEqual(@as(u32, 3), Mock.native(injected).refs);
    native.discardImage(&image);
    try std.testing.expectEqual(@as(u32, 1), Mock.native(injected).refs);
    sdk.release(injected);
}

test "D3D11 shaders own bytecode, map uniform registers and clean partial pipeline failure" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    const bytes = [_]u8{ 1, 2, 3, 4 };
    var desc: t.ShaderDesc = .{ .vertex_func = .{ .bytecode = t.Range.fromSlice(u8, &bytes) }, .fragment_func = .{ .bytecode = t.Range.fromSlice(u8, &bytes) } };
    desc.attrs[0] = .{ .hlsl_sem_name = "POSITION", .hlsl_sem_index = 2 };
    desc.uniform_blocks[0] = .{ .stage = .fragment, .size = 20, .hlsl_register_b_n = 3 };
    var shader: r.Shader = .{};
    try std.testing.expect(native.createShader(&shader, desc));
    try std.testing.expectEqual(@as(u32, 32), mock.buffer_desc.byte_width);
    try std.testing.expectEqual(shader.uniform_buffers[0], shader.fragment_uniforms[3]);
    try std.testing.expectEqualSlices(u8, &bytes, shader.vertex_bytecode.?);
    try std.testing.expect(@intFromPtr(&bytes) != @intFromPtr(shader.vertex_bytecode.?.ptr));
    var pipeline: r.Pipeline = .{};
    var pipeline_desc: t.PipelineDesc = .{};
    pipeline_desc.layout.attrs[0] = .{ .format = .float3 };
    pipeline_desc = defaults.pipeline(pipeline_desc, .{ .color_format = .rgba8, .depth_format = .none, .sample_count = 1 });
    mock.fail_at = mock.attempts + 2; // fail depth state after input layout and rasterizer
    try std.testing.expect(!native.createPipeline(&pipeline, &shader, pipeline_desc));
    native.discardPipeline(&pipeline);
    native.discardShader(&shader);
    try std.testing.expectEqual(mock.used, mock.destroyed);
}

test "D3D11 raw storage views keep their buffer alive and omit dynamic UAVs" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    var buffer: r.Buffer = .{};
    const desc: t.BufferDesc = .{ .size = 1024, .usage = .{ .storage_buffer = true } };
    try std.testing.expect(native.createBuffer(&buffer, desc));
    var view: r.View = .{};
    const view_desc: t.ViewDesc = .{ .storage_buffer = .{ .buffer = .{ .id = 1 }, .offset = 256 } };
    try std.testing.expect(native.createView(&view, view_desc, &buffer, desc, null, .{}));
    try std.testing.expectEqual(@as(u32, 64), mock.srv_desc.data.buffer_ex.first_element);
    try std.testing.expectEqual(@as(u32, 192), mock.uav_desc.data.buffer.num_elements);
    const object = buffer.object.?;
    native.discardBuffer(&buffer);
    try std.testing.expectEqual(@as(u32, 2), Mock.native(object).refs);
    native.discardView(&view);
    try std.testing.expectEqual(@as(u32, 0), Mock.native(object).refs);
    var dynamic = desc;
    dynamic.usage.write_transient = true;
    try std.testing.expect(native.createBuffer(&buffer, dynamic));
    try std.testing.expect(native.createView(&view, view_desc, &buffer, dynamic, null, .{}));
    try std.testing.expect(view.srv != null and view.uav == null);
    native.discardView(&view);
    native.discardBuffer(&buffer);
    try std.testing.expectEqual(mock.used, mock.destroyed);
}

test "D3D11 transient buffer writes discard once then preserve earlier writes" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    var buffer: r.Buffer = .{};
    try std.testing.expect(native.createBuffer(&buffer, .{ .size = 32, .usage = .{ .vertex_buffer = true, .write_transient = true } }));
    defer native.discardBuffer(&buffer);
    const data = [_]u8{ 1, 2, 3, 4 };
    var write: t.WriteBufferDesc = .{ .src = .{ .data = t.Range.fromSlice(u8, &data) }, .dst = .{ .offset = 4 }, .size = 4 };
    native.writeBuffer(&buffer, write, true, true);
    try std.testing.expectEqual(c.map_write_discard, mock.last_map);
    write.dst.offset = 8;
    native.writeBuffer(&buffer, write, true, false);
    try std.testing.expectEqual(c.map_write_no_overwrite, mock.last_map);
    try std.testing.expectEqualSlices(u8, &data, Mock.native(buffer.object.?).data[4..8]);
    try std.testing.expectEqualSlices(u8, &data, Mock.native(buffer.object.?).data[8..12]);
    try std.testing.expectEqual(@as(usize, 2), mock.unmap_count);
    try std.testing.expectEqual(@as(u32, 2), native.stats.num_map);
}

test "D3D11 uniform upload pads the rounded constant buffer without overreading the range" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    const code = [_]u8{1};
    var desc: t.ShaderDesc = .{ .compute_func = .{ .bytecode = t.Range.fromSlice(u8, &code) } };
    desc.uniform_blocks[0] = .{ .stage = .compute, .size = 20 };
    var shader: r.Shader = .{};
    try std.testing.expect(native.createShader(&shader, desc));
    defer native.discardShader(&shader);
    const values: [20]u8 = @splat(7);
    native.applyUniforms(&shader, 0, t.Range.fromSlice(u8, &values));
    const buffer = Mock.native(shader.uniform_buffers[0].?);
    try std.testing.expectEqualSlices(u8, &values, buffer.data[0..20]);
    try std.testing.expectEqualSlices(u8, &@as([12]u8, @splat(0)), buffer.data[20..32]);
    try std.testing.expectEqual(@as(u32, 1), native.stats.uniforms.num_update_subresource);
}

test "D3D11 compute bindings unbind shader resources before assigning writable views" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    var shader: r.Shader = .{};
    const shader_desc: t.ShaderDesc = .{};
    var pipeline: r.Pipeline = .{};
    const pipeline_desc: t.PipelineDesc = .{ .compute = true };
    const bindings: r.Bindings = .{ .pipeline = .{ .resource = &pipeline, .desc = &pipeline_desc, .slot = .{} }, .shader = .{ .resource = &shader, .desc = &shader_desc } };
    try std.testing.expect(native.applyBindings(&bindings));
    try std.testing.expectEqualSlices(Mock.Event, &.{ .cs_srv, .cs_uav, .cs_srv, .cs_sampler }, mock.events[0..mock.event_count]);
    native.dispatch(4, 1, 1);
    native.endPass(.{ .compute = true }, &.{});
    try std.testing.expectEqual(@as(usize, 1), mock.clear_count);
}

test "D3D11 draw variants and top-left coordinate transforms reach the expected commands" {
    var mock: Mock = undefined;
    mock.init();
    var native = try backend(&mock, std.testing.allocator);
    defer native.deinit();
    native.draw(false, false, 0, 3, 1, 0, 0);
    native.draw(true, false, 0, 3, 1, -2, 0);
    native.draw(false, true, 0, 3, 1, 0, 4);
    native.draw(true, true, 0, 3, 1, 1, 4);
    try std.testing.expectEqualSlices(Mock.Event, &.{ .draw, .indexed, .instanced, .indexed_instanced }, mock.events[0..mock.event_count]);
    native.viewport(100, 4, 10, 20, 30, false);
    try std.testing.expectEqual(@as(f32, 60), mock.viewport.top_left_y);
    native.scissor(100, 4, 10, 20, 30, false);
    try std.testing.expectEqual(@as(i32, 60), mock.rect.top);
    try std.testing.expectEqual(@as(i32, 90), mock.rect.bottom);
}

test "D3D11 validation separates stage register files and rejects shared SRV collisions" {
    // validation is compiled out without the debug option, like SOKOL_DEBUG
    if (!@import("../../config.zig").debug) return error.SkipZigTest;
    const validation = @import("../../validation.zig");
    const core = @import("../../core.zig");
    const gfx = @import("../../internal.zig");
    try gfx.setup(std.testing.allocator, .dummy, .{});
    defer gfx.shutdown();
    // validation rules depend on the active backend
    core.state().backend = .d3d11;
    defer core.state().backend = .dummy;
    var desc: t.ShaderDesc = .{ .vertex_func = .{ .source = "vs" }, .fragment_func = .{ .source = "ps" } };
    desc.uniform_blocks[0] = .{ .stage = .vertex, .size = 16 };
    desc.uniform_blocks[1] = .{ .stage = .fragment, .size = 16 };
    try std.testing.expect(validation.shaderDesc(&desc));
    desc.uniform_blocks[1].stage = .vertex;
    try std.testing.expect(!validation.shaderDesc(&desc));
    desc.uniform_blocks[1].stage = .fragment;
    desc.views[0].texture.stage = .vertex;
    desc.views[1].storage_buffer = .{ .stage = .vertex, .readonly = true };
    try std.testing.expect(!validation.shaderDesc(&desc));
    desc.views[1].storage_buffer.hlsl_register_t_n = 1;
    desc.views[0].texture.stage = .none;
    try std.testing.expect(validation.shaderDesc(&desc));
}

test "public D3D11 pipeline validation uses owned shader semantic names" {
    const gfx = @import("../../internal.zig");
    var mock: Mock = undefined;
    mock.init();
    try gfx.setup(std.testing.allocator, .d3d11, .{ .environment = .{ .d3d11 = .{ .device = mock.devicePointer(), .device_context = mock.contextPointer() } } });
    defer gfx.shutdown();
    const bytes = [_]u8{ 1, 2, 3, 4 };
    var name: [8:0]u8 = "POSITION".*;
    var desc: t.ShaderDesc = .{ .vertex_func = .{ .bytecode = t.Range.fromSlice(u8, &bytes) }, .fragment_func = .{ .bytecode = t.Range.fromSlice(u8, &bytes) } };
    desc.attrs[0].hlsl_sem_name = &name;
    const shader = gfx.makeShader(desc);
    try std.testing.expectEqual(e.ResourceState.valid, gfx.queryShaderState(shader));
    @memset(&name, 0);
    var pipeline_desc: t.PipelineDesc = .{ .shader = shader };
    pipeline_desc.layout.attrs[0].format = .float2;
    const pipeline = gfx.makePipeline(pipeline_desc);
    try std.testing.expectEqual(e.ResourceState.valid, gfx.queryPipelineState(pipeline));
    try std.testing.expectEqualStrings("POSITION", std.mem.sliceTo(&mock.semantic, 0));
}
