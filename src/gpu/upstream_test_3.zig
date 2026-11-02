//! Tests ported from upstream sokol tests/functional/sokol_gfx_test.c (part 3).
const std = @import("std");
const common = @import("upstream_test_common.zig");
const gfx = common.gfx;
const core = common.core;

const log_items = &common.log_items;

test "make_buffer_validate_start_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([32]u32);
    const buf = gfx.makeBuffer(.{
        ._start_canary = 1234,
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_canary);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_validate_end_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([32]u32);
    const buf = gfx.makeBuffer(.{
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
        ._end_canary = 1234,
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_canary);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_validate_immutable_nodata" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = gfx.makeBuffer(.{});
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_nonzero_size);
    try std.testing.expect(log_items[1] == .validate_bufferdesc_expect_data);
    try std.testing.expect(log_items[2] == .validation_failed);
}

test "make_buffer_validate_size_mismatch" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .size = 15 * @sizeOf(u32),
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_matching_data_size);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_validate_data_ptr_but_no_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .data = .{ .ptr = &data },
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_nonzero_size);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_validate_data_ptr_but_no_data_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .size = @sizeOf(@TypeOf(data)),
        .data = .{ .ptr = &data },
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_matching_data_size);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_validate_no_data_ptr_but_data_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .usage = .{ .copy_dst = true },
        .size = @sizeOf(@TypeOf(data)),
        .data = .{ .size = @sizeOf(@TypeOf(data)) },
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_zero_data_size);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_usage_write_transient_expect_no_data" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .usage = .{ .write_transient = true },
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_writetransient_vs_initialdata);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_usage_write_unsealed_expect_no_data" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .usage = .{ .write_unsealed = true },
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_writeunsealed_vs_initialdata);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_usage_copy_dst_expect_no_data" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .usage = .{ .copy_dst = true },
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_copydst_vs_initialdata);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_buffer_usage_staging_validation" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([16]u32);
    const buf = gfx.makeBuffer(.{
        .usage = .{ .staging_buffer = true, .vertex_buffer = true, .copy_dst = true },
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_staging_vs_vertexbuffer);
    try std.testing.expect(log_items[1] == .validate_bufferdesc_staging_vs_copydst);
    try std.testing.expect(log_items[2] == .validate_bufferdesc_staging_copysrc);
    try std.testing.expect(log_items[3] == .validate_bufferdesc_staging_vs_initialdata);
    try std.testing.expect(log_items[4] == .validate_bufferdesc_copydst_vs_initialdata);
    try std.testing.expect(log_items[5] == .validation_failed);
}

// buffers without initial data must be writable via write_unsealed, write_transient or copy_dst
test "make_buffer_validate_expect_data" {
    common.setup(.{});
    defer gfx.shutdown();
    const vbuf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true }, .size = 64 });
    try std.testing.expect(gfx.queryBufferState(vbuf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_data);
    try std.testing.expect(log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    const ibuf = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .size = 64 });
    try std.testing.expect(gfx.queryBufferState(ibuf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_data);
    try std.testing.expect(log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
    common.resetLogItems();
    // a staging buffer without write_transient can never be filled
    const sbuf = gfx.makeBuffer(.{ .usage = .{ .staging_buffer = true, .copy_src = true }, .size = 64 });
    try std.testing.expect(gfx.queryBufferState(sbuf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_expect_data);
    try std.testing.expect(log_items[1] == .validation_failed);
    try std.testing.expect(common.num_log_called == 2);
}

test "make_buffer_no_data_writable_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const unsealed = gfx.makeBuffer(.{ .usage = .{ .write_unsealed = true }, .size = 64 });
    const transient = gfx.makeBuffer(.{ .usage = .{ .write_transient = true }, .size = 64 });
    const copy_dst = gfx.makeBuffer(.{ .usage = .{ .copy_dst = true }, .size = 64 });
    const staging = gfx.makeBuffer(.{
        .usage = .{ .staging_buffer = true, .write_transient = true, .copy_src = true },
        .size = 64,
    });
    const staging_index = gfx.makeBuffer(.{
        .usage = .{ .staging_index_buffer = true, .write_transient = true, .copy_src = true },
        .size = 64,
    });
    try std.testing.expect(gfx.queryBufferState(unsealed) == .unsealed);
    try std.testing.expect(gfx.queryBufferState(transient) == .valid);
    try std.testing.expect(gfx.queryBufferState(copy_dst) == .valid);
    try std.testing.expect(gfx.queryBufferState(staging) == .valid);
    try std.testing.expect(gfx.queryBufferState(staging_index) == .valid);
    try std.testing.expect(common.num_log_called == 0);
}

// storage buffers can be initialized by compute shaders, so they don't need data
// (the storage buffer feature itself is backend-specific, so only check for the absence of EXPECT_DATA)
test "make_buffer_storage_no_data_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    _ = gfx.makeBuffer(.{ .usage = .{ .storage_buffer = true }, .size = 64 });
    for (0..common.num_log_called) |i| {
        try std.testing.expect(log_items[i] != .validate_bufferdesc_expect_data);
    }
}

test "make_buffer_storagebuffer_not_supported_and_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const data = std.mem.zeroes([10]u8);
    const buf = gfx.makeBuffer(.{
        .usage = .{ .storage_buffer = true },
        .data = gfx.Range.fromValue(@TypeOf(data), &data),
    });
    try std.testing.expect(gfx.queryBufferState(buf) == .failed);
    try std.testing.expect(log_items[0] == .validate_bufferdesc_storagebuffer_supported);
    try std.testing.expect(log_items[1] == .validate_bufferdesc_storagebuffer_size_multiple_4);
    try std.testing.expect(log_items[2] == .validation_failed);
}

test "make_image_validate_start_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const pixels = std.mem.zeroes([8][8]u32);
    var desc: gfx.ImageDesc = .{
        ._start_canary = 1234,
        .width = 8,
        .height = 8,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(pixels), &pixels);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_canary);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_validate_end_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const pixels = std.mem.zeroes([8][8]u32);
    var desc: gfx.ImageDesc = .{
        .width = 8,
        .height = 8,
        ._end_canary = 1234,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(pixels), &pixels);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_canary);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_zero_width_height" {
    common.setup(.{});
    defer gfx.shutdown();
    const pixels = std.mem.zeroes([8][8]u32);
    var desc: gfx.ImageDesc = .{
        .width = 0,
        .height = 0,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(pixels), &pixels);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_width);
    try std.testing.expect(log_items[1] == .validate_imagedesc_height);
    try std.testing.expect(log_items[2] == .validate_imagedata_data_size);
    try std.testing.expect(log_items[3] == .validation_failed);
}

test "make_image_validate_msaa_no_rt" {
    common.setup(.{});
    defer gfx.shutdown();
    const pixels = std.mem.zeroes([8][8]u32);
    var desc: gfx.ImageDesc = .{
        .width = 8,
        .height = 8,
        .sample_count = 4,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(pixels), &pixels);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_msaa_but_no_attachment);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_validate_msaa_num_mipmaps" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 64,
        .height = 64,
        .sample_count = 4,
        .num_mipmaps = 2,
    });
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_attachment_msaa_num_mipmaps);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_validate_msaa_3d_image" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .type = .@"3d",
        .width = 32,
        .height = 32,
        .num_slices = 32,
        .sample_count = 4,
    });
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_attachment_msaa_3d_image);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_validate_depth_3d_image_with_depth_format" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .depth_stencil_attachment = true },
        .type = .@"3d",
        .width = 8,
        .height = 8,
        .num_slices = 8,
        .pixel_format = .depth,
    });
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_depth_3d_image);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_validate_rt_immutable" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{
            .color_attachment = true,
            .copy_dst = true,
        },
        .width = 8,
        .height = 8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_attachment_expect_immutable);
    try std.testing.expect(log_items[1] == .validate_imagedesc_copydst_vs_attachment);
    try std.testing.expect(log_items[2] == .validation_failed);
}

test "make_image_validate_copy_dst_no_data" {
    common.setup(.{});
    defer gfx.shutdown();
    const pixels = std.mem.zeroes([8][8]u32);
    var desc: gfx.ImageDesc = .{
        .usage = .{ .copy_dst = true },
        .width = 8,
        .height = 8,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(pixels), &pixels);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedesc_writable_no_data);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_compressed_writable" {
    common.setup(.{});
    defer gfx.shutdown();
    // compressed images don't need to be immutable
    const img0 = gfx.makeImage(.{
        .usage = .{ .copy_dst = true },
        .width = 8,
        .height = 8,
        .pixel_format = .bc1_rgba,
    });
    const img1 = gfx.makeImage(.{
        .usage = .{ .write_transient = true },
        .width = 8,
        .height = 8,
        .pixel_format = .bc1_rgba,
    });
    try std.testing.expect(gfx.queryImageState(img0) == .valid);
    try std.testing.expect(gfx.queryImageState(img1) == .valid);
    try std.testing.expect(common.num_log_called == 0);
}

test "make_image_validate_nodata" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .width = 8,
        .height = 8,
    });
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedata_nodata);
    try std.testing.expect(log_items[1] == .validate_imagedata_data_size);
    try std.testing.expect(log_items[2] == .validation_failed);
}

test "make_image_validate_data_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const pixels = std.mem.zeroes([4][4]u32);
    var desc: gfx.ImageDesc = .{
        .width = 8,
        .height = 8,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(pixels), &pixels);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedata_data_size);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_image_validate_missing_mipdata" {
    common.setup(.{});
    defer gfx.shutdown();
    const mip0 = std.mem.zeroes([8][8]u32);
    const mip1 = std.mem.zeroes([4][4]u32);
    const mip2 = std.mem.zeroes([2][2]u32);
    var desc: gfx.ImageDesc = .{
        .width = 8,
        .height = 8,
        .num_mipmaps = 4,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(mip0), &mip0);
    desc.data.mip_levels[1] = gfx.Range.fromValue(@TypeOf(mip1), &mip1);
    desc.data.mip_levels[2] = gfx.Range.fromValue(@TypeOf(mip2), &mip2);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedata_nodata);
    try std.testing.expect(log_items[1] == .validate_imagedata_data_size);
    try std.testing.expect(log_items[2] == .validation_failed);
}

test "make_image_validate_wrong_mipsize" {
    common.setup(.{});
    defer gfx.shutdown();
    const mip0 = std.mem.zeroes([8][8]u32);
    const mip1 = std.mem.zeroes([4][4]u32);
    const mip2 = std.mem.zeroes([2][2]u32);
    const mip3 = std.mem.zeroes([1][1]u32);
    var desc: gfx.ImageDesc = .{
        .width = 8,
        .height = 8,
        .num_mipmaps = 4,
    };
    desc.data.mip_levels[0] = gfx.Range.fromValue(@TypeOf(mip0), &mip0);
    desc.data.mip_levels[1] = gfx.Range.fromValue(@TypeOf(mip2), &mip2);
    desc.data.mip_levels[2] = gfx.Range.fromValue(@TypeOf(mip1), &mip1);
    desc.data.mip_levels[3] = gfx.Range.fromValue(@TypeOf(mip3), &mip3);
    const img = gfx.makeImage(desc);
    try std.testing.expect(gfx.queryImageState(img) == .failed);
    try std.testing.expect(log_items[0] == .validate_imagedata_data_size);
    try std.testing.expect(log_items[1] == .validate_imagedata_data_size);
    try std.testing.expect(log_items[2] == .validation_failed);
}

test "make_sampler_validate_start_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const smp = gfx.makeSampler(.{
        ._start_canary = 1234,
    });
    try std.testing.expect(gfx.querySamplerState(smp) == .failed);
    try std.testing.expect(log_items[0] == .validate_samplerdesc_canary);
}

test "make_sampler_validate_anistropic_requires_linear_filtering" {
    common.setup(.{});
    defer gfx.shutdown();
    var smp: gfx.Sampler = undefined;

    smp = gfx.makeSampler(.{
        .max_anisotropy = 2,
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .nearest,
    });
    try std.testing.expect(gfx.querySamplerState(smp) == .failed);
    try std.testing.expect(log_items[0] == .validate_samplerdesc_anistropic_requires_linear_filtering);

    common.resetLogItems();
    smp = gfx.makeSampler(.{
        .max_anisotropy = 2,
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .nearest,
    });
    try std.testing.expect(gfx.querySamplerState(smp) == .failed);
    try std.testing.expect(log_items[0] == .validate_samplerdesc_anistropic_requires_linear_filtering);

    common.resetLogItems();
    smp = gfx.makeSampler(.{
        .max_anisotropy = 2,
        .min_filter = .nearest,
        .mag_filter = .linear,
        .mipmap_filter = .linear,
    });
    try std.testing.expect(gfx.querySamplerState(smp) == .failed);
    try std.testing.expect(log_items[0] == .validate_samplerdesc_anistropic_requires_linear_filtering);

    common.resetLogItems();
    smp = gfx.makeSampler(.{
        .max_anisotropy = 2,
        .min_filter = .linear,
        .mag_filter = .nearest,
        .mipmap_filter = .linear,
    });
    try std.testing.expect(gfx.querySamplerState(smp) == .failed);
    try std.testing.expect(log_items[0] == .validate_samplerdesc_anistropic_requires_linear_filtering);

    common.resetLogItems();
    smp = gfx.makeSampler(.{
        .max_anisotropy = 2,
        .min_filter = .linear,
        .mag_filter = .linear,
        .mipmap_filter = .linear,
    });
    try std.testing.expect(gfx.querySamplerState(smp) == .valid);
}

test "make_pipeline_depth_only" {
    common.setup(.{});
    defer gfx.shutdown();
    // a NONE color format in colors[0] selects depth-only rendering, the desc
    // defaults then force color_count to zero, which must pass validation
    var desc: gfx.PipelineDesc = .{
        .shader = common.createShader(),
        .depth = .{
            .pixel_format = .depth,
            .write_enabled = true,
            .compare = .less_equal,
        },
    };
    desc.colors[0].pixel_format = .none;
    const pip = gfx.makePipeline(desc);
    try std.testing.expect(gfx.queryPipelineState(pip) == .valid);
    try std.testing.expect(gfx.queryPipelineDesc(pip).color_count == 0);
    try std.testing.expect(common.num_log_called == 0);
}

test "make_pipeline_validate_color_count" {
    common.setup(.{});
    defer gfx.shutdown();
    const shd = common.createShader();
    var pip: gfx.Pipeline = undefined;

    // a negative color count is rejected
    pip = gfx.makePipeline(.{
        .shader = shd,
        .color_count = -1,
    });
    try std.testing.expect(gfx.queryPipelineState(pip) == .failed);
    try std.testing.expect(log_items[0] == .validate_pipelinedesc_color_count);
    try std.testing.expect(log_items[1] == .validation_failed);

    // the maximum color count is valid
    common.resetLogItems();
    pip = gfx.makePipeline(.{
        .shader = shd,
        .color_count = @intCast(gfx.max_color_attachments),
    });
    try std.testing.expect(gfx.queryPipelineState(pip) == .valid);
    try std.testing.expect(gfx.queryPipelineDesc(pip).color_count == @as(i32, @intCast(gfx.max_color_attachments)));
    try std.testing.expect(common.num_log_called == 0);

    // too many color attachments are clamped by the desc defaults, not rejected
    common.resetLogItems();
    pip = gfx.makePipeline(.{
        .shader = shd,
        .color_count = @intCast(gfx.max_color_attachments + 1),
    });
    try std.testing.expect(gfx.queryPipelineState(pip) == .valid);
    try std.testing.expect(gfx.queryPipelineDesc(pip).color_count == @as(i32, @intCast(gfx.max_color_attachments)));
    try std.testing.expect(common.num_log_called == 0);
}

test "make_view_validate_start_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const view = gfx.makeView(.{
        ._start_canary = 1234,
        .color_attachment = .{
            .image = gfx.makeImage(.{
                .usage = .{ .color_attachment = true },
                .width = 64,
                .height = 64,
            }),
        },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_canary);
}

test "make_view_validate_end_canary" {
    common.setup(.{});
    defer gfx.shutdown();
    const atts = gfx.makeView(.{
        .color_attachment = .{
            .image = gfx.makeImage(.{
                .usage = .{ .color_attachment = true },
                .width = 64,
                .height = 64,
            }),
        },
        ._end_canary = 1234,
    });
    try std.testing.expect(gfx.queryViewState(atts) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_canary);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_image" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 64,
        .height = 65,
    });
    gfx.destroyImage(img);
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = img },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_resource_alive);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_miplevel" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .width = 16,
        .height = 16,
        .num_mipmaps = 4,
    });
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = img, .mip_level = 4 },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_image_miplevel);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_face" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .type = .cube,
        .width = 64,
        .height = 64,
    });
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = img, .slice = 6 },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_image_cubemap_slice);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_array_slice" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .type = .array,
        .width = 64,
        .height = 64,
        .num_slices = 4,
    });
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = img, .slice = 5 },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_image_array_slice);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_3dslice" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .color_attachment = true },
        .type = .@"3d",
        .width = 64,
        .height = 64,
        .num_slices = 4,
    });
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = img, .slice = 5 },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_image_3d_slice);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_image_no_usage" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.makeImage(.{
        .usage = .{ .copy_dst = true },
        .width = 8,
        .height = 8,
    });
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = img },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_colorattachment_usage);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_color_inv_pixelformat" {
    common.setup(.{});
    defer gfx.shutdown();
    const img_desc: gfx.ImageDesc = .{
        .usage = .{ .color_attachment = true },
        .width = 8,
        .height = 8,
        .pixel_format = .depth,
    };
    common.resetLogItems();
    const view = gfx.makeView(.{
        .color_attachment = .{ .image = gfx.makeImage(img_desc) },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_colorattachment_pixelformat);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "make_view_validate_depth_inv_pixelformat" {
    common.setup(.{});
    defer gfx.shutdown();
    // need to explicitly use a non-depth pixel format, otherwise
    // the default depth format will be picked
    const img_desc: gfx.ImageDesc = .{
        .usage = .{ .depth_stencil_attachment = true },
        .width = 8,
        .height = 8,
        .pixel_format = .rgba8,
    };
    const view = gfx.makeView(.{
        .depth_stencil_attachment = .{ .image = gfx.makeImage(img_desc) },
    });
    try std.testing.expect(gfx.queryViewState(view) == .failed);
    try std.testing.expect(log_items[0] == .validate_viewdesc_depthstencilattachment_pixelformat);
    try std.testing.expect(log_items[1] == .validation_failed);
}

test "query_pixelformat_bytesperpixel" {
    common.setup(.{});
    defer gfx.shutdown();
    try std.testing.expect(gfx.queryPixelformat(.r8).bytes_per_pixel == 1);
    try std.testing.expect(gfx.queryPixelformat(.r8sn).bytes_per_pixel == 1);
    try std.testing.expect(gfx.queryPixelformat(.r8ui).bytes_per_pixel == 1);
    try std.testing.expect(gfx.queryPixelformat(.r8si).bytes_per_pixel == 1);
    try std.testing.expect(gfx.queryPixelformat(.r16).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.r16sn).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.r16ui).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.r16si).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.r16f).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.rg8).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.rg8sn).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.rg8ui).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.rg8si).bytes_per_pixel == 2);
    try std.testing.expect(gfx.queryPixelformat(.r32ui).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.r32si).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.r32f).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg16).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg16sn).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg16ui).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg16si).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg16f).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rgba8).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.srgb8a8).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rgba8sn).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rgba8ui).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rgba8si).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.bgra8).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rgb10a2).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg11b10f).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rgb9e5).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.rg32ui).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rg32si).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rg32f).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rgba16).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rgba16sn).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rgba16ui).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rgba16si).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rgba16f).bytes_per_pixel == 8);
    try std.testing.expect(gfx.queryPixelformat(.rgba32ui).bytes_per_pixel == 16);
    try std.testing.expect(gfx.queryPixelformat(.rgba32si).bytes_per_pixel == 16);
    try std.testing.expect(gfx.queryPixelformat(.rgba32f).bytes_per_pixel == 16);
    try std.testing.expect(gfx.queryPixelformat(.depth).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.depth_stencil).bytes_per_pixel == 4);
    try std.testing.expect(gfx.queryPixelformat(.bc1_rgba).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc2_rgba).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc3_rgba).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc4_r).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc4_rsn).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc5_rg).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc5_rgsn).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc6h_rgbf).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc6h_rgbuf).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.bc7_rgba).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.etc2_rgb8).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.etc2_rgb8a1).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.etc2_rgba8).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.eac_r11).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.eac_r11sn).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.eac_r11).bytes_per_pixel == 0);
    try std.testing.expect(gfx.queryPixelformat(.eac_r11sn).bytes_per_pixel == 0);
}

test "query_pixelformat_compressed" {
    common.setup(.{});
    defer gfx.shutdown();
    var i: u32 = @backingInt(gfx.PixelFormat.none) + 1;
    while (i < @backingInt(gfx.PixelFormat.bc1_rgba)) : (i += 1) {
        try std.testing.expect(gfx.queryPixelformat(@fromBackingInt(@intCast(i))).compressed == false);
    }
    while (i < core.num_pixel_formats) : (i += 1) {
        try std.testing.expect(gfx.queryPixelformat(@fromBackingInt(@intCast(i))).compressed == true);
    }
}

test "query_row_pitch" {
    common.setup(.{});
    defer gfx.shutdown();
    try std.testing.expect(gfx.queryRowPitch(.r8, 13, 1) == 13);
    try std.testing.expect(gfx.queryRowPitch(.r8, 13, 32) == 32);
    try std.testing.expect(gfx.queryRowPitch(.rg8sn, 256, 16) == 512);
    try std.testing.expect(gfx.queryRowPitch(.rgba8, 256, 16) == 1024);
    try std.testing.expect(gfx.queryRowPitch(.bc1_rgba, 1024, 1) == 2048);
    try std.testing.expect(gfx.queryRowPitch(.bc1_rgba, 1, 1) == 8);
    try std.testing.expect(gfx.queryRowPitch(.depth, 256, 4) == 1024);
    try std.testing.expect(gfx.queryRowPitch(.depth_stencil, 256, 4) == 1024);
}

test "sg_query_surface_pitch" {
    common.setup(.{});
    defer gfx.shutdown();
    try std.testing.expect(gfx.querySurfacePitch(.r8, 256, 256, 1) == (256 * 256));
    try std.testing.expect(gfx.querySurfacePitch(.r8, 256, 256, 1024) == (256 * 1024));
    try std.testing.expect(gfx.querySurfacePitch(.rg8, 1, 1, 1) == 2);
    try std.testing.expect(gfx.querySurfacePitch(.rg8, 256, 256, 4) == (256 * 256 * 2));
    try std.testing.expect(gfx.querySurfacePitch(.rgba32f, 256, 256, 1) == (256 * 256 * 16));
    try std.testing.expect(gfx.querySurfacePitch(.bc1_rgba, 256, 256, 1) == (256 * 2 * 64));
    try std.testing.expect(gfx.querySurfacePitch(.bc1_rgba, 256, 1, 1) == (256 * 2));
    try std.testing.expect(gfx.querySurfacePitch(.bc1_rgba, 256, 2, 1) == (256 * 2));
    try std.testing.expect(gfx.querySurfacePitch(.bc1_rgba, 256, 3, 1) == (256 * 2));
    try std.testing.expect(gfx.querySurfacePitch(.bc1_rgba, 256, 4, 1) == (256 * 2));
    try std.testing.expect(gfx.querySurfacePitch(.bc1_rgba, 256, 5, 1) == (256 * 2 * 2));
}

test "max_texture_bindings_per_stage_vs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].texture.stage = .vertex;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(log_items[0] == .shaderdesc_too_many_vertexstage_textures);
}

test "max_texture_bindings_per_stage_fs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].texture.stage = .fragment;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(log_items[0] == .shaderdesc_too_many_fragmentstage_textures);
}

test "max_texture_bindings_per_stage_cs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].texture.stage = .compute;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(log_items[0] == .shaderdesc_too_many_computestage_textures);
}

test "max_storagebuffer_bindings_per_stage_vs" {
    common.setup(.{});
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_buffer.stage = .vertex;
        desc.views[i].storage_buffer.readonly = true;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(log_items[0] == .shaderdesc_too_many_vertexstage_storagebuffers);
}

test "max_storagebuffer_bindings_per_stage_fs" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    var desc: gfx.ShaderDesc = .{};
    for (0..gfx.max_view_bindslots) |i| {
        desc.views[i].storage_buffer.stage = .fragment;
    }
    const shd = gfx.makeShader(desc);
    try std.testing.expect(gfx.queryShaderState(shd) == .failed);
    try std.testing.expect(log_items[0] == .shaderdesc_too_many_fragmentstage_storagebuffers);
}

test {
    _ = .{ std, gfx, core };
}
