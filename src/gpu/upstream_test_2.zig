//! Tests ported from upstream sokol tests/functional/sokol_gfx_test.c (part 2).
const std = @import("std");
const common = @import("upstream_test_common.zig");
const gfx = common.gfx;
const core = common.core;

const expect = std.testing.expect;
const li = &common.log_items;

fn ud(n: usize) ?*anyopaque {
    return @ptrFromInt(n);
}

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

fn createCopySrcBuffer(usage: gfx.BufferUsage, size: usize) gfx.Buffer {
    var u = usage;
    u.copy_src = true;
    u.write_transient = true;
    return gfx.makeBuffer(.{ .size = size, .usage = u });
}

fn createCopyDstImage(width: i32, height: i32) gfx.Image {
    return gfx.makeImage(.{
        .width = width,
        .height = height,
        .pixel_format = .rgba8,
        .usage = .{ .copy_dst = true },
    });
}

// override backend features after resource creation to test the validation rules in isolation
fn setCopyBufferToImageFeatures(relaxed_buffer_type: bool, relaxed_bytes_per_row: bool, separate_buffer_types: bool) void {
    const f = &core.state().features;
    f.copy_buffer_to_image_relaxed_buffer_type = relaxed_buffer_type;
    f.copy_buffer_to_image_relaxed_bytes_per_row = relaxed_bytes_per_row;
    f.separate_buffer_types = separate_buffer_types;
}

test "copy_buffer_to_buffer_validate_size_and_offsets" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(64);
    const dst = createCopyDstBuffer(32);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{
        .src = .{ .buffer = src, .offset = 2 },
        .dst = .{ .buffer = dst, .offset = 1 },
        .size = 0,
    });
    try expect(li[0] == .validate_copybuffertobuffer_zero_size);
    try expect(li[1] == .validate_copybuffertobuffer_src_offset_alignment);
    try expect(li[2] == .validate_copybuffertobuffer_dst_offset_alignment);
    try expect(li[3] == .validation_failed);
    try expect(common.num_log_called == 4);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{
        .src = .{ .buffer = src, .offset = 32 },
        .dst = .{ .buffer = dst, .offset = 16 },
        .size = 32,
    });
    try expect(li[0] == .validate_copybuffertobuffer_dst_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{
        .src = .{ .buffer = src, .offset = 48 },
        .dst = .{ .buffer = dst, .offset = 0 },
        .size = 32,
    });
    try expect(li[0] == .validate_copybuffertobuffer_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
}

test "copy_buffer_to_image_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    // staging source must pass with all restrictive features, 16x16 RGBA8 has a 64 byte row pitch
    setCopyBufferToImageFeatures(false, false, true);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst } });
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_src_staging_index_buffer" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createCopySrcBuffer(.{ .staging_index_buffer = true }, 1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    // rejected independent of any backend feature
    for (0..2) |i| {
        const relaxed = i == 1;
        setCopyBufferToImageFeatures(relaxed, relaxed, false);
        common.resetLogItems();
        gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst } });
        try expect(li[0] == .validate_copybuffertoimage_src_staging_index_buffer);
        if (relaxed) {
            try expect(li[1] == .validation_failed);
            try expect(common.num_log_called == 2);
        } else {
            // additionally fails the staging-buffer-only and 256-byte-row checks
            try expect(li[1] == .validate_copybuffertoimage_src_staging_buffer);
            try expect(li[2] == .validate_copybuffertoimage_bytesperrow_multiple_256);
            try expect(li[3] == .validation_failed);
            try expect(common.num_log_called == 4);
        }
    }
}

test "copy_buffer_to_image_relaxed_buffer_type" {
    common.setup(.{});
    defer gfx.shutdown();
    const vtx = createCopySrcBuffer(.{ .vertex_buffer = true }, 1024);
    const idx = createCopySrcBuffer(.{ .index_buffer = true }, 1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(vtx) == .valid);
    try expect(gfx.queryBufferState(idx) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // relaxed: any buffer type is accepted as source
    setCopyBufferToImageFeatures(true, true, false);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = vtx }, .dst = .{ .image = dst } });
    gfx.copyBufferToImage(.{ .src = .{ .buffer = idx }, .dst = .{ .image = dst } });
    try expect(common.num_log_called == 0);

    // not relaxed (D3D11): only .staging_buffer is accepted
    setCopyBufferToImageFeatures(false, true, false);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = vtx }, .dst = .{ .image = dst } });
    try expect(li[0] == .validate_copybuffertoimage_src_staging_buffer);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = idx }, .dst = .{ .image = dst } });
    try expect(li[0] == .validate_copybuffertoimage_src_staging_buffer);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
}

test "copy_buffer_to_image_relaxed_bytes_per_row" {
    common.setup(.{});
    defer gfx.shutdown();
    const vtx = createCopySrcBuffer(.{ .vertex_buffer = true }, 8192);
    const stg = createStagingBuffer(4096);
    const small = createCopyDstImage(16, 16); // 64 byte row pitch
    const wide = createCopyDstImage(64, 16); // 256 byte row pitch
    try expect(gfx.queryBufferState(vtx) == .valid);
    try expect(gfx.queryBufferState(stg) == .valid);
    try expect(gfx.queryImageState(small) == .valid);
    try expect(gfx.queryImageState(wide) == .valid);

    // relaxed: any row pitch is fine
    setCopyBufferToImageFeatures(true, true, false);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = vtx }, .dst = .{ .image = small } });
    try expect(common.num_log_called == 0);

    // not relaxed (WebGPU): non-staging source needs a 256 byte multiple row pitch
    setCopyBufferToImageFeatures(true, false, false);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = vtx }, .dst = .{ .image = small } });
    try expect(li[0] == .validate_copybuffertoimage_bytesperrow_multiple_256);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    // explicit bytes_per_row which is a multiple of the pixel size but not of 256
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = vtx, .bytes_per_row = 320, .bytes_per_slice = 320 * 16 },
        .dst = .{ .image = wide },
    });
    try expect(li[0] == .validate_copybuffertoimage_bytesperrow_multiple_256);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    // 256 byte multiple row pitch passes
    gfx.copyBufferToImage(.{ .src = .{ .buffer = vtx }, .dst = .{ .image = wide } });
    try expect(common.num_log_called == 0);
    // staging source is exempt from the 256 byte rule
    gfx.copyBufferToImage(.{ .src = .{ .buffer = stg }, .dst = .{ .image = small } });
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_webgl2_index_buffer" {
    common.setup(.{});
    defer gfx.shutdown();
    const idx = createCopySrcBuffer(.{ .index_buffer = true }, 1024);
    const vtx = createCopySrcBuffer(.{ .vertex_buffer = true }, 1024);
    const stg = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(idx) == .valid);
    try expect(gfx.queryBufferState(vtx) == .valid);
    try expect(gfx.queryBufferState(stg) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // separate buffer types (WebGL2): index buffers can't be a source
    setCopyBufferToImageFeatures(true, true, true);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = idx }, .dst = .{ .image = dst } });
    try expect(li[0] == .validate_copybuffertoimage_webgl2_index_buffer);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    // ...but vertex and staging buffers are fine
    gfx.copyBufferToImage(.{ .src = .{ .buffer = vtx }, .dst = .{ .image = dst } });
    gfx.copyBufferToImage(.{ .src = .{ .buffer = stg }, .dst = .{ .image = dst } });
    try expect(common.num_log_called == 0);

    // without separate buffer types an index buffer source is fine
    setCopyBufferToImageFeatures(true, true, false);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = idx }, .dst = .{ .image = dst } });
    try expect(common.num_log_called == 0);
}

fn copyBuffer16Bytes(src: gfx.Buffer, dst: gfx.Buffer) void {
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dst }, .size = 16 });
}

// WebGL2 can only copy between two index buffers or two non-index buffers
test "copy_buffer_to_buffer_webgl2_index_buffer" {
    common.setup(.{});
    defer gfx.shutdown();
    const src_stg = createStagingBuffer(64);
    const src_stg_idx = createCopySrcBuffer(.{ .staging_index_buffer = true }, 64);
    const src_vtx = createCopySrcBuffer(.{ .vertex_buffer = true }, 64);
    const src_idx = createCopySrcBuffer(.{ .index_buffer = true }, 64);
    const dst_vtx = createCopyDstBuffer(64);
    const dst_idx = gfx.makeBuffer(.{
        .size = 64,
        .usage = .{ .index_buffer = true, .copy_dst = true },
    });
    try expect(gfx.queryBufferState(src_stg) == .valid);
    try expect(gfx.queryBufferState(src_stg_idx) == .valid);
    try expect(gfx.queryBufferState(src_vtx) == .valid);
    try expect(gfx.queryBufferState(src_idx) == .valid);
    try expect(gfx.queryBufferState(dst_vtx) == .valid);
    try expect(gfx.queryBufferState(dst_idx) == .valid);
    const invalid_pairs = [4][2]gfx.Buffer{
        .{ src_stg, dst_idx },
        .{ src_vtx, dst_idx },
        .{ src_stg_idx, dst_vtx },
        .{ src_idx, dst_vtx },
    };

    // separate buffer types (WebGL2): index-to-index and non-index-to-non-index is fine...
    core.state().features.separate_buffer_types = true;
    common.resetLogItems();
    copyBuffer16Bytes(src_stg_idx, dst_idx);
    copyBuffer16Bytes(src_idx, dst_idx);
    copyBuffer16Bytes(src_stg, dst_vtx);
    copyBuffer16Bytes(src_vtx, dst_vtx);
    try expect(common.num_log_called == 0);
    // ...but mixing index and non-index buffers in either direction is not
    for (0..4) |i| {
        common.resetLogItems();
        copyBuffer16Bytes(invalid_pairs[i][0], invalid_pairs[i][1]);
        try expect(li[0] == .validate_copybuffertobuffer_webgl2_index_buffer);
        try expect(li[1] == .validation_failed);
        try expect(common.num_log_called == 2);
    }

    // without separate buffer types, mixing is fine
    core.state().features.separate_buffer_types = false;
    common.resetLogItems();
    for (0..4) |i| {
        copyBuffer16Bytes(invalid_pairs[i][0], invalid_pairs[i][1]);
    }
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_src_overflow" {
    common.setup(.{});
    defer gfx.shutdown();
    const full_ok = createStagingBuffer(1024);
    const full_small = createStagingBuffer(1020);
    const sub_ok = createStagingBuffer(144);
    const sub_small = createStagingBuffer(140);
    const dst = createCopyDstImage(16, 16); // 64 byte row pitch, 1024 byte slice pitch
    try expect(gfx.queryBufferState(full_ok) == .valid);
    try expect(gfx.queryBufferState(full_small) == .valid);
    try expect(gfx.queryBufferState(sub_ok) == .valid);
    try expect(gfx.queryBufferState(sub_small) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // whole image with default pitches requires exactly 1024 bytes
    gfx.copyBufferToImage(.{ .src = .{ .buffer = full_ok }, .dst = .{ .image = dst } });
    try expect(common.num_log_called == 0);
    gfx.copyBufferToImage(.{ .src = .{ .buffer = full_small }, .dst = .{ .image = dst } });
    try expect(li[0] == .validate_copybuffertoimage_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();

    // 4x2 sub-region with a one-row source offset: only the bytes actually
    // read are required, e.g. no padding after the last row or slice:
    //  64 (offset) + 64 (first row incl. padding) + 16 (last row) = 144
    const sub_desc: gfx.CopyBufferToImageDesc = .{
        .src = .{ .offset = 64, .bytes_per_row = 64, .bytes_per_slice = 128 },
        .dst = .{ .image = dst, .x = 2, .y = 4 },
        .size = .{ .width = 4, .height = 2 },
    };
    var desc = sub_desc;
    desc.src.buffer = sub_ok;
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);
    desc.src.buffer = sub_small;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    // a bigger offset pushes the same copy over the end
    desc.src.buffer = sub_ok;
    desc.src.offset = 68;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
}

test "copy_buffer_to_image_src_overflow_array" {
    common.setup(.{});
    defer gfx.shutdown();
    const src_ok = createStagingBuffer(1104);
    const src_small = createStagingBuffer(1100);
    const dst = gfx.makeImage(.{
        .type = .array,
        .width = 16,
        .height = 16,
        .num_slices = 3,
        .pixel_format = .rgba8,
        .usage = .{ .copy_dst = true },
    });
    try expect(gfx.queryBufferState(src_ok) == .valid);
    try expect(gfx.queryBufferState(src_small) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // 4x2 region into slices 1 and 2 with default pitches (64 and 1024 bytes):
    //  1024 (first slice incl. padding) + 64 (first row of last slice) + 16 (last row) = 1104
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src_ok },
        .dst = .{ .image = dst, .slice = 1 },
        .size = .{ .width = 4, .height = 2, .num_slices = 2 },
    });
    try expect(common.num_log_called == 0);
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src_small },
        .dst = .{ .image = dst, .slice = 1 },
        .size = .{ .width = 4, .height = 2, .num_slices = 2 },
    });
    try expect(li[0] == .validate_copybuffertoimage_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
}

test "copy_buffer_to_image_bytes_per_row_too_small" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // 16 pixel wide copy needs at least 64 bytes per row
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .bytes_per_row = 32, .bytes_per_slice = 32 * 16 },
        .dst = .{ .image = dst },
        .size = .{ .width = 16, .height = 16 },
    });
    try expect(li[0] == .validate_copybuffertoimage_bytesperrow_too_small);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    // ...but a 32 byte row pitch is enough for an 8 pixel wide copy
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .bytes_per_row = 32, .bytes_per_slice = 32 * 16 },
        .dst = .{ .image = dst },
        .size = .{ .width = 8, .height = 16 },
    });
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_bytes_per_slice_too_small" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // 16 rows with 64 bytes per row need at least 1024 bytes per slice
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .bytes_per_row = 64, .bytes_per_slice = 64 * 8 },
        .dst = .{ .image = dst },
        .size = .{ .width = 16, .height = 16 },
    });
    try expect(li[0] == .validate_copybuffertoimage_bytesperslice_too_small);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    // ...but 512 bytes per slice are enough for an 8 row copy
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .bytes_per_row = 64, .bytes_per_slice = 64 * 8 },
        .dst = .{ .image = dst },
        .size = .{ .width = 16, .height = 8 },
    });
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_compressed_sizes" {
    common.setup(.{});
    defer gfx.shutdown();
    // 16x16 BC1: 4x4 blocks of 8 bytes, 32 byte row pitch, 128 byte slice pitch
    const src_ok = createStagingBuffer(48);
    const src_small = createStagingBuffer(40);
    const dst = gfx.makeImage(.{
        .width = 16,
        .height = 16,
        .pixel_format = .bc1_rgba,
        .usage = .{ .copy_dst = true },
    });
    try expect(gfx.queryBufferState(src_ok) == .valid);
    try expect(gfx.queryBufferState(src_small) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // 8x8 pixel region is 2x2 blocks: 32 (first block-row incl. padding) + 16 (last block-row) = 48
    var desc: gfx.CopyBufferToImageDesc = .{
        .src = .{ .buffer = src_ok, .bytes_per_row = 32, .bytes_per_slice = 128 },
        .dst = .{ .image = dst, .x = 4, .y = 4 },
        .size = .{ .width = 8, .height = 8 },
    };
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);
    desc.src.buffer = src_small;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();

    // one block (8 bytes) per row is too small for a 2 block wide copy
    desc.src.buffer = src_ok;
    desc.src.bytes_per_row = 8;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_bytesperrow_too_small);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();

    // a slice pitch of one block-row is too small for a 2 block-row copy
    desc.src.bytes_per_row = 32;
    desc.src.bytes_per_slice = 32;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_bytesperslice_too_small);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();

    // copy size must be a multiple of the block dimensions
    desc.src.bytes_per_slice = 128;
    desc.size.width = 6;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_width_multiple);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    desc.size.width = 8;
    desc.size.height = 6;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_height_multiple);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();

    // source offset must be a multiple of the block size (single block copy)
    desc.size.width = 4;
    desc.size.height = 4;
    desc.src.offset = 4;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_src_offset_alignment);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    desc.src.offset = 8;
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_compressed_small_mips" {
    common.setup(.{});
    defer gfx.shutdown();
    // 24x24 BC1 with miplevels 24, 12, 6, 3, 1
    const src = createStagingBuffer(1024);
    const dst = gfx.makeImage(.{
        .width = 24,
        .height = 24,
        .num_mipmaps = 5,
        .pixel_format = .bc1_rgba,
        .usage = .{ .copy_dst = true },
    });
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // default-sized copies into miplevels smaller than one block are allowed
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .mip_level = 3 } });
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .mip_level = 4 } });
    try expect(common.num_log_called == 0);

    // a non-block-multiple size is allowed when the copy reaches the miplevel edge (6x6 miplevel)
    var desc: gfx.CopyBufferToImageDesc = .{
        .src = .{ .buffer = src },
        .dst = .{ .image = dst, .mip_level = 2, .x = 4, .y = 4 },
        .size = .{ .width = 2, .height = 2 },
    };
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);
    desc.dst.x = 0;
    desc.dst.y = 0;
    desc.size = .{ .width = 6, .height = 6 };
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);

    // ...but not when the copy ends inside the miplevel
    desc.size = .{ .width = 2, .height = 6 };
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_width_multiple);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    desc.size = .{ .width = 6, .height = 2 };
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_height_multiple);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();

    // the same rules in the 3x3 miplevel
    desc.dst.mip_level = 3;
    desc.size = .{ .width = 3, .height = 3 };
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);
    desc.size = .{ .width = 2, .height = 2 };
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_width_multiple);
    try expect(li[1] == .validate_copybuffertoimage_dst_height_multiple);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
}

test "copy_buffer_to_image_compressed_dst_alignment" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = gfx.makeImage(.{
        .width = 16,
        .height = 16,
        .pixel_format = .bc1_rgba,
        .usage = .{ .copy_dst = true },
    });
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // block-aligned destination offsets are fine
    var desc: gfx.CopyBufferToImageDesc = .{
        .src = .{ .buffer = src },
        .dst = .{ .image = dst, .x = 4, .y = 8 },
        .size = .{ .width = 4, .height = 4 },
    };
    gfx.copyBufferToImage(desc);
    try expect(common.num_log_called == 0);

    // unaligned destination offsets are rejected, even when the copy reaches the miplevel edge
    desc.dst.x = 2;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_x_alignment);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    common.resetLogItems();
    desc.dst.x = 4;
    desc.dst.y = 6;
    desc.size.height = 10;
    gfx.copyBufferToImage(desc);
    try expect(li[0] == .validate_copybuffertoimage_dst_y_alignment);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
}

test "copy_buffer_to_image_uncompressed_unaligned_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    // the block alignment rules don't apply to uncompressed formats
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src },
        .dst = .{ .image = dst, .x = 3, .y = 5 },
        .size = .{ .width = 7, .height = 9 },
    });
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_dst_range_with_default_size" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);

    // a destination offset at the edge of the miplevel defaults the copy size to zero,
    // this must only trigger the size and range checks (and not any of the source size checks)
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .x = 16 } });
    try expect(li[0] == .validate_copybuffertoimage_dst_width);
    try expect(li[1] == .validate_copybuffertoimage_dst_x_range);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .y = 16 } });
    try expect(li[0] == .validate_copybuffertoimage_dst_height);
    try expect(li[1] == .validate_copybuffertoimage_dst_y_range);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .slice = 1 } });
    try expect(li[0] == .validate_copybuffertoimage_dst_numslices);
    try expect(li[1] == .validate_copybuffertoimage_dst_slice_range);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
    common.resetLogItems();

    // a destination offset beyond the edge defaults to a negative copy size (must not assert)
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .x = 20 } });
    try expect(li[0] == .validate_copybuffertoimage_dst_width);
    try expect(li[1] == .validate_copybuffertoimage_dst_x_range);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .y = 20 } });
    try expect(li[0] == .validate_copybuffertoimage_dst_height);
    try expect(li[1] == .validate_copybuffertoimage_dst_y_range);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .slice = 2 } });
    try expect(li[0] == .validate_copybuffertoimage_dst_numslices);
    try expect(li[1] == .validate_copybuffertoimage_dst_slice_range);
    try expect(li[2] == .validation_failed);
    try expect(common.num_log_called == 3);
    common.resetLogItems();

    // the default copy size covers the rest of the miplevel and the source is sized for that
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst, .x = 15, .y = 15 } });
    try expect(common.num_log_called == 0);
}

test "copy_buffer_to_image_stats" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const src_small = createStagingBuffer(1020);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryBufferState(src_small) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    gfx.enableStats();

    // whole image with default pitches
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dst } });
    try expect(common.num_log_called == 0);
    var stats = gfx.queryStats();
    try expect(stats.cur_frame.num_copy_buffer_to_image == 1);
    try expect(stats.cur_frame.size_copy_buffer_to_image == 1024);

    // 4x2 sub-region only counts the bytes actually read: 64 (first row incl. padding) + 16 (last row)
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .bytes_per_row = 64, .bytes_per_slice = 128 },
        .dst = .{ .image = dst, .x = 2, .y = 4 },
        .size = .{ .width = 4, .height = 2 },
    });
    try expect(common.num_log_called == 0);
    stats = gfx.queryStats();
    try expect(stats.cur_frame.num_copy_buffer_to_image == 2);
    try expect(stats.cur_frame.size_copy_buffer_to_image == 1104);

    // a copy rejected by validation is counted, but doesn't add to the copied size
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src_small }, .dst = .{ .image = dst } });
    try expect(li[0] == .validate_copybuffertoimage_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    stats = gfx.queryStats();
    try expect(stats.cur_frame.num_copy_buffer_to_image == 3);
    try expect(stats.cur_frame.size_copy_buffer_to_image == 1104);
}

// copy resources must be in VALID state, this is checked outside the validation layer,
// and before the copy desc defaults are resolved (which require a valid image pixel format)
fn checkCopyBufferToImageResourceState() !void {
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    const alloc_buf = gfx.allocBuffer();
    const failed_buf = gfx.allocBuffer();
    gfx.failBuffer(failed_buf);
    const alloc_img = gfx.allocImage();
    const failed_img = gfx.allocImage();
    gfx.failImage(failed_img);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    try expect(gfx.queryBufferState(alloc_buf) == .alloc);
    try expect(gfx.queryBufferState(failed_buf) == .failed);
    try expect(gfx.queryImageState(alloc_img) == .alloc);
    try expect(gfx.queryImageState(failed_img) == .failed);
    common.resetLogItems();

    gfx.copyBufferToImage(.{ .src = .{ .buffer = alloc_buf }, .dst = .{ .image = dst } });
    try expect(li[0] == .copy_buffer_to_image_src_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = failed_buf }, .dst = .{ .image = dst } });
    try expect(li[0] == .copy_buffer_to_image_src_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = alloc_img } });
    try expect(li[0] == .copy_buffer_to_image_dst_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = failed_img } });
    try expect(li[0] == .copy_buffer_to_image_dst_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    // only the first error is reported
    gfx.copyBufferToImage(.{ .src = .{ .buffer = alloc_buf }, .dst = .{ .image = failed_img } });
    try expect(li[0] == .copy_buffer_to_image_src_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    // a rejected copy is counted, but doesn't add to the copied size
    gfx.enableStats();
    const stats_before = gfx.queryStats().cur_frame;
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = failed_img } });
    try expect(common.num_log_called == 1);
    const stats_after = gfx.queryStats().cur_frame;
    try expect(stats_after.num_copy_buffer_to_image == (stats_before.num_copy_buffer_to_image + 1));
    try expect(stats_after.size_copy_buffer_to_image == stats_before.size_copy_buffer_to_image);
}

test "copy_buffer_to_image_resource_state" {
    common.setup(.{});
    defer gfx.shutdown();
    try checkCopyBufferToImageResourceState();
}

// ...and the same must happen with validation disabled
test "copy_buffer_to_image_resource_state_no_validation" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    try checkCopyBufferToImageResourceState();
}

// destroyed resources are reported as errors outside the validation layer
test "copy_buffer_to_image_resource_alive" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    const dead_buf = createStagingBuffer(1024);
    const dead_img = createCopyDstImage(16, 16);
    gfx.destroyBuffer(dead_buf);
    gfx.destroyImage(dead_img);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    try expect(gfx.queryBufferState(dead_buf) == .invalid);
    try expect(gfx.queryImageState(dead_img) == .invalid);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = dead_buf }, .dst = .{ .image = dst } });
    try expect(li[0] == .copy_buffer_to_image_src_alive);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToImage(.{ .src = .{ .buffer = src }, .dst = .{ .image = dead_img } });
    try expect(li[0] == .copy_buffer_to_image_dst_alive);
    try expect(common.num_log_called == 1);
}

test "copy_buffer_to_image_negative_bytes_per_row" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(1024);
    const dst = createCopyDstImage(16, 16);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryImageState(dst) == .valid);
    // must be rejected by validation, and not assert in the bytes-per-slice multiple check
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .bytes_per_row = -64, .bytes_per_slice = 1024 },
        .dst = .{ .image = dst },
    });
    try expect(li[0] == .validate_copybuffertoimage_bytesperrow_multiple_blocksize);
    try expect(li[1] == .validate_copybuffertoimage_bytesperslice);
    try expect(li[2] == .validate_copybuffertoimage_src_overflow);
    try expect(li[3] == .validation_failed);
    try expect(common.num_log_called == 4);
}

// copy resources must be in VALID state, this is checked outside the validation layer
fn checkCopyBufferToBufferResourceState() !void {
    const src = createStagingBuffer(64);
    const dst = createCopyDstBuffer(64);
    const alloc_buf = gfx.allocBuffer();
    const failed_buf = gfx.allocBuffer();
    gfx.failBuffer(failed_buf);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryBufferState(dst) == .valid);
    try expect(gfx.queryBufferState(alloc_buf) == .alloc);
    try expect(gfx.queryBufferState(failed_buf) == .failed);
    common.resetLogItems();

    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = alloc_buf }, .dst = .{ .buffer = dst }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_src_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = failed_buf }, .dst = .{ .buffer = dst }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_src_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = alloc_buf }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_dst_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = failed_buf }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_dst_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    // only the first error is reported
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = alloc_buf }, .dst = .{ .buffer = failed_buf }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_src_valid);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    // a rejected copy is counted, but doesn't add to the copied size
    gfx.enableStats();
    const stats_before = gfx.queryStats().cur_frame;
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = failed_buf }, .size = 32 });
    try expect(common.num_log_called == 1);
    const stats_after = gfx.queryStats().cur_frame;
    try expect(stats_after.num_copy_buffer_to_buffer == (stats_before.num_copy_buffer_to_buffer + 1));
    try expect(stats_after.size_copy_buffer_to_buffer == stats_before.size_copy_buffer_to_buffer);
}

test "copy_buffer_to_buffer_resource_state" {
    common.setup(.{});
    defer gfx.shutdown();
    try checkCopyBufferToBufferResourceState();
}

// ...and the same must happen with validation disabled
test "copy_buffer_to_buffer_resource_state_no_validation" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    try checkCopyBufferToBufferResourceState();
}

// destroyed resources are reported as errors outside the validation layer
test "copy_buffer_to_buffer_resource_alive" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(64);
    const dst = createCopyDstBuffer(64);
    const dead_buf = createStagingBuffer(64);
    gfx.destroyBuffer(dead_buf);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryBufferState(dst) == .valid);
    try expect(gfx.queryBufferState(dead_buf) == .invalid);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = dead_buf }, .dst = .{ .buffer = dst }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_src_alive);
    try expect(common.num_log_called == 1);
    common.resetLogItems();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dead_buf }, .size = 32 });
    try expect(li[0] == .copy_buffer_to_buffer_dst_alive);
    try expect(common.num_log_called == 1);
}

test "copy_buffer_to_buffer_stats" {
    common.setup(.{});
    defer gfx.shutdown();
    const src = createStagingBuffer(64);
    const dst = createCopyDstBuffer(64);
    try expect(gfx.queryBufferState(src) == .valid);
    try expect(gfx.queryBufferState(dst) == .valid);
    gfx.enableStats();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src }, .dst = .{ .buffer = dst }, .size = 32 });
    try expect(common.num_log_called == 0);
    var stats = gfx.queryStats();
    try expect(stats.cur_frame.num_copy_buffer_to_buffer == 1);
    try expect(stats.cur_frame.size_copy_buffer_to_buffer == 32);
    // a copy rejected by validation is counted, but doesn't add to the copied size
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = src, .offset = 48 }, .dst = .{ .buffer = dst }, .size = 32 });
    try expect(li[0] == .validate_copybuffertobuffer_src_overflow);
    try expect(li[1] == .validation_failed);
    try expect(common.num_log_called == 2);
    stats = gfx.queryStats();
    try expect(stats.cur_frame.num_copy_buffer_to_buffer == 2);
    try expect(stats.cur_frame.size_copy_buffer_to_buffer == 32);
}

var commit_listener_userdata: usize = 0;
var commit_listener_num_called: usize = 0;

fn resetCommitListener() void {
    commit_listener_userdata = 0;
    commit_listener_num_called = 0;
}

fn commitListenerFunc(user_data: ?*anyopaque) void {
    commit_listener_userdata = @intFromPtr(user_data);
    commit_listener_num_called += 1;
}

fn listener(user_data: usize) gfx.CommitListener {
    return .{ .func = commitListenerFunc, .user_data = ud(user_data) };
}

test "commit_listener_called" {
    resetCommitListener();
    common.setup(.{});
    defer gfx.shutdown();
    const added = gfx.addCommitListener(listener(23));
    try expect(added);
    try expect(core.state().commit_listeners_upper == 1);
    gfx.commit();
    try expect(23 == commit_listener_userdata);
    try expect(1 == commit_listener_num_called);
}

test "commit_listener_add_twice" {
    resetCommitListener();
    common.setup(.{});
    defer gfx.shutdown();
    const l = listener(23);
    try expect(gfx.addCommitListener(l));
    try expect(core.state().commit_listeners_upper == 1);
    try expect(!gfx.addCommitListener(l));
    try expect(core.state().commit_listeners_upper == 1);
    gfx.commit();
    try expect(23 == commit_listener_userdata);
    try expect(1 == commit_listener_num_called);
}

test "commit_listener_same_func_diff_ud" {
    resetCommitListener();
    common.setup(.{});
    defer gfx.shutdown();
    try expect(gfx.addCommitListener(listener(23)));
    try expect(core.state().commit_listeners_upper == 1);
    try expect(gfx.addCommitListener(listener(25)));
    try expect(core.state().commit_listeners_upper == 2);
    gfx.commit();
    try expect(2 == commit_listener_num_called);
}

test "commit_listener_add_remove_add" {
    resetCommitListener();
    common.setup(.{});
    defer gfx.shutdown();
    const l = listener(23);
    try expect(gfx.addCommitListener(l));
    try expect(core.state().commit_listeners_upper == 1);
    try expect(gfx.removeCommitListener(l));
    try expect(core.state().commit_listeners_upper == 1);
    gfx.commit();
    try expect(0 == commit_listener_num_called);
    try expect(gfx.addCommitListener(l));
    try expect(core.state().commit_listeners_upper == 1);
    gfx.commit();
    try expect(1 == commit_listener_num_called);
    try expect(23 == commit_listener_userdata);
}

test "commit_listener_remove_non_existent" {
    resetCommitListener();
    common.setup(.{});
    defer gfx.shutdown();
    const l0 = listener(23);
    const l1 = listener(46);
    const l2 = listener(256);
    try expect(gfx.addCommitListener(l0));
    try expect(gfx.addCommitListener(l1));
    try expect(core.state().commit_listeners_upper == 2);
    try expect(!gfx.removeCommitListener(l2));
    try expect(core.state().commit_listeners_upper == 2);
}

test "commit_listener_multi_add_remove" {
    resetCommitListener();
    common.setup(.{});
    defer gfx.shutdown();
    const l0 = listener(23);
    const l1 = listener(46);
    try expect(gfx.addCommitListener(l0));
    try expect(gfx.addCommitListener(l1));
    try expect(core.state().commit_listeners_upper == 2);
    // removing the first listener will just clear its slot
    try expect(gfx.removeCommitListener(l0));
    try expect(core.state().commit_listeners_upper == 2);
    gfx.commit();
    try expect(commit_listener_num_called == 1);
    try expect(commit_listener_userdata == 46);
    commit_listener_num_called = 0;
    // adding the first listener back will fill that same slot again
    try expect(gfx.addCommitListener(l0));
    try expect(core.state().commit_listeners_upper == 2);
    gfx.commit();
    try expect(commit_listener_num_called == 2);
    try expect(commit_listener_userdata == 46);
    commit_listener_num_called = 0;
    // removing the second listener will decrement the upper bound
    try expect(gfx.removeCommitListener(l1));
    try expect(core.state().commit_listeners_upper == 2);
    gfx.commit();
    try expect(commit_listener_num_called == 1);
    try expect(commit_listener_userdata == 23);
    commit_listener_num_called = 0;
    // and finally remove the first listener too
    try expect(gfx.removeCommitListener(l0));
    try expect(core.state().commit_listeners_upper == 2);
    gfx.commit();
    try expect(commit_listener_num_called == 0);
    // removing the same listener twice just returns false
    try expect(!gfx.removeCommitListener(l0));
    try expect(!gfx.removeCommitListener(l1));
}

test "commit_listener_array_full" {
    resetCommitListener();
    common.setup(.{ .max_commit_listeners = 3 });
    defer gfx.shutdown();
    const l0 = listener(23);
    const l1 = listener(46);
    const l2 = listener(128);
    const l3 = listener(256);
    try expect(gfx.addCommitListener(l0));
    try expect(gfx.addCommitListener(l1));
    try expect(gfx.addCommitListener(l2));
    try expect(core.state().commit_listeners_upper == 3);
    // overflow!
    try expect(!gfx.addCommitListener(l3));
    try expect(core.state().commit_listeners_upper == 3);
    gfx.commit();
    try expect(commit_listener_num_called == 3);
    try expect(commit_listener_userdata == 128);
}

test "buffer_double_destroy_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = common.createBuffer();
    try expect(gfx.queryBufferState(buf) == .valid);
    gfx.destroyBuffer(buf);
    try expect(gfx.queryBufferState(buf) == .invalid);
    gfx.destroyBuffer(buf);
    try expect(gfx.queryBufferState(buf) == .invalid);
}

test "image_double_destroy_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = common.createImage();
    try expect(gfx.queryImageState(img) == .valid);
    gfx.destroyImage(img);
    try expect(gfx.queryImageState(img) == .invalid);
    gfx.destroyImage(img);
    try expect(gfx.queryImageState(img) == .invalid);
}

test "sampler_double_destroy_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const smp = gfx.makeSampler(.{});
    try expect(gfx.querySamplerState(smp) == .valid);
    gfx.destroySampler(smp);
    try expect(gfx.querySamplerState(smp) == .invalid);
    gfx.destroySampler(smp);
    try expect(gfx.querySamplerState(smp) == .invalid);
}

test "shader_double_destroy_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const shd = common.createShader();
    try expect(gfx.queryShaderState(shd) == .valid);
    gfx.destroyShader(shd);
    try expect(gfx.queryShaderState(shd) == .invalid);
    gfx.destroyShader(shd);
    try expect(gfx.queryShaderState(shd) == .invalid);
}

test "pipeline_double_destroy_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const pip = common.createPipeline();
    try expect(gfx.queryPipelineState(pip) == .valid);
    gfx.destroyPipeline(pip);
    try expect(gfx.queryPipelineState(pip) == .invalid);
    gfx.destroyPipeline(pip);
    try expect(gfx.queryPipelineState(pip) == .invalid);
}

// (the C test is named with a typo'd suite, sokoL_gfx; the test name is kept)
test "view_double_destroy_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const view = common.createView();
    try expect(gfx.queryViewState(view) == .valid);
    gfx.destroyView(view);
    try expect(gfx.queryViewState(view) == .invalid);
    gfx.destroyView(view);
    try expect(gfx.queryViewState(view) == .invalid);
}

test "make_dealloc_buffer_warns" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = common.createBuffer();
    try expect(gfx.queryBufferState(buf) == .valid);
    gfx.deallocBuffer(buf);
    try expect(li[0] == .dealloc_buffer_invalid_state);
    try expect(common.num_log_called == 1);
    try expect(gfx.queryBufferState(buf) == .valid);
    gfx.destroyBuffer(buf);
    try expect(gfx.queryBufferState(buf) == .invalid);
}

test "make_dealloc_image_warns" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = common.createImage();
    try expect(gfx.queryImageState(img) == .valid);
    gfx.deallocImage(img);
    try expect(li[0] == .dealloc_image_invalid_state);
    try expect(common.num_log_called == 1);
    try expect(gfx.queryImageState(img) == .valid);
    gfx.destroyImage(img);
    try expect(gfx.queryImageState(img) == .invalid);
}

test "make_dealloc_sampler_warns" {
    common.setup(.{});
    defer gfx.shutdown();
    const smp = gfx.makeSampler(.{});
    try expect(gfx.querySamplerState(smp) == .valid);
    gfx.deallocSampler(smp);
    try expect(li[0] == .dealloc_sampler_invalid_state);
    try expect(common.num_log_called == 1);
    try expect(gfx.querySamplerState(smp) == .valid);
    gfx.destroySampler(smp);
    try expect(gfx.querySamplerState(smp) == .invalid);
}

test "make_dealloc_shader_warns" {
    common.setup(.{});
    defer gfx.shutdown();
    const shd = common.createShader();
    try expect(gfx.queryShaderState(shd) == .valid);
    gfx.deallocShader(shd);
    try expect(li[0] == .dealloc_shader_invalid_state);
    try expect(common.num_log_called == 1);
    try expect(gfx.queryShaderState(shd) == .valid);
    gfx.destroyShader(shd);
    try expect(gfx.queryShaderState(shd) == .invalid);
}

test "make_dealloc_pipeline_warns" {
    common.setup(.{});
    defer gfx.shutdown();
    const pip = common.createPipeline();
    try expect(gfx.queryPipelineState(pip) == .valid);
    gfx.deallocPipeline(pip);
    try expect(li[0] == .dealloc_pipeline_invalid_state);
    try expect(common.num_log_called == 1);
    try expect(gfx.queryPipelineState(pip) == .valid);
    gfx.destroyPipeline(pip);
    try expect(gfx.queryPipelineState(pip) == .invalid);
}

test "make_dealloc_view_warns" {
    common.setup(.{});
    defer gfx.shutdown();
    const view = common.createView();
    try expect(gfx.queryViewState(view) == .valid);
    gfx.deallocView(view);
    try expect(li[0] == .dealloc_view_invalid_state);
    try expect(common.num_log_called == 1);
    try expect(gfx.queryViewState(view) == .valid);
    gfx.destroyView(view);
    try expect(gfx.queryViewState(view) == .invalid);
}

test "alloc_destroy_buffer_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const buf = gfx.allocBuffer();
    try expect(gfx.queryBufferState(buf) == .alloc);
    gfx.destroyBuffer(buf);
    try expect(common.num_log_called == 0);
    try expect(gfx.queryBufferState(buf) == .invalid);
}

test "alloc_destroy_image_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const img = gfx.allocImage();
    try expect(gfx.queryImageState(img) == .alloc);
    gfx.destroyImage(img);
    try expect(common.num_log_called == 0);
    try expect(gfx.queryImageState(img) == .invalid);
}

test "alloc_destroy_sampler_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const smp = gfx.allocSampler();
    try expect(gfx.querySamplerState(smp) == .alloc);
    gfx.destroySampler(smp);
    try expect(common.num_log_called == 0);
    try expect(gfx.querySamplerState(smp) == .invalid);
}

test "alloc_destroy_shader_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const shd = gfx.allocShader();
    try expect(gfx.queryShaderState(shd) == .alloc);
    gfx.destroyShader(shd);
    try expect(common.num_log_called == 0);
    try expect(gfx.queryShaderState(shd) == .invalid);
}

test "alloc_destroy_pipeline_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const pip = gfx.allocPipeline();
    try expect(gfx.queryPipelineState(pip) == .alloc);
    gfx.destroyPipeline(pip);
    try expect(common.num_log_called == 0);
    try expect(gfx.queryPipelineState(pip) == .invalid);
}

test "alloc_destroy_view_is_ok" {
    common.setup(.{});
    defer gfx.shutdown();
    const view = gfx.allocView();
    try expect(gfx.queryViewState(view) == .alloc);
    gfx.destroyView(view);
    try expect(common.num_log_called == 0);
    try expect(gfx.queryViewState(view) == .invalid);
}

test "make_pipeline_with_nonvalid_shader" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    const shd = gfx.allocShader();
    try expect(gfx.queryShaderState(shd) == .alloc);
    var desc: gfx.PipelineDesc = .{ .shader = shd };
    desc.layout.attrs[0].format = .float3;
    const pip = gfx.makePipeline(desc);
    try expect(gfx.queryPipelineState(pip) == .failed);
}

test "make_view_with_nonvalid_image" {
    common.setup(.{ .disable_validation = true });
    defer gfx.shutdown();
    const view = gfx.makeView(.{
        .texture = .{ .image = gfx.allocImage() },
    });
    try expect(gfx.queryViewState(view) == .failed);
    gfx.destroyView(view);
    try expect(gfx.queryViewState(view) == .invalid);
}
