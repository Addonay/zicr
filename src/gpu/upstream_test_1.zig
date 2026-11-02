//! Tests ported from upstream sokol tests/functional/sokol_gfx_test.c (part 1).
//! Covers sokol_gfx_test.c lines 85-1476: init/shutdown, pool sizes, pool
//! exhaustion, make/destroy, defaults and query functions, resource states,
//! uninit counts and buffer-to-buffer copy validation.
const std = @import("std");
const common = @import("upstream_test_common.zig");
const pool = @import("pool.zig");
const gfx = common.gfx;
const core = common.core;
const expect = std.testing.expect;

/// SG_INVALID_ID (the sokol id type is u32, gfx.invalid_id is usize).
const invalid_id: u32 = 0;

// _SG_DEFAULT_*_POOL_SIZE and _SG_DEFAULT_UB_SIZE, see defaults.zig.
const default_image_pool_size: i32 = 128;
const default_pipeline_pool_size: i32 = 64;
const default_ub_size: i32 = 4 * 1024 * 1024;

fn createStagingBuffer(size: usize) gfx.Buffer {
    return gfx.makeBuffer(.{
        .size = size,
        .usage = .{ .staging_buffer = true, .write_transient = true, .copy_src = true },
    });
}

fn createCopyDstBuffer(size: usize) gfx.Buffer {
    return gfx.makeBuffer(.{
        .size = size,
        .usage = .{ .vertex_buffer = true, .copy_dst = true },
    });
}

test "init_shutdown" {
    common.setup(.{});
    try expect(gfx.isValid());
    gfx.shutdown();
    try expect(!gfx.isValid());
}

test "query_desc" {
    common.setup(.{
        .buffer_pool_size = 1024,
        .sampler_pool_size = 8,
        .shader_pool_size = 128,
        .view_pool_size = 64,
    });
    defer gfx.shutdown();
    const desc = gfx.queryDesc();
    try expect(desc.buffer_pool_size == 1024);
    try expect(desc.image_pool_size == default_image_pool_size);
    try expect(desc.sampler_pool_size == 8);
    try expect(desc.shader_pool_size == 128);
    try expect(desc.pipeline_pool_size == default_pipeline_pool_size);
    try expect(desc.view_pool_size == 64);
    try expect(desc.uniform_buffer_size == default_ub_size);
}

test "query_backend" {
    common.setup(.{});
    defer gfx.shutdown();
    try expect(gfx.queryBackend() == .dummy);
}

test "pool_size" {
    common.setup(.{
        .buffer_pool_size = 1024,
        .image_pool_size = 2048,
        .shader_pool_size = 128,
        .pipeline_pool_size = 256,
        .view_pool_size = 64,
    });
    defer gfx.shutdown();
    try expect(gfx.isValid());
    // pool slot 0 is reserved (this is the "invalid slot")
    const pools = &core.state().pools;
    try expect(pools.buffers.items.len == 1025);
    try expect(pools.images.items.len == 2049);
    try expect(pools.shaders.items.len == 129);
    try expect(pools.pipelines.items.len == 257);
    try expect(pools.views.items.len == 65);
    try expect(pools.buffers.queue_top == 1024);
    try expect(pools.images.queue_top == 2048);
    try expect(pools.shaders.queue_top == 128);
    try expect(pools.pipelines.queue_top == 256);
    try expect(pools.views.queue_top == 64);
}

test "alloc_fail_destroy_buffers" {
    common.setup(.{ .buffer_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var buf = std.mem.zeroes([3]gfx.Buffer);
    for (0..3) |i| {
        buf[i] = gfx.allocBuffer();
        try expect(buf[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.buffers.queue_top);
        try expect(gfx.queryBufferState(buf[i]) == .alloc);
    }
    // the next alloc will fail because the pool is exhausted
    const b3 = gfx.allocBuffer();
    try expect(b3.id == invalid_id);
    try expect(gfx.queryBufferState(b3) == .invalid);

    // before destroying, the resources must be either in valid or failed state
    for (0..3) |i| {
        gfx.failBuffer(buf[i]);
        try expect(gfx.queryBufferState(buf[i]) == .failed);
    }
    for (0..3) |i| {
        gfx.destroyBuffer(buf[i]);
        try expect(gfx.queryBufferState(buf[i]) == .invalid);
        try expect((i + 1) == core.state().pools.buffers.queue_top);
    }
}

test "alloc_fail_destroy_images" {
    common.setup(.{ .image_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var img = std.mem.zeroes([3]gfx.Image);
    for (0..3) |i| {
        img[i] = gfx.allocImage();
        try expect(img[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.images.queue_top);
        try expect(gfx.queryImageState(img[i]) == .alloc);
    }
    // the next alloc will fail because the pool is exhausted
    const img3 = gfx.allocImage();
    try expect(img3.id == invalid_id);
    try expect(gfx.queryImageState(img3) == .invalid);

    // before destroying, the resources must be either in valid or failed state
    for (0..3) |i| {
        gfx.failImage(img[i]);
        try expect(gfx.queryImageState(img[i]) == .failed);
    }
    for (0..3) |i| {
        gfx.destroyImage(img[i]);
        try expect(gfx.queryImageState(img[i]) == .invalid);
        try expect((i + 1) == core.state().pools.images.queue_top);
    }
}

test "alloc_fail_destroy_samplers" {
    common.setup(.{ .sampler_pool_size = 3 });
    defer gfx.shutdown();

    var smp = std.mem.zeroes([3]gfx.Sampler);
    for (0..3) |i| {
        smp[i] = gfx.allocSampler();
        try expect(smp[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.samplers.queue_top);
        try expect(gfx.querySamplerState(smp[i]) == .alloc);
    }
    // the next alloc will fail because the pool is exhausted
    const s3 = gfx.allocSampler();
    try expect(s3.id == invalid_id);
    try expect(gfx.querySamplerState(s3) == .invalid);

    // before destroying, the resources must be either in valid or failed state
    for (0..3) |i| {
        gfx.failSampler(smp[i]);
        try expect(gfx.querySamplerState(smp[i]) == .failed);
    }
    for (0..3) |i| {
        gfx.destroySampler(smp[i]);
        try expect(gfx.querySamplerState(smp[i]) == .invalid);
        try expect((i + 1) == core.state().pools.samplers.queue_top);
    }
}

test "alloc_fail_destroy_shaders" {
    common.setup(.{ .shader_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var shd = std.mem.zeroes([3]gfx.Shader);
    for (0..3) |i| {
        shd[i] = gfx.allocShader();
        try expect(shd[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.shaders.queue_top);
        try expect(gfx.queryShaderState(shd[i]) == .alloc);
    }
    // the next alloc will fail because the pool is exhausted
    const s3 = gfx.allocShader();
    try expect(s3.id == invalid_id);
    try expect(gfx.queryShaderState(s3) == .invalid);

    // before destroying, the resources must be either in valid or failed state
    for (0..3) |i| {
        gfx.failShader(shd[i]);
        try expect(gfx.queryShaderState(shd[i]) == .failed);
    }
    for (0..3) |i| {
        gfx.destroyShader(shd[i]);
        try expect(gfx.queryShaderState(shd[i]) == .invalid);
        try expect((i + 1) == core.state().pools.shaders.queue_top);
    }
}

test "alloc_fail_destroy_pipelines" {
    common.setup(.{ .pipeline_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var pip = std.mem.zeroes([3]gfx.Pipeline);
    for (0..3) |i| {
        pip[i] = gfx.allocPipeline();
        try expect(pip[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.pipelines.queue_top);
        try expect(gfx.queryPipelineState(pip[i]) == .alloc);
    }

    // the next alloc will fail because the pool is exhausted
    const p3 = gfx.allocPipeline();
    try expect(p3.id == invalid_id);
    try expect(gfx.queryPipelineState(p3) == .invalid);

    // before destroying, the resources must be either in valid or failed state
    for (0..3) |i| {
        gfx.failPipeline(pip[i]);
        try expect(gfx.queryPipelineState(pip[i]) == .failed);
    }
    for (0..3) |i| {
        gfx.destroyPipeline(pip[i]);
        try expect(gfx.queryPipelineState(pip[i]) == .invalid);
        try expect((i + 1) == core.state().pools.pipelines.queue_top);
    }
}

test "alloc_fail_destroy_views" {
    common.setup(.{ .view_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var views = std.mem.zeroes([3]gfx.View);
    for (0..3) |i| {
        views[i] = gfx.allocView();
        try expect(views[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.views.queue_top);
        try expect(gfx.queryViewState(views[i]) == .alloc);
    }
    // the next alloc will fail because the pool is exhausted
    const v3 = gfx.allocView();
    try expect(v3.id == invalid_id);
    try expect(gfx.queryViewState(v3) == .invalid);

    // before destroying, the resources must be either in valid or failed state
    for (0..3) |i| {
        gfx.failView(views[i]);
        try expect(gfx.queryViewState(views[i]) == .failed);
    }
    for (0..3) |i| {
        gfx.destroyView(views[i]);
        try expect(gfx.queryViewState(views[i]) == .invalid);
        try expect((i + 1) == core.state().pools.views.queue_top);
    }
}

test "make_destroy_buffers" {
    common.setup(.{ .buffer_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };

    var buf = std.mem.zeroes([3]gfx.Buffer);
    const desc = gfx.BufferDesc{ .data = gfx.Range.fromSlice(f32, &data) };
    for (0..3) |i| {
        buf[i] = gfx.makeBuffer(desc);
        try expect(buf[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.buffers.queue_top);
        try expect(gfx.queryBufferState(buf[i]) == .valid);
        const bufptr = core.lookupBuffer(buf[i].id);
        try expect(bufptr != null);
        const bp = bufptr.?;
        try expect(bp.slot.id == buf[i].id);
        try expect(bp.slot.state == .valid);
        try expect(bp.cmn.size == @sizeOf(@TypeOf(data)));
        try expect(bp.cmn.usage.vertex_buffer);
        try expect(!bp.cmn.usage.write_transient);
        try expect(!bp.cmn.usage.copy_dst);
        try expect(bp.cmn.validate.bind_frame_index == 0);
        try expect(bp.cmn.validate.copy_src_frame_index == 0);
        try expect(bp.cmn.write_transient_frame_index == 0);
        try expect(bp.cmn.num_slots == 1);
        try expect(bp.cmn.active_slot == 0);
    }
    // trying to create another one fails because pool is exhausted
    try expect(gfx.makeBuffer(desc).id == invalid_id);

    for (0..3) |i| {
        gfx.destroyBuffer(buf[i]);
        try expect(gfx.queryBufferState(buf[i]) == .invalid);
        try expect((i + 1) == core.state().pools.buffers.queue_top);
    }
}

// The C test also checks `cmn.upd_frame_index`, a deprecated field that is only
// ever zero in the original (sokol_gfx.h:7114, 9076) and does not exist here.
test "make_destroy_images" {
    common.setup(.{ .image_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var data = std.mem.zeroes([64]u32);

    var img = std.mem.zeroes([3]gfx.Image);
    var desc = gfx.ImageDesc{
        .width = 8,
        .height = 8,
    };
    desc.data.mip_levels[0] = gfx.Range.fromSlice(u32, &data);
    for (0..3) |i| {
        img[i] = gfx.makeImage(desc);
        try expect(img[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.images.queue_top);
        try expect(gfx.queryImageState(img[i]) == .valid);
        const imgptr = core.lookupImage(img[i].id);
        try expect(imgptr != null);
        const ip = imgptr.?;
        try expect(ip.slot.id == img[i].id);
        try expect(ip.slot.state == .valid);
        try expect(ip.cmn.type == .@"2d");
        try expect(!ip.cmn.usage.color_attachment);
        try expect(ip.cmn.width == 8);
        try expect(ip.cmn.height == 8);
        try expect(ip.cmn.num_slices == 1);
        try expect(ip.cmn.num_mipmaps == 1);
        try expect(ip.cmn.usage.immutable);
        try expect(ip.cmn.pixel_format == .rgba8);
        try expect(ip.cmn.sample_count == 1);
        try expect(ip.cmn.validate.bind_frame_index == 0);
        try expect(ip.cmn.num_slots == 1);
        try expect(ip.cmn.active_slot == 0);
    }
    // trying to create another one fails because pool is exhausted
    try expect(gfx.makeImage(desc).id == invalid_id);

    for (0..3) |i| {
        gfx.destroyImage(img[i]);
        try expect(gfx.queryImageState(img[i]) == .invalid);
        try expect((i + 1) == core.state().pools.images.queue_top);
    }
}

test "make_destroy_samplers" {
    common.setup(.{ .sampler_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var smp = std.mem.zeroes([3]gfx.Sampler);
    const desc = gfx.SamplerDesc{};
    for (0..3) |i| {
        smp[i] = gfx.makeSampler(desc);
        try expect(smp[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.samplers.queue_top);
        try expect(gfx.querySamplerState(smp[i]) == .valid);
        const smpptr = core.lookupSampler(smp[i].id);
        try expect(smpptr != null);
        const sp = smpptr.?;
        try expect(sp.slot.id == smp[i].id);
        try expect(sp.slot.state == .valid);
        try expect(sp.cmn.min_filter == .nearest);
        try expect(sp.cmn.mag_filter == .nearest);
        try expect(sp.cmn.mipmap_filter == .nearest);
        try expect(sp.cmn.wrap_u == .repeat);
        try expect(sp.cmn.wrap_v == .repeat);
        try expect(sp.cmn.wrap_w == .repeat);
        try expect(sp.cmn.min_lod == 0.0);
        try expect(sp.cmn.max_lod == std.math.floatMax(f32));
        try expect(sp.cmn.border_color == .opaque_black);
        try expect(sp.cmn.compare == .never);
        try expect(sp.cmn.max_anisotropy == 1);
    }
    // trying to create another one fails because pool is exhausted
    try expect(gfx.makeSampler(desc).id == invalid_id);

    for (0..3) |i| {
        gfx.destroySampler(smp[i]);
        try expect(gfx.querySamplerState(smp[i]) == .invalid);
        try expect((i + 1) == core.state().pools.samplers.queue_top);
    }
}

test "make_destroy_shaders" {
    common.setup(.{ .shader_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var shd = std.mem.zeroes([3]gfx.Shader);
    var desc: gfx.ShaderDesc = .{};
    desc.uniform_blocks[0] = .{ .stage = .vertex, .size = 16 };
    for (0..3) |i| {
        shd[i] = gfx.makeShader(desc);
        try expect(shd[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.shaders.queue_top);
        try expect(gfx.queryShaderState(shd[i]) == .valid);
        const shdptr = core.lookupShader(shd[i].id);
        try expect(shdptr != null);
        const sp = shdptr.?;
        try expect(sp.slot.id == shd[i].id);
        try expect(sp.slot.state == .valid);
        try expect(sp.cmn.uniform_blocks[0].stage == .vertex);
        try expect(sp.cmn.uniform_blocks[0].size == 16);
    }
    // trying to create another one fails because pool is exhausted
    try expect(gfx.makeShader(desc).id == invalid_id);

    for (0..3) |i| {
        gfx.destroyShader(shd[i]);
        try expect(gfx.queryShaderState(shd[i]) == .invalid);
        try expect((i + 1) == core.state().pools.shaders.queue_top);
    }
}

test "make_destroy_pipelines" {
    common.setup(.{ .pipeline_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var pip = std.mem.zeroes([3]gfx.Pipeline);
    var desc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(.{}) };
    desc.layout.attrs[0].format = .float3;
    desc.layout.attrs[1].format = .float4;
    for (0..3) |i| {
        pip[i] = gfx.makePipeline(desc);
        try expect(pip[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.pipelines.queue_top);
        try expect(gfx.queryPipelineState(pip[i]) == .valid);
        const pipptr = core.lookupPipeline(pip[i].id);
        try expect(pipptr != null);
        const pp = pipptr.?;
        try expect(pp.slot.id == pip[i].id);
        try expect(pp.slot.state == .valid);
        try expect(pp.cmn.shader.sref.id == desc.shader.id);
        try expect(pp.cmn.color_count == 1);
        try expect(pp.cmn.colors[0].pixel_format == .rgba8);
        try expect(pp.cmn.depth.pixel_format == .depth_stencil);
        try expect(pp.cmn.sample_count == 1);
        try expect(pp.cmn.index_type == .none);
        try expect(pp.cmn.vertex_buffer_layout_active[0]);
        try expect(!pp.cmn.vertex_buffer_layout_active[1]);
    }
    // trying to create another one fails because pool is exhausted
    try expect(gfx.makePipeline(desc).id == invalid_id);

    for (0..3) |i| {
        gfx.destroyPipeline(pip[i]);
        try expect(gfx.queryPipelineState(pip[i]) == .invalid);
        try expect((i + 1) == core.state().pools.pipelines.queue_top);
    }
}

test "make_destroy_views" {
    common.setup(.{ .view_pool_size = 3 });
    defer gfx.shutdown();
    try expect(gfx.isValid());

    var views = std.mem.zeroes([3]gfx.View);

    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 128,
        .height = 128,
    });
    const view_desc = gfx.ViewDesc{ .color_attachment = .{ .image = img } };
    for (0..3) |i| {
        views[i] = gfx.makeView(view_desc);
        try expect(views[i].id != invalid_id);
        try expect((2 - i) == core.state().pools.views.queue_top);
        try expect(gfx.queryViewState(views[i]) == .valid);
        const viewptr = core.lookupView(views[i].id);
        try expect(viewptr != null);
        const vp = viewptr.?;
        try expect(vp.slot.id == views[i].id);
        try expect(vp.slot.state == .valid);
    }
    // trying to create another one fails because pool is exhausted
    try expect(gfx.makeView(view_desc).id == invalid_id);

    for (0..3) |i| {
        gfx.destroyView(views[i]);
        try expect(gfx.queryViewState(views[i]) == .invalid);
        try expect((i + 1) == core.state().pools.views.queue_top);
    }
}

test "generation_counter" {
    common.setup(.{ .buffer_pool_size = 1 });
    defer gfx.shutdown();

    const data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    for (0..64) |i| {
        const buf = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &data) });
        try expect(buf.id != invalid_id);
        try expect(gfx.queryBufferState(buf) == .valid);
        try expect((buf.id >> 16) == @as(u32, @intCast(i + 1))); // this is the generation counter
        try expect(pool.slotIndex(buf.id) == 1); // slot index should remain the same
        gfx.destroyBuffer(buf);
        try expect(gfx.queryBufferState(buf) == .invalid);
    }
}

test "query_buffer_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    var desc: gfx.BufferDesc = gfx.queryBufferDefaults(.{});
    try expect(desc.usage.vertex_buffer);
    try expect(!desc.usage.write_transient);
    try expect(!desc.usage.copy_dst);
    desc = gfx.queryBufferDefaults(.{ .usage = .{ .index_buffer = true } });
    try expect(desc.usage.index_buffer);
    try expect(!desc.usage.vertex_buffer);
    desc = gfx.queryBufferDefaults(.{ .usage = .{ .staging_buffer = true, .copy_src = true } });
    try expect(desc.usage.staging_buffer);
    try expect(desc.usage.copy_src);
    try expect(!desc.usage.vertex_buffer);
    desc = gfx.queryBufferDefaults(.{ .usage = .{ .write_transient = true } });
    try expect(desc.usage.vertex_buffer);
    try expect(desc.usage.write_transient);
}

test "query_image_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.queryImageDefaults(.{});
    try expect(desc.type == .@"2d");
    try expect(!desc.usage.color_attachment);
    try expect(!desc.usage.resolve_attachment);
    try expect(!desc.usage.depth_stencil_attachment);
    try expect(desc.usage.immutable);
    try expect(desc.num_mipmaps == 1);
    try expect(desc.pixel_format == .rgba8);
    try expect(desc.sample_count == 1);
}

test "query_sampler_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.querySamplerDefaults(.{});
    try expect(desc.min_filter == .nearest);
    try expect(desc.mag_filter == .nearest);
    try expect(desc.mipmap_filter == .nearest);
    try expect(desc.wrap_u == .repeat);
    try expect(desc.wrap_v == .repeat);
    try expect(desc.wrap_w == .repeat);
    try expect(desc.min_lod == 0.0);
    try expect(desc.max_lod == std.math.floatMax(f32));
    try expect(desc.border_color == .opaque_black);
    try expect(desc.compare == .never);
    try expect(desc.max_anisotropy == 1);
}

test "query_shader_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.queryShaderDefaults(.{});
    try expect(desc.vertex_func.entry != null and std.mem.eql(u8, std.mem.span(desc.vertex_func.entry.?), "main"));
    try expect(desc.fragment_func.entry != null and std.mem.eql(u8, std.mem.span(desc.fragment_func.entry.?), "main"));
}

test "query_pipeline_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    var pdesc: gfx.PipelineDesc = .{};
    pdesc.layout.attrs[0].format = .float3;
    pdesc.layout.attrs[1].format = .float4;
    const desc = gfx.queryPipelineDefaults(pdesc);
    try expect(desc.layout.buffers[0].stride == 28);
    try expect(desc.layout.buffers[0].step_rate == 1);
    try expect(desc.layout.buffers[0].step_func == .per_vertex);
    try expect(desc.layout.attrs[0].offset == 0);
    try expect(desc.layout.attrs[0].buffer_index == 0);
    try expect(desc.layout.attrs[0].format == .float3);
    try expect(desc.layout.attrs[1].offset == 12);
    try expect(desc.layout.attrs[1].buffer_index == 0);
    try expect(desc.layout.attrs[1].format == .float4);
    try expect(desc.stencil.front.fail_op == .keep);
    try expect(desc.stencil.front.depth_fail_op == .keep);
    try expect(desc.stencil.front.pass_op == .keep);
    try expect(desc.stencil.front.compare == .always);
    try expect(desc.stencil.back.fail_op == .keep);
    try expect(desc.stencil.back.depth_fail_op == .keep);
    try expect(desc.stencil.back.pass_op == .keep);
    try expect(desc.stencil.back.compare == .always);
    try expect(desc.stencil.enabled == false);
    try expect(desc.stencil.read_mask == 0);
    try expect(desc.stencil.write_mask == 0);
    try expect(desc.stencil.ref == 0);
    try expect(desc.depth.pixel_format == .depth_stencil);
    try expect(desc.depth.compare == .always);
    try expect(desc.depth.write_enabled == false);
    try expect(desc.depth.bias == 0);
    try expect(desc.depth.bias_slope_scale == 0);
    try expect(desc.depth.bias_clamp == 0);
    try expect(desc.color_count == 1);
    try expect(desc.colors[0].pixel_format == .rgba8);
    try expect(desc.colors[0].write_mask == .rgba);
    try expect(desc.colors[0].blend.enabled == false);
    try expect(desc.colors[0].blend.src_factor_rgb == .one);
    try expect(desc.colors[0].blend.dst_factor_rgb == .zero);
    try expect(desc.colors[0].blend.op_rgb == .add);
    try expect(desc.colors[0].blend.src_factor_alpha == .one);
    try expect(desc.colors[0].blend.dst_factor_alpha == .zero);
    try expect(desc.colors[0].blend.op_alpha == .add);
    try expect(desc.alpha_to_coverage_enabled == false);
    try expect(desc.primitive_type == .triangles);
    try expect(desc.index_type == .none);
    try expect(desc.cull_mode == .none);
    try expect(desc.face_winding == .cw);
    try expect(desc.sample_count == 1);
}

// test that color attachment defaults are set in all attachments
test "query_mrt_pipeline_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.queryPipelineDefaults(.{ .color_count = 3 });
    try expect(desc.color_count == 3);
    const n: usize = @intCast(desc.color_count);
    for (0..n) |i| {
        try expect(desc.colors[i].pixel_format == .rgba8);
        try expect(desc.colors[i].write_mask == .rgba);
        try expect(desc.colors[i].blend.enabled == false);
        try expect(desc.colors[i].blend.src_factor_rgb == .one);
        try expect(desc.colors[i].blend.dst_factor_rgb == .zero);
        try expect(desc.colors[i].blend.op_rgb == .add);
        try expect(desc.colors[i].blend.src_factor_alpha == .one);
        try expect(desc.colors[i].blend.dst_factor_alpha == .zero);
        try expect(desc.colors[i].blend.op_alpha == .add);
    }
}

// test that first color attachment values are duplicated to other attachments
test "multiple_color_state" {
    common.setup(.{});
    defer gfx.shutdown();
    var pdesc: gfx.PipelineDesc = .{ .color_count = 3 };
    pdesc.colors[0] = .{
        .pixel_format = .r8,
        .write_mask = .ba,
        .blend = .{
            .enabled = true,
            .src_factor_rgb = .src_color,
            .dst_factor_rgb = .dst_color,
            .op_rgb = .subtract,
            .src_factor_alpha = .src_alpha,
            .dst_factor_alpha = .dst_alpha,
            .op_alpha = .reverse_subtract,
        },
    };
    pdesc.colors[2] = .{
        .pixel_format = .rg8,
        .write_mask = .ga,
        .blend = .{
            .enabled = true,
            .src_factor_rgb = .dst_color,
            .dst_factor_rgb = .src_color,
            .op_rgb = .reverse_subtract,
            .src_factor_alpha = .dst_alpha,
            .dst_factor_alpha = .src_alpha,
            .op_alpha = .subtract,
        },
    };
    const desc = gfx.queryPipelineDefaults(pdesc);
    try expect(desc.color_count == 3);

    try expect(desc.colors[0].pixel_format == .r8);
    try expect(desc.colors[0].write_mask == .ba);
    try expect(desc.colors[0].blend.enabled == true);
    try expect(desc.colors[0].blend.src_factor_rgb == .src_color);
    try expect(desc.colors[0].blend.dst_factor_rgb == .dst_color);
    try expect(desc.colors[0].blend.op_rgb == .subtract);
    try expect(desc.colors[0].blend.src_factor_alpha == .src_alpha);
    try expect(desc.colors[0].blend.dst_factor_alpha == .dst_alpha);
    try expect(desc.colors[0].blend.op_alpha == .reverse_subtract);

    try expect(desc.colors[1].pixel_format == .rgba8);
    try expect(desc.colors[1].write_mask == .rgba);
    try expect(desc.colors[1].blend.enabled == false);
    try expect(desc.colors[1].blend.src_factor_rgb == .one);
    try expect(desc.colors[1].blend.dst_factor_rgb == .zero);
    try expect(desc.colors[1].blend.op_rgb == .add);
    try expect(desc.colors[1].blend.src_factor_alpha == .one);
    try expect(desc.colors[1].blend.dst_factor_alpha == .zero);
    try expect(desc.colors[1].blend.op_alpha == .add);

    try expect(desc.colors[2].pixel_format == .rg8);
    try expect(desc.colors[2].write_mask == .ga);
    try expect(desc.colors[2].blend.enabled == true);
    try expect(desc.colors[2].blend.src_factor_rgb == .dst_color);
    try expect(desc.colors[2].blend.dst_factor_rgb == .src_color);
    try expect(desc.colors[2].blend.op_rgb == .reverse_subtract);
    try expect(desc.colors[2].blend.src_factor_alpha == .dst_alpha);
    try expect(desc.colors[2].blend.dst_factor_alpha == .src_alpha);
    try expect(desc.colors[2].blend.op_alpha == .subtract);
}

test "query_view_defaults" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.queryViewDefaults(.{});
    try expect(desc.texture.image.id == invalid_id);
    try expect(desc.texture.mip_levels.count == 0);
}

test "query_buffer_info" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = gfx.makeBuffer(.{
        .size = 256,
        .usage = .{
            .vertex_buffer = true,
            .write_transient = true,
        },
    });
    try expect(buf.id != invalid_id);
    const info = gfx.queryBufferInfo(buf);
    try expect(info.slot.state == .valid);
    try expect(info.slot.res_id == buf.id);
}

test "query_image_info" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 256,
        .height = 128,
    });
    try expect(img.id != invalid_id);
    const info = gfx.queryImageInfo(img);
    try expect(info.slot.state == .valid);
    try expect(info.slot.res_id == img.id);
    try expect(info.num_slots == 1);
}

test "query_sampler_info" {
    common.setup(.{});
    defer gfx.shutdown();
    const smp = gfx.makeSampler(.{});
    try expect(smp.id != invalid_id);
    const info = gfx.querySamplerInfo(smp);
    try expect(info.slot.state == .valid);
    try expect(info.slot.res_id == smp.id);
}

test "query_shader_info" {
    common.setup(.{});
    defer gfx.shutdown();
    var sdesc: gfx.ShaderDesc = .{};
    sdesc.attrs[0].glsl_name = "pos";
    sdesc.vertex_func.source = "bla";
    sdesc.fragment_func.source = "blub";
    const shd = gfx.makeShader(sdesc);
    const info = gfx.queryShaderInfo(shd);
    try expect(info.slot.state == .valid);
    try expect(info.slot.res_id == shd.id);
}

test "query_pipeline_info" {
    common.setup(.{});
    defer gfx.shutdown();
    var sdesc: gfx.ShaderDesc = .{};
    sdesc.attrs[0].glsl_name = "pos";
    sdesc.vertex_func.source = "bla";
    sdesc.fragment_func.source = "blub";
    var pdesc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(sdesc) };
    pdesc.layout.attrs[0].format = .float3;
    const pip = gfx.makePipeline(pdesc);
    const info = gfx.queryPipelineInfo(pip);
    try expect(info.slot.state == .valid);
    try expect(info.slot.res_id == pip.id);
}

test "query_view_info" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 128,
        .height = 128,
    });
    const view = gfx.makeView(.{ .color_attachment = .{ .image = img } });
    const info = gfx.queryViewInfo(view);
    try expect(info.slot.state == .valid);
    try expect(info.slot.res_id == view.id);
}

test "query_buffer_desc" {
    common.setup(.{});
    defer gfx.shutdown();

    const b0 = gfx.makeBuffer(.{
        .size = 32,
        .usage = .{ .write_transient = true },
        .label = "bla",
    });
    const b0_desc = gfx.queryBufferDesc(b0);
    try expect(b0_desc.size == 32);
    try expect(b0_desc.usage.vertex_buffer);
    try expect(b0_desc.usage.write_transient);
    try expect(b0_desc.data.ptr == null);
    try expect(b0_desc.data.size == 0);
    try expect(b0_desc.gl_buffer == 0);
    try expect(b0_desc.mtl_buffer == null);
    try expect(b0_desc.d3d11_buffer == null);
    try expect(b0_desc.wgpu_buffer == null);
    try expect(gfx.queryBufferSize(b0) == 32);
    try expect(gfx.queryBufferUsage(b0).write_transient);

    var vtx_data = std.mem.zeroes([16]f32);
    const b1 = gfx.makeBuffer(.{
        .data = gfx.Range.fromSlice(f32, &vtx_data),
    });
    const b1_desc = gfx.queryBufferDesc(b1);
    try expect(b1_desc.size == @sizeOf(@TypeOf(vtx_data)));
    try expect(b1_desc.usage.vertex_buffer);
    try expect(!b1_desc.usage.write_transient);
    try expect(!b1_desc.usage.copy_dst);
    try expect(b1_desc.data.ptr == null);
    try expect(b1_desc.data.size == 0);
    try expect(gfx.queryBufferSize(b1) == @sizeOf(@TypeOf(vtx_data)));
    try expect(gfx.queryBufferUsage(b1).vertex_buffer);
    try expect(!gfx.queryBufferUsage(b1).write_transient);

    var idx_data = std.mem.zeroes([8]u16);
    const b2 = gfx.makeBuffer(.{
        .usage = .{ .index_buffer = true },
        .data = gfx.Range.fromSlice(u16, &idx_data),
    });
    const b2_desc = gfx.queryBufferDesc(b2);
    try expect(b2_desc.size == @sizeOf(@TypeOf(idx_data)));
    try expect(b2_desc.usage.index_buffer);
    try expect(!b2_desc.usage.write_transient);
    try expect(!b2_desc.usage.copy_dst);
    try expect(b2_desc.data.ptr == null);
    try expect(b2_desc.data.size == 0);
    try expect(gfx.queryBufferSize(b2) == @sizeOf(@TypeOf(idx_data)));
    try expect(gfx.queryBufferUsage(b2).index_buffer);
    try expect(!gfx.queryBufferUsage(b2).write_transient);

    // invalid buffer (returns zeroed desc)
    const b3 = gfx.makeBuffer(.{
        .size = 32,
        .usage = .{ .write_transient = true },
        .label = "bla",
    });
    gfx.destroyBuffer(b3);
    const b3_desc = gfx.queryBufferDesc(b3);
    try expect(b3_desc.size == 0);
    try expect(!b3_desc.usage.write_transient);
    try expect(gfx.queryBufferSize(b3) == 0);
    try expect(!gfx.queryBufferUsage(b3).write_transient);
}

test "query_image_desc" {
    common.setup(.{});
    defer gfx.shutdown();

    const img0 = gfx.makeImage(.{
        .width = 256,
        .height = 512,
        .pixel_format = .r8,
        .usage = .{ .copy_dst = true },
    });
    const img0_desc = gfx.queryImageDesc(img0);
    try expect(img0_desc.type == .@"2d");
    try expect(!img0_desc.usage.color_attachment);
    try expect(!img0_desc.usage.resolve_attachment);
    try expect(!img0_desc.usage.depth_stencil_attachment);
    try expect(img0_desc.usage.copy_dst);
    try expect(!img0_desc.usage.immutable);
    try expect(img0_desc.width == 256);
    try expect(img0_desc.height == 512);
    try expect(img0_desc.num_slices == 1);
    try expect(img0_desc.num_mipmaps == 1);
    try expect(img0_desc.pixel_format == .r8);
    try expect(img0_desc.sample_count == 1);
    try expect(img0_desc.data.mip_levels[0].ptr == null);
    try expect(img0_desc.data.mip_levels[0].size == 0);
    try expect(img0_desc.gl_texture == 0);
    try expect(img0_desc.gl_texture_target == 0);
    try expect(img0_desc.mtl_texture == null);
    try expect(img0_desc.d3d11_texture == null);
    try expect(img0_desc.wgpu_texture == null);
    try expect(gfx.queryImageType(img0) == .@"2d");
    try expect(gfx.queryImageWidth(img0) == 256);
    try expect(gfx.queryImageHeight(img0) == 512);
    try expect(gfx.queryImageNumSlices(img0) == 1);
    try expect(gfx.queryImageNumMipmaps(img0) == 1);
    try expect(gfx.queryImagePixelformat(img0) == .r8);
    try expect(gfx.queryImageSampleCount(img0) == 1);
    gfx.destroyImage(img0);
    const img0_desc_x = gfx.queryImageDesc(img0);
    try expect(img0_desc_x.type == .default);
    try expect(!img0_desc_x.usage.color_attachment);
    try expect(!img0_desc_x.usage.resolve_attachment);
    try expect(!img0_desc_x.usage.depth_stencil_attachment);
    try expect(!img0_desc_x.usage.copy_dst);
    try expect(img0_desc_x.width == 0);
    try expect(img0_desc_x.height == 0);
    try expect(img0_desc_x.num_slices == 0);
    try expect(img0_desc_x.num_mipmaps == 0);
    try expect(img0_desc_x.pixel_format == .default);
    try expect(img0_desc_x.sample_count == 0);
    try expect(gfx.queryImageType(img0) == .default);
    try expect(gfx.queryImageWidth(img0) == 0);
    try expect(gfx.queryImageHeight(img0) == 0);
    try expect(gfx.queryImageNumSlices(img0) == 0);
    try expect(gfx.queryImageNumMipmaps(img0) == 0);
    try expect(gfx.queryImagePixelformat(img0) == .default);
    try expect(gfx.queryImageSampleCount(img0) == 0);
}

test "query_sampler_desc" {
    common.setup(.{});
    defer gfx.shutdown();
    const s0 = gfx.makeSampler(.{
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .linear,
        .wrap_v = .mirrored_repeat,
        .max_anisotropy = 8,
        .border_color = .transparent_black,
        .compare = .greater,
    });
    const s0_desc = gfx.querySamplerDesc(s0);
    try expect(s0_desc.min_filter == .linear);
    try expect(s0_desc.mag_filter == .linear);
    try expect(s0_desc.mipmap_filter == .linear);
    try expect(s0_desc.wrap_u == .repeat);
    try expect(s0_desc.wrap_v == .mirrored_repeat);
    try expect(s0_desc.wrap_w == .repeat);
    try expect(s0_desc.min_lod == 0.0);
    try expect(s0_desc.max_lod == std.math.floatMax(f32));
    try expect(s0_desc.border_color == .transparent_black);
    try expect(s0_desc.compare == .greater);
    try expect(s0_desc.max_anisotropy == 8);

    gfx.destroySampler(s0);
    const s0_desc_x = gfx.querySamplerDesc(s0);
    try expect(s0_desc_x.min_filter == .default);
    try expect(s0_desc_x.compare == .default);
}

test "query_shader_desc" {
    common.setup(.{});
    defer gfx.shutdown();

    var desc: gfx.ShaderDesc = .{};
    desc.attrs[0] = .{ .glsl_name = "pos", .hlsl_sem_name = "POS", .hlsl_sem_index = 1 };
    desc.vertex_func.source = "vs_source";
    desc.fragment_func.source = "fs_source";
    desc.uniform_blocks[0] = .{ .stage = .vertex, .size = 128, .layout = .std140 };
    desc.uniform_blocks[0].glsl_uniforms[0] = .{ .glsl_name = "blub", .type = .float4, .array_count = 1 };
    desc.uniform_blocks[0].glsl_uniforms[1] = .{ .glsl_name = "blob", .type = .float2, .array_count = 1 };
    desc.views[0].texture = .{ .stage = .vertex, .image_type = .@"2d", .sample_type = .float, .multisampled = true };
    desc.views[1].texture = .{ .stage = .vertex, .image_type = .@"3d", .sample_type = .depth };
    desc.views[2].texture = .{ .stage = .fragment, .image_type = .array, .sample_type = .depth };
    desc.views[3].texture = .{ .stage = .fragment, .image_type = .cube, .sample_type = .unfilterable_float };
    desc.samplers[0] = .{ .stage = .vertex, .sampler_type = .filtering };
    desc.samplers[1] = .{ .stage = .vertex, .sampler_type = .comparison };
    desc.samplers[2] = .{ .stage = .fragment, .sampler_type = .comparison };
    desc.samplers[3] = .{ .stage = .fragment, .sampler_type = .nonfiltering };
    desc.texture_sampler_pairs[0] = .{ .stage = .vertex, .view_slot = 0, .sampler_slot = 0, .glsl_name = "img0" };
    desc.texture_sampler_pairs[1] = .{ .stage = .vertex, .view_slot = 1, .sampler_slot = 1, .glsl_name = "img1" };
    desc.texture_sampler_pairs[2] = .{ .stage = .fragment, .view_slot = 2, .sampler_slot = 2, .glsl_name = "img3" };
    desc.texture_sampler_pairs[3] = .{ .stage = .fragment, .view_slot = 3, .sampler_slot = 3, .glsl_name = "img4" };
    desc.label = "label";
    const s0 = gfx.makeShader(desc);

    const s0_desc = gfx.queryShaderDesc(s0);
    try expect(s0_desc.attrs[0].glsl_name == null);
    try expect(s0_desc.attrs[0].hlsl_sem_name == null);
    try expect(s0_desc.attrs[0].hlsl_sem_index == 0);
    try expect(s0_desc.vertex_func.source == null);
    try expect(s0_desc.fragment_func.source == null);
    try expect(s0_desc.uniform_blocks[0].size == 128);
    try expect(s0_desc.uniform_blocks[0].layout == .default);
    try expect(s0_desc.uniform_blocks[0].glsl_uniforms[0].glsl_name == null);
    try expect(s0_desc.uniform_blocks[0].glsl_uniforms[0].type == .invalid);
    try expect(s0_desc.uniform_blocks[0].glsl_uniforms[0].array_count == 0);
    try expect(s0_desc.views[0].texture.stage == .vertex);
    try expect(s0_desc.views[0].texture.image_type == .@"2d");
    try expect(s0_desc.views[0].texture.sample_type == .float);
    try expect(s0_desc.views[0].texture.multisampled);
    try expect(s0_desc.views[1].texture.stage == .vertex);
    try expect(s0_desc.views[1].texture.image_type == .@"3d");
    try expect(s0_desc.views[1].texture.sample_type == .depth);
    try expect(s0_desc.views[1].texture.multisampled == false);
    try expect(s0_desc.views[2].texture.stage == .fragment);
    try expect(s0_desc.views[2].texture.image_type == .array);
    try expect(s0_desc.views[2].texture.sample_type == .depth);
    try expect(s0_desc.views[2].texture.multisampled == false);
    try expect(s0_desc.views[3].texture.stage == .fragment);
    try expect(s0_desc.views[3].texture.image_type == .cube);
    try expect(s0_desc.views[3].texture.sample_type == .unfilterable_float);
    try expect(s0_desc.views[3].texture.multisampled == false);
    try expect(s0_desc.samplers[0].stage == .vertex);
    try expect(s0_desc.samplers[0].sampler_type == .filtering);
    try expect(s0_desc.samplers[1].stage == .vertex);
    try expect(s0_desc.samplers[1].sampler_type == .comparison);
    try expect(s0_desc.samplers[2].stage == .fragment);
    try expect(s0_desc.samplers[2].sampler_type == .comparison);
    try expect(s0_desc.samplers[3].stage == .fragment);
    try expect(s0_desc.samplers[3].sampler_type == .nonfiltering);
    try expect(s0_desc.texture_sampler_pairs[0].stage == .vertex);
    try expect(s0_desc.texture_sampler_pairs[0].view_slot == 0);
    try expect(s0_desc.texture_sampler_pairs[0].sampler_slot == 0);
    try expect(s0_desc.texture_sampler_pairs[0].glsl_name == null);
    try expect(s0_desc.texture_sampler_pairs[1].stage == .vertex);
    try expect(s0_desc.texture_sampler_pairs[1].view_slot == 1);
    try expect(s0_desc.texture_sampler_pairs[1].sampler_slot == 1);
    try expect(s0_desc.texture_sampler_pairs[1].glsl_name == null);
    try expect(s0_desc.texture_sampler_pairs[2].stage == .fragment);
    try expect(s0_desc.texture_sampler_pairs[2].view_slot == 2);
    try expect(s0_desc.texture_sampler_pairs[2].sampler_slot == 2);
    try expect(s0_desc.texture_sampler_pairs[2].glsl_name == null);
    try expect(s0_desc.texture_sampler_pairs[3].stage == .fragment);
    try expect(s0_desc.texture_sampler_pairs[3].view_slot == 3);
    try expect(s0_desc.texture_sampler_pairs[3].sampler_slot == 3);
    try expect(s0_desc.texture_sampler_pairs[3].glsl_name == null);
}

test "query_pipeline_desc" {
    common.setup(.{});
    defer gfx.shutdown();

    const shd = gfx.makeShader(.{});
    var pdesc: gfx.PipelineDesc = .{ .shader = shd, .label = "p0" };
    pdesc.layout.attrs[0].format = .float4;
    pdesc.layout.attrs[1].format = .float2;
    const p0 = gfx.makePipeline(pdesc);

    const p0_desc = gfx.queryPipelineDesc(p0);
    try expect(p0_desc.shader.id == shd.id);
    try expect(p0_desc.layout.buffers[0].stride == 24);
    try expect(p0_desc.layout.buffers[0].step_func == .per_vertex);
    try expect(p0_desc.layout.buffers[0].step_rate == 1);
    try expect(p0_desc.layout.buffers[1].stride == 0);
    try expect(p0_desc.layout.buffers[1].step_func == .default);
    try expect(p0_desc.layout.buffers[1].step_rate == 0);
    try expect(p0_desc.layout.attrs[0].format == .float4);
    try expect(p0_desc.layout.attrs[0].offset == 0);
    try expect(p0_desc.layout.attrs[0].buffer_index == 0);
    try expect(p0_desc.layout.attrs[1].format == .float2);
    try expect(p0_desc.layout.attrs[1].offset == 16);
    try expect(p0_desc.layout.attrs[1].buffer_index == 0);
    try expect(p0_desc.layout.attrs[2].format == .invalid);
    try expect(p0_desc.layout.attrs[2].offset == 0);
    try expect(p0_desc.layout.attrs[2].buffer_index == 0);
    try expect(p0_desc.depth.pixel_format == .depth_stencil);
    try expect(p0_desc.depth.compare == .always);
    try expect(p0_desc.depth.write_enabled == false);
    try expect(p0_desc.depth.bias == 0.0);
    try expect(p0_desc.depth.bias_slope_scale == 0.0);
    try expect(p0_desc.depth.bias_clamp == 0.0);
    try expect(p0_desc.stencil.enabled == false);
    try expect(p0_desc.stencil.front.compare == .always);
    try expect(p0_desc.stencil.front.fail_op == .keep);
    try expect(p0_desc.stencil.front.depth_fail_op == .keep);
    try expect(p0_desc.stencil.front.pass_op == .keep);
    try expect(p0_desc.stencil.back.compare == .always);
    try expect(p0_desc.stencil.back.fail_op == .keep);
    try expect(p0_desc.stencil.back.depth_fail_op == .keep);
    try expect(p0_desc.stencil.back.pass_op == .keep);
    try expect(p0_desc.stencil.read_mask == 0);
    try expect(p0_desc.stencil.write_mask == 0);
    try expect(p0_desc.stencil.ref == 0);
    try expect(p0_desc.color_count == 1);
    try expect(p0_desc.colors[0].pixel_format == .rgba8);
    try expect(p0_desc.colors[0].write_mask == .rgba);
    try expect(p0_desc.colors[0].blend.enabled == false);
    try expect(p0_desc.colors[0].blend.src_factor_rgb == .one);
    try expect(p0_desc.colors[0].blend.dst_factor_rgb == .zero);
    try expect(p0_desc.colors[0].blend.op_rgb == .add);
    try expect(p0_desc.colors[0].blend.src_factor_alpha == .one);
    try expect(p0_desc.colors[0].blend.dst_factor_alpha == .zero);
    try expect(p0_desc.colors[0].blend.op_alpha == .add);
    try expect(p0_desc.primitive_type == .triangles);
    try expect(p0_desc.index_type == .none);
    try expect(p0_desc.cull_mode == .none);
    try expect(p0_desc.face_winding == .cw);
    try expect(p0_desc.sample_count == 1);
    try expect(p0_desc.blend_color.r == 0.0);
    try expect(p0_desc.blend_color.g == 0.0);
    try expect(p0_desc.blend_color.b == 0.0);
    try expect(p0_desc.blend_color.a == 0.0);
    try expect(p0_desc.alpha_to_coverage_enabled == false);
    try expect(p0_desc.label == null);
}

test "query_view_desc" {
    common.setup(.{});
    defer gfx.shutdown();

    const color_img_desc = gfx.ImageDesc{
        .usage = .{ .color_attachment = true },
        .width = 128,
        .height = 128,
    };
    const depth_img_desc = gfx.ImageDesc{
        .usage = .{ .depth_stencil_attachment = true },
        .width = 128,
        .height = 128,
        .pixel_format = .depth,
    };
    const color_img = gfx.makeImage(color_img_desc);
    const depth_img = gfx.makeImage(depth_img_desc);
    const color_view = gfx.makeView(.{ .color_attachment = .{ .image = color_img } });
    const depth_view = gfx.makeView(.{ .depth_stencil_attachment = .{ .image = depth_img } });

    const color_view_desc = gfx.queryViewDesc(color_view);
    try expect(color_view_desc.color_attachment.image.id == color_img.id);
    try expect(color_view_desc.color_attachment.mip_level == 0);
    try expect(color_view_desc.color_attachment.slice == 0);
    const depth_view_desc = gfx.queryViewDesc(depth_view);
    try expect(depth_view_desc.depth_stencil_attachment.image.id == depth_img.id);
    try expect(depth_view_desc.depth_stencil_attachment.mip_level == 0);
    try expect(depth_view_desc.depth_stencil_attachment.slice == 0);
}

test "buffer_resource_states" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = gfx.allocBuffer();
    try expect(gfx.queryBufferState(buf) == .alloc);
    gfx.initBuffer(buf, .{ .usage = .{ .write_transient = true }, .size = 128 });
    try expect(gfx.queryBufferState(buf) == .valid);
    gfx.uninitBuffer(buf);
    try expect(gfx.queryBufferState(buf) == .alloc);
    gfx.deallocBuffer(buf);
    try expect(gfx.queryBufferState(buf) == .invalid);
}

test "image_resource_states" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.allocImage();
    try expect(gfx.queryImageState(img) == .alloc);
    gfx.initImage(img, .{ .usage = .{ .color_attachment = true }, .width = 16, .height = 16 });
    try expect(gfx.queryImageState(img) == .valid);
    gfx.uninitImage(img);
    try expect(gfx.queryImageState(img) == .alloc);
    gfx.deallocImage(img);
    try expect(gfx.queryImageState(img) == .invalid);
}

test "sampler_resource_states" {
    common.setup(.{});
    defer gfx.shutdown();
    const smp = gfx.allocSampler();
    try expect(gfx.querySamplerState(smp) == .alloc);
    gfx.initSampler(smp, .{ .min_filter = .linear, .mag_filter = .linear });
    try expect(gfx.querySamplerState(smp) == .valid);
    gfx.uninitSampler(smp);
    try expect(gfx.querySamplerState(smp) == .alloc);
    gfx.deallocSampler(smp);
    try expect(gfx.querySamplerState(smp) == .invalid);
}

test "shader_resource_states" {
    common.setup(.{});
    defer gfx.shutdown();
    const shd = gfx.allocShader();
    try expect(gfx.queryShaderState(shd) == .alloc);
    gfx.initShader(shd, .{});
    try expect(gfx.queryShaderState(shd) == .valid);
    gfx.uninitShader(shd);
    try expect(gfx.queryShaderState(shd) == .alloc);
    gfx.deallocShader(shd);
    try expect(gfx.queryShaderState(shd) == .invalid);
}

test "pipeline_resource_states" {
    common.setup(.{});
    defer gfx.shutdown();
    const pip = gfx.allocPipeline();
    try expect(gfx.queryPipelineState(pip) == .alloc);
    var pdesc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(.{}) };
    pdesc.layout.attrs[0].format = .float3;
    gfx.initPipeline(pip, pdesc);
    try expect(gfx.queryPipelineState(pip) == .valid);
    gfx.uninitPipeline(pip);
    try expect(gfx.queryPipelineState(pip) == .alloc);
    gfx.deallocPipeline(pip);
    try expect(gfx.queryPipelineState(pip) == .invalid);
}

test "view_resource_states" {
    common.setup(.{});
    defer gfx.shutdown();
    const view = gfx.allocView();
    try expect(gfx.queryViewState(view) == .alloc);
    gfx.initView(view, .{
        .color_attachment = .{ .image = gfx.makeImage(.{ .usage = .{ .color_attachment = true }, .width = 16, .height = 16 }) },
    });
    try expect(gfx.queryViewState(view) == .valid);
    gfx.uninitView(view);
    try expect(gfx.queryViewState(view) == .alloc);
    gfx.deallocView(view);
    try expect(gfx.queryViewState(view) == .invalid);
}

test "buffer_uninit_count" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.BufferDesc{ .usage = .{ .write_transient = true }, .size = 128 };
    const buf = gfx.makeBuffer(desc);
    try expect(gfx.queryBufferInfo(buf).slot.uninit_count == 0);
    gfx.uninitBuffer(buf);
    try expect(gfx.queryBufferInfo(buf).slot.uninit_count == 1);
    gfx.initBuffer(buf, desc);
    try expect(gfx.queryBufferInfo(buf).slot.uninit_count == 1);
    gfx.uninitBuffer(buf);
    try expect(gfx.queryBufferInfo(buf).slot.uninit_count == 2);
    gfx.deallocBuffer(buf);
    try expect(gfx.queryBufferInfo(buf).slot.uninit_count == 0);
}

test "image_uninit_count" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.ImageDesc{ .usage = .{ .color_attachment = true }, .width = 128, .height = 128 };
    const img = gfx.makeImage(desc);
    try expect(gfx.queryImageInfo(img).slot.uninit_count == 0);
    gfx.uninitImage(img);
    try expect(gfx.queryImageInfo(img).slot.uninit_count == 1);
    gfx.initImage(img, desc);
    try expect(gfx.queryImageInfo(img).slot.uninit_count == 1);
    gfx.uninitImage(img);
    try expect(gfx.queryImageInfo(img).slot.uninit_count == 2);
    gfx.deallocImage(img);
    try expect(gfx.queryImageInfo(img).slot.uninit_count == 0);
}

test "shader_uninit_count" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.ShaderDesc{};
    const shd = gfx.makeShader(desc);
    try expect(gfx.queryShaderInfo(shd).slot.uninit_count == 0);
    gfx.uninitShader(shd);
    try expect(gfx.queryShaderInfo(shd).slot.uninit_count == 1);
    gfx.initShader(shd, desc);
    try expect(gfx.queryShaderInfo(shd).slot.uninit_count == 1);
    gfx.uninitShader(shd);
    try expect(gfx.queryShaderInfo(shd).slot.uninit_count == 2);
    gfx.deallocShader(shd);
    try expect(gfx.queryShaderInfo(shd).slot.uninit_count == 0);
}

test "pipeline_uninit_count" {
    common.setup(.{});
    defer gfx.shutdown();
    const desc = gfx.PipelineDesc{ .shader = gfx.makeShader(.{}) };
    const pip = gfx.makePipeline(desc);
    try expect(gfx.queryPipelineInfo(pip).slot.uninit_count == 0);
    gfx.uninitPipeline(pip);
    try expect(gfx.queryPipelineInfo(pip).slot.uninit_count == 1);
    gfx.initPipeline(pip, desc);
    try expect(gfx.queryPipelineInfo(pip).slot.uninit_count == 1);
    gfx.uninitPipeline(pip);
    try expect(gfx.queryPipelineInfo(pip).slot.uninit_count == 2);
    gfx.deallocPipeline(pip);
    try expect(gfx.queryPipelineInfo(pip).slot.uninit_count == 0);
}

test "view_uninit_count" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{ .width = 128, .height = 128 });
    const desc = gfx.ViewDesc{ .texture = .{ .image = img } };
    const view = gfx.makeView(desc);
    try expect(gfx.queryViewInfo(view).slot.uninit_count == 0);
    gfx.uninitView(view);
    try expect(gfx.queryViewInfo(view).slot.uninit_count == 1);
    gfx.initView(view, desc);
    try expect(gfx.queryViewInfo(view).slot.uninit_count == 1);
    gfx.uninitView(view);
    try expect(gfx.queryViewInfo(view).slot.uninit_count == 2);
    gfx.deallocView(view);
    try expect(gfx.queryViewInfo(view).slot.uninit_count == 0);
}

test "copy_buffer_to_buffer_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(64);
    const dst = createCopyDstBuffer(64);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryBufferState(dst) == .valid);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{
        .src = .{ .buffer = src, .offset = 16 },
        .dst = .{ .buffer = dst, .offset = 32 },
        .size = 32,
    });
    try expect(common.num_log_called == 0);
    try expect(core.lookupBuffer(src.id).?.cmn.validate.copy_src_frame_index == core.state().frame_index);
}

test "copy_buffer_to_buffer_validate_usage" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = common.createBuffer();
    const dst = common.createBuffer();
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryBufferState(dst) == .valid);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{
        .src = .{ .buffer = src },
        .dst = .{ .buffer = dst },
        .size = 16,
    });
    try expect(common.log_items[0] == .validate_copybuffertobuffer_copy_src);
    try expect(common.log_items[1] == .validate_copybuffertobuffer_copy_dst);
    try expect(common.log_items[2] == .validation_failed);
    try expect(common.num_log_called == 3);
}

test "copy_buffer_to_buffer_validate_same_buffer" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = gfx.makeBuffer(.{
        .size = 64,
        .usage = .{ .vertex_buffer = true, .copy_src = true, .copy_dst = true },
    });
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{
        .src = .{ .buffer = buf, .offset = 0 },
        .dst = .{ .buffer = buf, .offset = 32 },
        .size = 16,
    });
    try expect(common.log_items[0] == .validate_copybuffertobuffer_src_vs_dst_buffer);
    try expect(common.log_items[1] == .validation_failed);
    try expect(common.num_log_called == 2);
}
