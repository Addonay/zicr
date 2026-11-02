//! Tests ported from upstream sokol tests/functional/sokol_gfx_test.c (part 4).
const std = @import("std");
const common = @import("upstream_test_common.zig");
const gfx = common.gfx;
const core = common.core;

// ---------------------------------------------------------------- helpers

fn createCopyDstImage(width: i32, height: i32) gfx.Image {
    return gfx.makeImage(.{ .width = width, .height = height, .pixel_format = .rgba8, .usage = .{ .copy_dst = true } });
}

// override backend features after resource creation to test the validation rules in isolation
fn setCopyBufferToImageFeatures(relaxed_buffer_type: bool, relaxed_bytes_per_row: bool, separate_buffer_types: bool) void {
    const features = &core.state().features;
    features.copy_buffer_to_image_relaxed_buffer_type = relaxed_buffer_type;
    features.copy_buffer_to_image_relaxed_bytes_per_row = relaxed_bytes_per_row;
    features.separate_buffer_types = separate_buffer_types;
}

/// The WRITE_TRANSIENT_TEST_PASS and SBUF_RW_TEST_PASS macros of the C file.
fn testPass() gfx.Pass {
    return .{ .swapchain = .{ .width = 64, .height = 64, .sample_count = 1, .color_format = .rgba8 } };
}

/// the dummy backend has no compute support, fake it for the storage buffer tests
fn setupWithCompute(desc: gfx.Desc) void {
    common.setup(desc);
    core.state().features.compute = true;
}

fn createWriteTransientTestPipeline() gfx.Pipeline {
    var desc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(.{}) };
    desc.layout.attrs[0].format = .float3;
    return gfx.makePipeline(desc);
}

fn createWriteTransientTestBuffer() gfx.Buffer {
    return gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_transient = true }, .size = 128 });
}

// pipeline + shader with one write_transient texture view for the image tests
const WriteTransientImageSetup = struct {
    pip: gfx.Pipeline = .{},
    vbuf: gfx.Buffer = .{},
    img: gfx.Image = .{},
    view: gfx.View = .{},
    smp: gfx.Sampler = .{},
};

fn createWriteTransientImageSetup() WriteTransientImageSetup {
    var s: WriteTransientImageSetup = .{};
    // non-transient vertex buffer to keep the buffer-side check silent
    const verts = std.mem.zeroes([8]f32);
    s.vbuf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true }, .data = gfx.Range.fromSlice(f32, &verts) });
    s.img = gfx.makeImage(.{ .usage = .{ .write_transient = true }, .width = 8, .height = 8, .pixel_format = .rgba8 });
    s.view = gfx.makeView(.{ .texture = .{ .image = s.img } });
    s.smp = gfx.makeSampler(.{});
    var shd_desc: gfx.ShaderDesc = .{};
    shd_desc.views[0].texture = .{ .stage = .fragment, .image_type = .@"2d", .sample_type = .float };
    shd_desc.samplers[0] = .{ .stage = .fragment, .sampler_type = .filtering };
    shd_desc.texture_sampler_pairs[0] = .{ .stage = .fragment, .view_slot = 0, .sampler_slot = 0 };
    var pip_desc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(shd_desc) };
    pip_desc.layout.attrs[0].format = .float3;
    s.pip = gfx.makePipeline(pip_desc);
    return s;
}

fn imageSetupBindings(s: WriteTransientImageSetup) gfx.Bindings {
    var b: gfx.Bindings = .{};
    b.vertex_buffers[0] = s.vbuf;
    b.views[0] = s.view;
    b.samplers[0] = s.smp;
    return b;
}

fn vertexBindings(buf: gfx.Buffer) gfx.Bindings {
    var b: gfx.Bindings = .{};
    b.vertex_buffers[0] = buf;
    return b;
}

fn indexBindings(buf: gfx.Buffer) gfx.Bindings {
    var b: gfx.Bindings = .{};
    b.index_buffer = buf;
    return b;
}

fn viewBindings(view: gfx.View) gfx.Bindings {
    var b: gfx.Bindings = .{};
    b.views[0] = view;
    return b;
}

fn views01Bindings(view0: gfx.View, view1: gfx.View) gfx.Bindings {
    var b: gfx.Bindings = .{};
    b.views[0] = view0;
    b.views[1] = view1;
    return b;
}

// read/write storage buffers in fragment shaders

const SbufRwSetup = struct {
    buf: gfx.Buffer = .{}, // vertex, index and storage buffer
    view: gfx.View = .{}, // storage buffer view on buf
    view2: gfx.View = .{}, // another storage buffer view on buf
    other_buf: gfx.Buffer = .{}, // a second storage buffer
    other_view: gfx.View = .{}, // storage buffer view on other_buf
    fs_rw_pip: gfx.Pipeline = .{}, // views[0]: fragment read/write
    fs_ro_pip: gfx.Pipeline = .{}, // views[0]: fragment readonly
    vs_ro_pip: gfx.Pipeline = .{}, // views[0]: vertex readonly
    fs_rw_ro_pip: gfx.Pipeline = .{}, // views[0]: fragment read/write, views[1]: fragment readonly
    vbuf_pip: gfx.Pipeline = .{}, // one vertex buffer, no views
    ibuf_pip: gfx.Pipeline = .{}, // index buffer, no vertex buffers, no views
    cs_rw_pip: gfx.Pipeline = .{}, // compute, views[0]: read/write
    cs_ro_pip: gfx.Pipeline = .{}, // compute, views[0]: readonly
};

fn createSbufRenderShader(stage0: gfx.ShaderStage, readonly0: bool, stage1: gfx.ShaderStage, readonly1: bool) gfx.Shader {
    var desc: gfx.ShaderDesc = .{};
    desc.views[0].storage_buffer = .{ .stage = stage0, .readonly = readonly0 };
    desc.views[1].storage_buffer = .{ .stage = stage1, .readonly = readonly1 };
    return gfx.makeShader(desc);
}

fn createSbufStageShader(stage: gfx.ShaderStage, readonly: bool) gfx.Shader {
    var desc: gfx.ShaderDesc = .{};
    desc.views[0].storage_buffer = .{ .stage = stage, .readonly = readonly };
    return gfx.makeShader(desc);
}

fn createCsSbufShader(readonly: bool) gfx.Shader {
    var desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = "cs" } };
    desc.views[0].storage_buffer = .{ .stage = .compute, .readonly = readonly };
    return gfx.makeShader(desc);
}

fn createSbufRwSetup() SbufRwSetup {
    var s: SbufRwSetup = .{};
    const data = std.mem.zeroes([64]u8);
    s.buf = gfx.makeBuffer(.{
        .usage = .{ .vertex_buffer = true, .index_buffer = true, .storage_buffer = true },
        .data = gfx.Range.fromSlice(u8, &data),
    });
    s.view = gfx.makeView(.{ .storage_buffer = .{ .buffer = s.buf } });
    s.view2 = gfx.makeView(.{ .storage_buffer = .{ .buffer = s.buf } });
    s.other_buf = gfx.makeBuffer(.{ .usage = .{ .storage_buffer = true }, .size = 64 });
    s.other_view = gfx.makeView(.{ .storage_buffer = .{ .buffer = s.other_buf } });
    s.fs_rw_pip = gfx.makePipeline(.{ .shader = createSbufStageShader(.fragment, false) });
    s.fs_ro_pip = gfx.makePipeline(.{ .shader = createSbufStageShader(.fragment, true) });
    s.vs_ro_pip = gfx.makePipeline(.{ .shader = createSbufStageShader(.vertex, true) });
    s.fs_rw_ro_pip = gfx.makePipeline(.{ .shader = createSbufRenderShader(.fragment, false, .fragment, true) });
    var vbuf_desc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(.{}) };
    vbuf_desc.layout.attrs[0].format = .float3;
    s.vbuf_pip = gfx.makePipeline(vbuf_desc);
    s.ibuf_pip = gfx.makePipeline(.{ .shader = gfx.makeShader(.{}), .index_type = .uint16 });
    s.cs_rw_pip = gfx.makePipeline(.{ .compute = true, .shader = createCsSbufShader(false) });
    s.cs_ro_pip = gfx.makePipeline(.{ .compute = true, .shader = createCsSbufShader(true) });
    return s;
}

fn applySbufRw(s: *const SbufRwSetup, view: gfx.View) void {
    gfx.applyPipeline(s.fs_rw_pip);
    gfx.applyBindings(viewBindings(view));
}

fn testWriteResourceState() !void {
    const data = std.mem.zeroes([64]u32);
    const data_range = gfx.Range.fromSlice(u32, &data);
    const valid_buf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_transient = true }, .size = @sizeOf(@TypeOf(data)) });
    const unsealed_buf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_unsealed = true }, .size = @sizeOf(@TypeOf(data)) });
    const alloc_buf = gfx.allocBuffer();
    const failed_buf = gfx.allocBuffer();
    gfx.failBuffer(failed_buf);
    const dead_buf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_transient = true }, .size = @sizeOf(@TypeOf(data)) });
    gfx.destroyBuffer(dead_buf);
    const valid_img = gfx.makeImage(.{ .usage = .{ .write_transient = true }, .width = 8, .height = 8, .pixel_format = .rgba8 });
    const unsealed_img = gfx.makeImage(.{ .usage = .{ .write_unsealed = true }, .width = 8, .height = 8, .pixel_format = .rgba8 });
    const alloc_img = gfx.allocImage();
    const failed_img = gfx.allocImage();
    gfx.failImage(failed_img);
    const dead_img = gfx.makeImage(.{ .usage = .{ .write_transient = true }, .width = 8, .height = 8, .pixel_format = .rgba8 });
    gfx.destroyImage(dead_img);
    try std.testing.expect(gfx.queryBufferState(valid_buf) == .valid);
    try std.testing.expect(gfx.queryBufferState(unsealed_buf) == .unsealed);
    try std.testing.expect(gfx.queryBufferState(alloc_buf) == .alloc);
    try std.testing.expect(gfx.queryBufferState(failed_buf) == .failed);
    try std.testing.expect(gfx.queryBufferState(dead_buf) == .invalid);
    try std.testing.expect(gfx.queryImageState(valid_img) == .valid);
    try std.testing.expect(gfx.queryImageState(unsealed_img) == .unsealed);
    try std.testing.expect(gfx.queryImageState(alloc_img) == .alloc);
    try std.testing.expect(gfx.queryImageState(failed_img) == .failed);
    try std.testing.expect(gfx.queryImageState(dead_img) == .invalid);
    common.resetLogItems();

    // sg_write_buffer_transient() requires VALID state
    const wbt_bufs = [_]gfx.Buffer{ unsealed_buf, alloc_buf, failed_buf };
    for (wbt_bufs) |buf| {
        gfx.writeBufferTransient(.{ .src = .{ .data = data_range }, .dst = .{ .buffer = buf } });
        try std.testing.expect(common.log_items[0] == .write_buffer_transient_buffer_valid);
        try std.testing.expect(common.num_log_called == 1);
        common.resetLogItems();
    }
    gfx.writeBufferTransient(.{ .src = .{ .data = data_range }, .dst = .{ .buffer = dead_buf } });
    try std.testing.expect(common.log_items[0] == .write_buffer_transient_buffer_alive);
    try std.testing.expect(common.num_log_called == 1);
    common.resetLogItems();

    // sg_write_buffer_unsealed() requires UNSEALED state
    const wbu_bufs = [_]gfx.Buffer{ valid_buf, alloc_buf, failed_buf };
    for (wbu_bufs) |buf| {
        gfx.writeBufferUnsealed(.{ .src = .{ .data = data_range }, .dst = .{ .buffer = buf } });
        try std.testing.expect(common.log_items[0] == .write_buffer_unsealed_buffer_unsealed);
        try std.testing.expect(common.num_log_called == 1);
        common.resetLogItems();
    }
    gfx.writeBufferUnsealed(.{ .src = .{ .data = data_range }, .dst = .{ .buffer = dead_buf } });
    try std.testing.expect(common.log_items[0] == .write_buffer_unsealed_buffer_alive);
    try std.testing.expect(common.num_log_called == 1);
    common.resetLogItems();

    // sg_write_image_transient() requires VALID state
    const wit_imgs = [_]gfx.Image{ unsealed_img, alloc_img, failed_img };
    for (wit_imgs) |img| {
        gfx.writeImageTransient(.{ .src = .{ .data = data_range }, .dst = .{ .image = img } });
        try std.testing.expect(common.log_items[0] == .write_image_transient_image_valid);
        try std.testing.expect(common.num_log_called == 1);
        common.resetLogItems();
    }
    gfx.writeImageTransient(.{ .src = .{ .data = data_range }, .dst = .{ .image = dead_img } });
    try std.testing.expect(common.log_items[0] == .write_image_transient_image_alive);
    try std.testing.expect(common.num_log_called == 1);
    common.resetLogItems();

    // sg_write_image_unsealed() requires UNSEALED state
    const wiu_imgs = [_]gfx.Image{ valid_img, alloc_img, failed_img };
    for (wiu_imgs) |img| {
        gfx.writeImageUnsealed(.{ .src = .{ .data = data_range }, .dst = .{ .image = img } });
        try std.testing.expect(common.log_items[0] == .write_image_unsealed_image_unsealed);
        try std.testing.expect(common.num_log_called == 1);
        common.resetLogItems();
    }
    gfx.writeImageUnsealed(.{ .src = .{ .data = data_range }, .dst = .{ .image = dead_img } });
    try std.testing.expect(common.log_items[0] == .write_image_unsealed_image_alive);
    try std.testing.expect(common.num_log_called == 1);
    common.resetLogItems();

    // and the resources in the right state can be written
    gfx.writeBufferTransient(.{ .src = .{ .data = data_range }, .dst = .{ .buffer = valid_buf } });
    gfx.writeBufferUnsealed(.{ .src = .{ .data = data_range }, .dst = .{ .buffer = unsealed_buf } });
    gfx.writeImageTransient(.{ .src = .{ .data = data_range }, .dst = .{ .image = valid_img } });
    gfx.writeImageUnsealed(.{ .src = .{ .data = data_range }, .dst = .{ .image = unsealed_img } });
    try std.testing.expect(common.num_log_called == 0);
}

// ---------------------------------------------------------------- tests

test "max_writable_storagebuffer_bindings_per_stage_cs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_buffer.stage = .compute;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_computestage_storagebuffers);
}

test "max_readonly_storagebuffer_bindings_per_stage_cs" {
    common.setup(.{});
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_buffer.stage = .compute;
        desc.views[i].storage_buffer.readonly = true;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_computestage_storagebuffers);
}

test "max_storageimage_bindings_per_stage_vs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_image.stage = .vertex;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_vertexstage_storageimages);
}

test "max_storageimage_bindings_per_stage_fs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_image.stage = .fragment;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_fragmentstage_storageimages);
}

test "max_storageimage_bindings_per_stage_cs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_image.stage = .compute;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_computestage_storageimages);
}

test "max_texturesamplerpairs_per_stage_vs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.texture_sampler_pairs[i].stage = .vertex;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_vertexstage_texturesamplerpairs);
}

test "max_texturesamplerpairs_per_stage_fs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.texture_sampler_pairs[i].stage = .fragment;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_fragmentstage_texturesamplerpairs);
}

test "max_texturesamplerpairs_per_stage_cs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.texture_sampler_pairs[i].stage = .compute;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .shaderdesc_too_many_computestage_texturesamplerpairs);
}

test "max_pass_attachments" {
    common.setup(.{});
    defer gfx.shutdown();
    var pass: gfx.Pass = .{};
    for (0..gfx.max_color_attachments) |i| {
        const color_img = gfx.makeImage(.{ .usage = .{ .color_attachment = true }, .width = 64, .height = 64, .sample_count = 4 });
        const resolve_img = gfx.makeImage(.{ .usage = .{ .resolve_attachment = true }, .width = 64, .height = 64 });
        pass.attachments.colors[i] = gfx.makeView(.{ .color_attachment = .{ .image = color_img } });
        pass.attachments.resolves[i] = gfx.makeView(.{ .resolve_attachment = .{ .image = resolve_img } });
    }
    gfx.beginPass(pass);
    try std.testing.expect(common.log_items[0] == .beginpass_too_many_color_attachments);
    try std.testing.expect(common.log_items[1] == .beginpass_too_many_resolve_attachments);
    gfx.endPass();
    gfx.commit();
}

// write-transient deferred-validation tests

// missing sg_write_buffer_transient() must be reported at sg_draw() time,
// not at sg_apply_bindings() time
test "draw_write_buffer_transient_missing" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = createWriteTransientTestBuffer();
    const pip = createWriteTransientTestPipeline();
    gfx.beginPass(testPass());
    gfx.applyPipeline(pip);
    gfx.applyBindings(vertexBindings(buf));
    common.resetLogItems();
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.log_items[0] == .validate_draw_write_buffer_transient_missing);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

// write -> bind -> draw is the correct sequence and must not error
test "draw_write_buffer_transient_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = createWriteTransientTestBuffer();
    const pip = createWriteTransientTestPipeline();
    gfx.beginPass(testPass());
    const data = std.mem.zeroes([8]f32);
    gfx.writeBufferTransient(.{
        .src = .{ .data = gfx.Range.fromSlice(f32, &data) },
        .dst = .{ .buffer = buf },
        .size = @sizeOf(@TypeOf(data)),
    });
    gfx.applyPipeline(pip);
    gfx.applyBindings(vertexBindings(buf));
    common.resetLogItems();
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.num_log_called == 0);
    gfx.endPass();
    gfx.commit();
}

// regression test: sg_apply_pipeline() must reset the write_transient_missing
// flags so an apply_pipeline -> draw sequence (bindings skipped) only reports
// the real REQUIRED_BINDINGS_OR_UNIFORMS_MISSING error and doesn't leak a
// stale flag from an earlier sg_apply_bindings()
test "apply_pipeline_resets_write_transient_flag" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = createWriteTransientTestBuffer();
    const pip = createWriteTransientTestPipeline();
    gfx.beginPass(testPass());
    // set the stale flag by binding an unwritten write_transient buffer
    gfx.applyPipeline(pip);
    gfx.applyBindings(vertexBindings(buf));
    // fresh apply_pipeline must clear the flag
    gfx.applyPipeline(pip);
    common.resetLogItems();
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.log_items[0] == .validate_draw_required_bindings_or_uniforms_missing);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

// missing sg_write_image_transient() must be reported at sg_draw() time,
// not at sg_apply_bindings() time
test "draw_write_image_transient_missing" {
    common.setup(.{});
    defer gfx.shutdown();
    const s = createWriteTransientImageSetup();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.pip);
    gfx.applyBindings(imageSetupBindings(s));
    common.resetLogItems();
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.log_items[0] == .validate_draw_write_image_transient_missing);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

// write -> bind -> draw for a write_transient image must not error
test "draw_write_image_transient_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const s = createWriteTransientImageSetup();
    gfx.beginPass(testPass());
    const pixels = std.mem.zeroes([8 * 8]u32);
    gfx.writeImageTransient(.{
        .src = .{
            .data = gfx.Range.fromSlice(u32, &pixels),
            .bytes_per_row = 8 * 4,
            .bytes_per_slice = 8 * 8 * 4,
        },
        .dst = .{ .image = s.img },
        .size = .{ .width = 8, .height = 8, .num_slices = 1 },
    });
    gfx.applyPipeline(s.pip);
    gfx.applyBindings(imageSetupBindings(s));
    common.resetLogItems();
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.num_log_called == 0);
    gfx.endPass();
    gfx.commit();
}

// multiple sg_write_buffer_transient() calls are allowed until the buffer is used for the first time in a frame
test "write_buffer_transient_multiple_before_bind" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = createWriteTransientTestBuffer();
    const pip = createWriteTransientTestPipeline();
    const data = std.mem.zeroes([8]f32);
    const range = gfx.Range.fromSlice(f32, &data);
    for (0..2) |_| {
        common.resetLogItems();
        gfx.beginPass(testPass());
        gfx.writeBufferTransient(.{ .src = .{ .data = range }, .dst = .{ .buffer = buf, .offset = 0 } });
        gfx.writeBufferTransient(.{ .src = .{ .data = range }, .dst = .{ .buffer = buf, .offset = 32 } });
        gfx.writeBufferTransient(.{ .src = .{ .data = range }, .dst = .{ .buffer = buf, .offset = 64 } });
        try std.testing.expect(common.num_log_called == 0);
        gfx.applyPipeline(pip);
        gfx.applyBindings(vertexBindings(buf));
        gfx.draw(0, 3, 1);
        try std.testing.expect(common.num_log_called == 0);
        gfx.endPass();
        gfx.commit();
    }
}

// sg_write_buffer_transient() after the buffer has been bound in the same frame is an error, but ok again in the next frame
test "write_buffer_transient_after_bind" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = createWriteTransientTestBuffer();
    const pip = createWriteTransientTestPipeline();
    const data = std.mem.zeroes([8]f32);
    const wr: gfx.WriteBufferDesc = .{ .src = .{ .data = gfx.Range.fromSlice(f32, &data) }, .dst = .{ .buffer = buf } };
    gfx.beginPass(testPass());
    gfx.writeBufferTransient(wr);
    gfx.applyPipeline(pip);
    gfx.applyBindings(vertexBindings(buf));
    common.resetLogItems();
    gfx.writeBufferTransient(wr);
    try std.testing.expect(common.log_items[0] == .validate_writebuffertransient_write_before_bind);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
    common.resetLogItems();
    gfx.writeBufferTransient(wr);
    try std.testing.expect(common.num_log_called == 0);
}

// multiple copies from a write-transient buffer are allowed, but not interleaved with sg_write_buffer_transient()
test "write_buffer_transient_vs_copy" {
    common.setup(.{});
    defer gfx.shutdown();
    setCopyBufferToImageFeatures(true, true, false);
    const src = gfx.makeBuffer(.{
        .usage = .{ .vertex_buffer = true, .write_transient = true, .copy_src = true },
        .size = 1024,
    });
    const dst = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .copy_dst = true }, .size = 1024 });
    const img = createCopyDstImage(16, 16);
    try std.testing.expect(gfx.queryBufferState(src) == .valid);
    try std.testing.expect(gfx.queryBufferState(dst) == .valid);
    try std.testing.expect(gfx.queryImageState(img) == .valid);
    const data = std.mem.zeroes([64]u8);
    const wr: gfx.WriteBufferDesc = .{ .src = .{ .data = gfx.Range.fromSlice(u8, &data) }, .dst = .{ .buffer = src } };
    for (0..2) |_| {
        common.resetLogItems();
        gfx.writeBufferTransient(wr);
        gfx.writeBufferTransient(wr);
        // any mix of copies to buffers and images
        gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dst }, .size = 64 });
        gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = img } });
        gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dst }, .size = 32 });
        try std.testing.expect(common.num_log_called == 0);
        // a write after the first copy is an error
        gfx.writeBufferTransient(wr);
        try std.testing.expect(common.log_items[0] == .validate_writebuffertransient_write_before_copy);
        try std.testing.expect(common.log_items[1] == .validation_failed);
        try std.testing.expect(common.num_log_called == 2);
        // ...and more copies are still ok
        common.resetLogItems();
        gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dst }, .size = 16 });
        try std.testing.expect(common.num_log_called == 0);
        gfx.commit();
    }
}

// the copy-before-write rule also applies when the first copy goes to an image
test "write_buffer_transient_after_copy_to_image" {
    common.setup(.{});
    defer gfx.shutdown();
    setCopyBufferToImageFeatures(true, true, false);
    const src = gfx.makeBuffer(.{
        .usage = .{ .vertex_buffer = true, .write_transient = true, .copy_src = true },
        .size = 1024,
    });
    const img = createCopyDstImage(16, 16);
    const data = std.mem.zeroes([64]u8);
    const wr: gfx.WriteBufferDesc = .{ .src = .{ .data = gfx.Range.fromSlice(u8, &data) }, .dst = .{ .buffer = src } };
    gfx.writeBufferTransient(wr);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = img } });
    try std.testing.expect(common.num_log_called == 0);
    gfx.writeBufferTransient(wr);
    try std.testing.expect(common.log_items[0] == .validate_writebuffertransient_write_before_copy);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
}

// same rules for write-transient images: multiple writes before first bind, none after
test "write_image_transient_multiple_before_bind" {
    common.setup(.{});
    defer gfx.shutdown();
    const s = createWriteTransientImageSetup();
    const pixels = std.mem.zeroes([8 * 4]u32);
    // write the upper and lower half of the 8x8 image separately
    const wr_top: gfx.WriteImageDesc = .{
        .src = .{ .data = gfx.Range.fromSlice(u32, &pixels), .bytes_per_row = 8 * 4, .bytes_per_slice = 8 * 4 * 4 },
        .dst = .{ .image = s.img, .y = 0 },
        .size = .{ .width = 8, .height = 4, .num_slices = 1 },
    };
    var wr_bottom = wr_top;
    wr_bottom.dst.y = 4;
    for (0..2) |_| {
        common.resetLogItems();
        gfx.beginPass(testPass());
        gfx.writeImageTransient(wr_top);
        gfx.writeImageTransient(wr_bottom);
        gfx.writeImageTransient(wr_top);
        try std.testing.expect(common.num_log_called == 0);
        gfx.applyPipeline(s.pip);
        gfx.applyBindings(imageSetupBindings(s));
        gfx.draw(0, 3, 1);
        try std.testing.expect(common.num_log_called == 0);
        // write after bind is an error
        gfx.writeImageTransient(wr_bottom);
        try std.testing.expect(common.log_items[0] == .validate_writeimagetransient_write_before_bind);
        try std.testing.expect(common.log_items[1] == .validation_failed);
        try std.testing.expect(common.num_log_called == 2);
        gfx.endPass();
        gfx.commit();
    }
}

// multiple sg_write_buffer_unsealed() calls are allowed while the buffer is unsealed, but not after sg_seal_buffer()
test "write_buffer_unsealed_only_while_unsealed" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_unsealed = true }, .size = 128 });
    try std.testing.expect(gfx.queryBufferState(buf) == .unsealed);
    const data = std.mem.zeroes([64]u8);
    const range = gfx.Range.fromSlice(u8, &data);
    gfx.writeBufferUnsealed(.{ .src = .{ .data = range }, .dst = .{ .buffer = buf, .offset = 0 } });
    gfx.writeBufferUnsealed(.{ .src = .{ .data = range }, .dst = .{ .buffer = buf, .offset = 64 } });
    try std.testing.expect(common.num_log_called == 0);
    try std.testing.expect(gfx.queryBufferState(buf) == .unsealed);
    gfx.sealBuffer(buf);
    try std.testing.expect(gfx.queryBufferState(buf) == .valid);
    try std.testing.expect(common.num_log_called == 0);
    gfx.writeBufferUnsealed(.{ .src = .{ .data = range }, .dst = .{ .buffer = buf } });
    try std.testing.expect(common.log_items[0] == .write_buffer_unsealed_buffer_unsealed);
    try std.testing.expect(common.num_log_called == 1);
}

test "write_image_dst_range_with_default_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 8,
        .height = 8,
        .pixel_format = .rgba8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const pixels = std.mem.zeroes([8 * 8]u32);
    const range = gfx.Range.fromSlice(u32, &pixels);

    // a destination offset at the edge of the miplevel defaults the write size to zero
    gfx.writeImageUnsealed(.{ .src = .{ .data = range }, .dst = .{ .image = img, .x = 8 } });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_width);
    try std.testing.expect(common.log_items[1] == .validate_writeimage_dst_x_range);
    try std.testing.expect(common.log_items[2] == .validation_failed);
    try std.testing.expect(common.num_log_called == 3);
    common.resetLogItems();
    gfx.writeImageUnsealed(.{ .src = .{ .data = range }, .dst = .{ .image = img, .y = 8 } });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_height);
    try std.testing.expect(common.log_items[1] == .validate_writeimage_dst_y_range);
    try std.testing.expect(common.log_items[2] == .validation_failed);
    try std.testing.expect(common.num_log_called == 3);
    common.resetLogItems();
    gfx.writeImageUnsealed(.{ .src = .{ .data = range }, .dst = .{ .image = img, .slice = 1 } });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_numslices);
    try std.testing.expect(common.log_items[1] == .validate_writeimage_dst_slice_range);
    try std.testing.expect(common.log_items[2] == .validation_failed);
    try std.testing.expect(common.num_log_called == 3);
    common.resetLogItems();

    // negative bytes-per-row must be rejected by validation and not assert in the bytes-per-slice multiple check
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = -32, .bytes_per_slice = 256 },
        .dst = .{ .image = img },
    });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_bytesperrow);
    try std.testing.expect(common.log_items[1] == .validate_writeimage_bytesperslice);
    try std.testing.expect(common.log_items[2] == .validation_failed);
    try std.testing.expect(common.num_log_called == 3);
    common.resetLogItems();

    // the default write size covers the rest of the miplevel
    gfx.writeImageUnsealed(.{ .src = .{ .data = range }, .dst = .{ .image = img, .x = 4, .y = 4 } });
    try std.testing.expect(common.num_log_called == 0);
}

test "write_image_bytes_per_row_too_small" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 16,
        .height = 16,
        .pixel_format = .rgba8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const pixels = std.mem.zeroes([16 * 16]u32);
    const range = gfx.Range.fromSlice(u32, &pixels);

    // 16 pixel wide write needs at least 64 bytes per row
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 32, .bytes_per_slice = 32 * 16 },
        .dst = .{ .image = img },
        .size = .{ .width = 16, .height = 16 },
    });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_bytesperrow_too_small);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    // ...but a 32 byte row pitch is enough for an 8 pixel wide write
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 32, .bytes_per_slice = 32 * 16 },
        .dst = .{ .image = img },
        .size = .{ .width = 8, .height = 16 },
    });
    try std.testing.expect(common.num_log_called == 0);
}

test "write_image_bytes_per_slice_too_small" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 16,
        .height = 16,
        .pixel_format = .rgba8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const pixels = std.mem.zeroes([16 * 16]u32);
    const range = gfx.Range.fromSlice(u32, &pixels);

    // 16 rows with 64 bytes per row need at least 1024 bytes per slice
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 64, .bytes_per_slice = 64 * 8 },
        .dst = .{ .image = img },
        .size = .{ .width = 16, .height = 16 },
    });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_bytesperslice_too_small);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    // ...but 512 bytes per slice are enough for an 8 row write
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 64, .bytes_per_slice = 64 * 8 },
        .dst = .{ .image = img },
        .size = .{ .width = 16, .height = 8 },
    });
    try std.testing.expect(common.num_log_called == 0);
}

// tiny pitches must not slip through the read-overflow check and cause the
// backend to read past the end of the source data
test "write_image_tiny_pitches_rejected" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .write_transient = true },
        .width = 8,
        .height = 8,
        .pixel_format = .rgba8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .valid);
    const pixel: u32 = 0;
    gfx.writeImageTransient(.{
        .src = .{ .data = gfx.Range.fromValue(u32, &pixel), .bytes_per_row = 4, .bytes_per_slice = 4 },
        .dst = .{ .image = img },
        .size = .{ .width = 8, .height = 8 },
    });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_bytesperrow_too_small);
    try std.testing.expect(common.log_items[1] == .validate_writeimage_bytesperslice_too_small);
    try std.testing.expect(common.log_items[2] == .validation_failed);
    try std.testing.expect(common.num_log_called == 3);
}

test "write_image_compressed_pitches" {
    common.setup(.{});
    defer gfx.shutdown();
    // 16x16 BC1: 4x4 blocks of 8 bytes, 32 byte row pitch, 128 byte slice pitch
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 16,
        .height = 16,
        .pixel_format = .bc1_rgba,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const blocks = std.mem.zeroes([128]u8);
    const range = gfx.Range.fromSlice(u8, &blocks);

    // a block-aligned row pitch smaller than 4 blocks is too small
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 16, .bytes_per_slice = 64 },
        .dst = .{ .image = img },
        .size = .{ .width = 16, .height = 16 },
    });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_bytesperrow_too_small);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    // the slice pitch must cover 4 block-rows, not 16 pixel rows
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 32, .bytes_per_slice = 64 },
        .dst = .{ .image = img },
        .size = .{ .width = 16, .height = 16 },
    });
    try std.testing.expect(common.log_items[0] == .validate_writeimage_bytesperslice_too_small);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    gfx.writeImageUnsealed(.{
        .src = .{ .data = range, .bytes_per_row = 32, .bytes_per_slice = 128 },
        .dst = .{ .image = img },
        .size = .{ .width = 16, .height = 16 },
    });
    try std.testing.expect(common.num_log_called == 0);
}

test "write_image_compressed_small_mips" {
    common.setup(.{});
    defer gfx.shutdown();
    // 24x24 BC1 with miplevels 24, 12, 6, 3, 1
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 24,
        .height = 24,
        .num_mipmaps = 5,
        .pixel_format = .bc1_rgba,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const blocks = std.mem.zeroes([512]u8);
    const range = gfx.Range.fromSlice(u8, &blocks);

    // default-sized writes into miplevels smaller than one block are allowed
    gfx.writeImageUnsealed(.{ .src = .{ .data = range }, .dst = .{ .image = img, .mip_level = 3 } });
    gfx.writeImageUnsealed(.{ .src = .{ .data = range }, .dst = .{ .image = img, .mip_level = 4 } });
    try std.testing.expect(common.num_log_called == 0);

    // a non-block-multiple size is allowed when the write reaches the miplevel edge (6x6 miplevel)
    var desc: gfx.WriteImageDesc = .{
        .src = .{ .data = range },
        .dst = .{ .image = img, .mip_level = 2, .x = 4, .y = 4 },
        .size = .{ .width = 2, .height = 2 },
    };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.num_log_called == 0);
    desc.dst.x = 0;
    desc.dst.y = 0;
    desc.size = .{ .width = 6, .height = 6 };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.num_log_called == 0);

    // ...but not when the write ends inside the miplevel
    desc.size = .{ .width = 2, .height = 6 };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.log_items[0] == .validate_writeimage_width_multiple);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    desc.size = .{ .width = 6, .height = 2 };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.log_items[0] == .validate_writeimage_height_multiple);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();

    // the same rules in the 3x3 miplevel
    desc.dst.mip_level = 3;
    desc.size = .{ .width = 3, .height = 3 };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.num_log_called == 0);
    desc.size = .{ .width = 2, .height = 2 };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.log_items[0] == .validate_writeimage_width_multiple);
    try std.testing.expect(common.log_items[1] == .validate_writeimage_height_multiple);
    try std.testing.expect(common.log_items[2] == .validation_failed);
    try std.testing.expect(common.num_log_called == 3);
}

test "write_image_compressed_dst_alignment" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 16,
        .height = 16,
        .pixel_format = .bc1_rgba,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const blocks = std.mem.zeroes([128]u8);

    // block-aligned destination offsets are fine
    var desc: gfx.WriteImageDesc = .{
        .src = .{ .data = gfx.Range.fromSlice(u8, &blocks) },
        .dst = .{ .image = img, .x = 4, .y = 8 },
        .size = .{ .width = 4, .height = 4 },
    };
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.num_log_called == 0);

    // unaligned destination offsets are rejected, even when the write reaches the miplevel edge
    desc.dst.x = 2;
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.log_items[0] == .validate_writeimage_dst_x_alignment);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    desc.dst.x = 4;
    desc.dst.y = 6;
    desc.size.height = 10;
    gfx.writeImageUnsealed(desc);
    try std.testing.expect(common.log_items[0] == .validate_writeimage_dst_y_alignment);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
}

test "write_image_uncompressed_unaligned_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    // the block alignment rules don't apply to uncompressed formats
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 16,
        .height = 16,
        .pixel_format = .rgba8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const pixels = std.mem.zeroes([16 * 16]u32);
    gfx.writeImageUnsealed(.{
        .src = .{ .data = gfx.Range.fromSlice(u32, &pixels) },
        .dst = .{ .image = img, .x = 3, .y = 5 },
        .size = .{ .width = 7, .height = 9 },
    });
    try std.testing.expect(common.num_log_called == 0);
}

// a buffer without usage.write_unsealed is never in UNSEALED state, so this is
// rejected by the resource state check before the usage validation is reached
test "write_buffer_unsealed_wrong_usage" {
    common.setup(.{});
    defer gfx.shutdown();
    const init_data = std.mem.zeroes([128]u8);
    const buf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true }, .data = gfx.Range.fromSlice(u8, &init_data) });
    try std.testing.expect(gfx.queryBufferState(buf) == .valid);
    const data = std.mem.zeroes([64]u8);
    gfx.writeBufferUnsealed(.{ .src = .{ .data = gfx.Range.fromSlice(u8, &data) }, .dst = .{ .buffer = buf } });
    try std.testing.expect(common.log_items[0] == .write_buffer_unsealed_buffer_unsealed);
    try std.testing.expect(common.num_log_called == 1);
}

// same for images, writing is done per region
test "write_image_unsealed_only_while_unsealed" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .write_unsealed = true },
        .width = 8,
        .height = 8,
        .pixel_format = .rgba8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    const pixels = std.mem.zeroes([8 * 4]u32);
    const wr_top: gfx.WriteImageDesc = .{
        .src = .{ .data = gfx.Range.fromSlice(u32, &pixels), .bytes_per_row = 8 * 4, .bytes_per_slice = 8 * 4 * 4 },
        .dst = .{ .image = img, .y = 0 },
        .size = .{ .width = 8, .height = 4, .num_slices = 1 },
    };
    var wr_bottom = wr_top;
    wr_bottom.dst.y = 4;
    gfx.writeImageUnsealed(wr_top);
    gfx.writeImageUnsealed(wr_bottom);
    try std.testing.expect(common.num_log_called == 0);
    try std.testing.expect(gfx.queryImageState(img) == .unsealed);
    gfx.sealImage(img);
    try std.testing.expect(gfx.queryImageState(img) == .valid);
    try std.testing.expect(common.num_log_called == 0);
    gfx.writeImageUnsealed(wr_top);
    try std.testing.expect(common.log_items[0] == .write_image_unsealed_image_unsealed);
    try std.testing.expect(common.num_log_called == 1);
}

// write functions check the resource state outside the validation layer, and before
// the write desc defaults are resolved (which require a valid image pixel format)
test "write_resource_state" {
    common.setup(.{});
    defer gfx.shutdown();
    try testWriteResourceState();
}

// ...and the same must happen with validation disabled
test "write_resource_state_no_validation" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    try testWriteResourceState();
}

// read/write storage buffers in fragment shaders

test "sbuf_rw_setup_valid" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    try std.testing.expect(gfx.queryBufferState(s.buf) == .valid);
    try std.testing.expect(gfx.queryViewState(s.view) == .valid);
    try std.testing.expect(gfx.queryViewState(s.view2) == .valid);
    try std.testing.expect(gfx.queryBufferState(s.other_buf) == .valid);
    try std.testing.expect(gfx.queryViewState(s.other_view) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.fs_rw_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.fs_ro_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.vs_ro_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.fs_rw_ro_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.vbuf_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.ibuf_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.cs_rw_pip) == .valid);
    try std.testing.expect(gfx.queryPipelineState(s.cs_ro_pip) == .valid);
    try std.testing.expect(common.num_log_called == 0);
}

test "make_shader_storagebuffer_vertex_readwrite" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const shd = createSbufStageShader(.vertex, false);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(common.log_items[0] == .validate_shaderdesc_view_storagebuffer_vertexshader_readwrite);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
}

test "make_shader_storagebuffer_fragment_readwrite_vertex_readonly_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const shd = createSbufRenderShader(.fragment, false, .vertex, true);
    try std.testing.expect(gfx.queryShaderState(shd) == .valid);
    try std.testing.expect(common.num_log_called == 0);
}

test "make_pipeline_storagebuffer_fragment_readwrite_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const pip = gfx.makePipeline(.{
        .shader = createSbufRenderShader(.fragment, false, .vertex, true),
    });
    try std.testing.expect(gfx.queryPipelineState(pip) == .valid);
    try std.testing.expect(common.num_log_called == 0);
}

// the shader validation already rejects vertex stage read/write storage buffers,
// so skip the shader validation to reach the pipeline check
test "make_pipeline_storagebuffer_vertex_readwrite" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    core.state().desc.disable_validation = true;
    const shd = createSbufStageShader(.vertex, false);
    core.state().desc.disable_validation = false;
    try std.testing.expect(gfx.queryShaderState(shd) == .valid);
    const pip = gfx.makePipeline(.{ .shader = shd });
    try std.testing.expect(gfx.queryPipelineState(pip) == .failed);
    try std.testing.expect(common.log_items[0] == .validate_pipelinedesc_shader_readonly_storagebuffers);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
}

test "apply_bindings_sbuf_readwrite_then_vertex_buffer" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.applyPipeline(s.vbuf_pip);
    common.resetLogItems();
    gfx.applyBindings(vertexBindings(s.buf));
    try std.testing.expect(common.log_items[0] == .validate_abnd_vbuf_vs_sbview_readwrite);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

test "apply_bindings_sbuf_readwrite_then_index_buffer" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.applyPipeline(s.ibuf_pip);
    common.resetLogItems();
    gfx.applyBindings(indexBindings(s.buf));
    try std.testing.expect(common.log_items[0] == .validate_abnd_ibuf_vs_sbview_readwrite);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

test "apply_bindings_sbuf_readwrite_then_readonly" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.applyPipeline(s.vs_ro_pip);
    common.resetLogItems();
    gfx.applyBindings(viewBindings(s.view));
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readonly_vs_readwrite);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

test "apply_bindings_sbuf_readonly_then_readwrite" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.fs_ro_pip);
    gfx.applyBindings(viewBindings(s.view));
    common.resetLogItems();
    applySbufRw(&s, s.view);
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readwrite_vs_read);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

test "apply_bindings_vertex_buffer_then_sbuf_readwrite" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.vbuf_pip);
    gfx.applyBindings(vertexBindings(s.buf));
    common.resetLogItems();
    applySbufRw(&s, s.view);
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readwrite_vs_read);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

test "apply_bindings_index_buffer_then_sbuf_readwrite" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.ibuf_pip);
    gfx.applyBindings(indexBindings(s.buf));
    common.resetLogItems();
    applySbufRw(&s, s.view);
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readwrite_vs_read);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

// the hazard check must look at the buffer, not the view
test "apply_bindings_sbuf_readwrite_then_readonly_other_view" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.applyPipeline(s.fs_ro_pip);
    common.resetLogItems();
    gfx.applyBindings(viewBindings(s.view2));
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readonly_vs_readwrite);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

// read/write and readonly binding of the same buffer in one sg_apply_bindings()
test "apply_bindings_sbuf_readwrite_and_readonly_same_call" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.fs_rw_ro_pip);
    common.resetLogItems();
    gfx.applyBindings(views01Bindings(s.view, s.view2));
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readonly_vs_readwrite);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}

// different buffers in the read/write and readonly slots are ok
test "apply_bindings_sbuf_readwrite_and_readonly_different_buffers_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.fs_rw_ro_pip);
    gfx.applyBindings(views01Bindings(s.view, s.other_view));
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.num_log_called == 0);
    gfx.endPass();
    gfx.commit();
}

// several draws may write the same buffer in one pass
test "apply_bindings_sbuf_readwrite_twice_same_pass_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.draw(0, 3, 1);
    applySbufRw(&s, s.view2);
    gfx.draw(0, 3, 1);
    try std.testing.expect(common.num_log_called == 0);
    gfx.endPass();
    gfx.commit();
}

// write in one pass and read in the next pass (and the other way around)
test "apply_bindings_sbuf_readwrite_and_read_in_different_passes_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.vs_ro_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.draw(0, 3, 1);
    gfx.applyPipeline(s.vbuf_pip);
    gfx.applyBindings(vertexBindings(s.buf));
    gfx.draw(0, 3, 1);
    gfx.applyPipeline(s.ibuf_pip);
    gfx.applyBindings(indexBindings(s.buf));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try std.testing.expect(common.num_log_called == 0);
    gfx.commit();
}

// the pass stamps must also not leak into the next frame
test "apply_bindings_sbuf_readwrite_and_read_in_different_frames_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.commit();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.fs_ro_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.commit();
    try std.testing.expect(common.num_log_called == 0);
}

// compute passes don't have the render pass hazard rules
test "apply_bindings_compute_sbuf_readwrite_then_readonly_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(s.cs_rw_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.dispatch(1, 1, 1);
    gfx.applyPipeline(s.cs_ro_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.dispatch(1, 1, 1);
    gfx.applyPipeline(s.cs_rw_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
    try std.testing.expect(common.num_log_called == 0);
    gfx.commit();
}

// a compute pass write followed by a render pass read (and the other way around)
test "apply_bindings_compute_and_render_pass_ok" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(s.cs_rw_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.vbuf_pip);
    gfx.applyBindings(vertexBindings(s.buf));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(s.cs_ro_pip);
    gfx.applyBindings(viewBindings(s.view));
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
    gfx.beginPass(testPass());
    applySbufRw(&s, s.view);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try std.testing.expect(common.num_log_called == 0);
    gfx.commit();
}

// write_transient storage buffers cannot be bound as read/write
test "apply_bindings_sbuf_readwrite_write_transient" {
    setupWithCompute(.{});
    defer gfx.shutdown();
    const s = createSbufRwSetup();
    const buf = gfx.makeBuffer(.{
        .usage = .{ .storage_buffer = true, .write_transient = true },
        .size = 64,
    });
    const view = gfx.makeView(.{ .storage_buffer = .{ .buffer = buf } });
    try std.testing.expect(gfx.queryViewState(view) == .valid);
    gfx.beginPass(testPass());
    gfx.applyPipeline(s.fs_rw_pip);
    common.resetLogItems();
    gfx.applyBindings(viewBindings(view));
    try std.testing.expect(common.log_items[0] == .validate_abnd_sbview_readwrite_vs_writetransient);
    try std.testing.expect(common.log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    gfx.endPass();
    gfx.commit();
}
