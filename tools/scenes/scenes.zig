//! The cross-backend scene suite: each scene renders or computes with the
//! public zicr.gpu API, reads the result back and compares it with values
//! computed on the CPU. The same scenes run unchanged on every backend.
const std = @import("std");
const gpu = @import("zicr").gpu;
const shaders = @import("scene_shaders");
const compute_shaders = @import("scene_compute_shaders");
const feature_shaders = @import("scene_feature_shaders");

pub const size = 64;
pub const Pixels = [size * size][4]u8;

pub const Scene = struct {
    name: []const u8,
    run: *const fn (env: *Env) anyerror!void,
};

pub const Env = struct {
    dev: *gpu.Device,
    allocator: std.mem.Allocator,
    /// Only deliberate negative tests may declare an expected library diagnostic.
    expected_diagnostic: ?gpu.LogItem = null,
    native_options: ?gpu.Options = null,
    prefer_async: bool = false,
    legacy_gl: bool = false,
    /// Browser harness hooks allow scenes to suspend at readback checkpoints.
    read_buffer: ?*const fn (*gpu.Device, gpu.Buffer, usize, []u8) anyerror!void = null,
    read_image: ?*const fn (*gpu.Device, gpu.Image, gpu.ImageRegion, []u8, gpu.DataLayout) anyerror!void = null,

    /// Failure details of the last scene.
    message: [256]u8 = undefined,
    message_len: usize = 0,

    fn readBuffer(env: *Env, buf: gpu.Buffer, offset: usize, out: []u8) !void {
        if (env.read_buffer) |read| return read(env.dev, buf, offset, out);
        if (env.prefer_async) {
            var ticket = try env.dev.requestReadBuffer(buf, offset, out.len);
            defer ticket.deinit();
            const bytes = try awaitTicket(&ticket);
            @memcpy(out, bytes);
            return;
        }
        return env.dev.readBuffer(buf, offset, out);
    }
    fn readImage(env: *Env, image: gpu.Image, region: gpu.ImageRegion, out: []u8, layout: gpu.DataLayout) !void {
        if (env.read_image) |read| return read(env.dev, image, region, out, layout);
        if (env.prefer_async) {
            var ticket = try env.dev.requestReadImage(image, region, layout);
            defer ticket.deinit();
            const bytes = try awaitTicket(&ticket);
            @memcpy(out[0..bytes.len], bytes);
            return;
        }
        return env.dev.readImage(image, region, out, layout);
    }

    fn fail(env: *Env, comptime fmt: []const u8, args: anytype) error{Mismatch} {
        const msg = std.fmt.bufPrint(&env.message, fmt, args) catch &env.message;
        env.message_len = msg.len;
        return error.Mismatch;
    }

    pub fn failure(env: *const Env) []const u8 {
        return env.message[0..env.message_len];
    }

    fn backend(env: *Env) gpu.Backend {
        return env.dev.backend();
    }

    fn shader(env: *Env, comptime program: anytype) !gpu.Shader {
        const desc = if (@hasDecl(program, "glsl330") and env.legacy_gl)
            program.glsl330
        else
            program.desc(env.backend()) orelse return error.NoShaderForBackend;
        return env.dev.createShader(desc);
    }

    const Target = struct {
        image: gpu.Image,
        view: gpu.View,
        texture: gpu.View = .invalid,
    };

    fn target(env: *Env, format: gpu.PixelFormat) !Target {
        const image = try env.dev.createImage(.{ .width = size, .height = size, .format = format, .usage = .{ .color_attachment = true, .copy_src = true } });
        return .{ .image = image, .view = try env.dev.createView(.{ .color_attachment = .{ .image = image } }) };
    }

    fn sampledTarget(env: *Env) !Target {
        var t = try env.target(.rgba8);
        t.texture = try env.dev.createView(.{ .texture = .{ .image = t.image } });
        return t;
    }

    fn destroyTarget(env: *Env, t: Target) void {
        if (t.texture != .invalid) env.dev.destroy(t.texture);
        env.dev.destroy(t.view);
        env.dev.destroy(t.image);
    }

    fn beginTarget(env: *Env, t: Target, clear_color: [4]f32) gpu.Pass {
        return env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{t.view} } }, .colors = &.{.{ .load = .{ .clear = clear_color } }} });
    }

    /// Reads a rendered RGBA8 target with the first row at the top.
    fn readRendered(env: *Env, image: gpu.Image) !Pixels {
        var pixels: Pixels = undefined;
        try env.readImage(image, .{}, std.mem.sliceAsBytes(&pixels), .{});
        if (!env.dev.features().origin_top_left) {
            for (0..size / 2) |y| {
                for (0..size) |x| std.mem.swap([4]u8, &pixels[y * size + x], &pixels[(size - 1 - y) * size + x]);
            }
        }
        return pixels;
    }

    fn expectPixel(env: *Env, pixels: *const Pixels, x: usize, y: usize, want: [4]u8, tolerance: u8) !void {
        const got = pixels[y * size + x];
        for (got, want) |g, w| {
            if (@abs(@as(i16, g) - w) > tolerance) return env.fail("pixel ({d},{d}) is {any}, expected {any}", .{ x, y, got, want });
        }
    }

    /// Checks the centers of the four quadrants (top-left, top-right, bottom-left, bottom-right).
    fn expectQuadrants(env: *Env, pixels: *const Pixels, colors: [4][4]u8, tolerance: u8) !void {
        const q = size / 4;
        try env.expectPixel(pixels, q, q, colors[0], tolerance);
        try env.expectPixel(pixels, 3 * q, q, colors[1], tolerance);
        try env.expectPixel(pixels, q, 3 * q, colors[2], tolerance);
        try env.expectPixel(pixels, 3 * q, 3 * q, colors[3], tolerance);
    }

    fn colorPipeline(env: *Env, extra: gpu.PipelineDesc) !gpu.Pipeline {
        var desc = extra;
        desc.vertex_attrs = &.{ .{ .format = .float3 }, .{ .format = .float4 } };
        if (desc.colors.len == 1 and desc.colors[0].format == null) desc.colors = &.{.{ .format = .rgba8 }};
        if (desc.depth.format == null) desc.depth.format = .none;
        return env.dev.createPipeline(desc);
    }

    fn texturedPipeline(env: *Env, shd: gpu.Shader) !gpu.Pipeline {
        return env.dev.createPipeline(.{
            .shader = shd,
            .vertex_attrs = &.{ .{ .format = .float2 }, .{ .format = .float2 } },
            .colors = &.{.{ .format = .rgba8 }},
            .depth = .{ .format = .none },
        });
    }

    fn buffer(env: *Env, comptime T: type, data: []const T, usage: gpu.BufferUsage) !gpu.Buffer {
        return env.dev.createBuffer(.{ .usage = usage, .data = std.mem.sliceAsBytes(data) });
    }
};

// ---------------------------------------------------------------- geometry

const ColorVertex = extern struct { pos: [3]f32, color: [4]f32 };
const TexVertex = extern struct { pos: [2]f32, uv: [2]f32 };

const red = [4]f32{ 1, 0, 0, 1 };
const green = [4]f32{ 0, 1, 0, 1 };
const blue = [4]f32{ 0, 0, 1, 1 };
const white = [4]f32{ 1, 1, 1, 1 };
const black = [4]f32{ 0, 0, 0, 1 };

fn rgba8(c: [4]f32) [4]u8 {
    var res: [4]u8 = undefined;
    for (&res, c) |*dst, v| dst.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
    return res;
}

/// Two triangles covering an NDC rectangle.
fn rect(x0: f32, y0: f32, x1: f32, y1: f32, z: f32, color: [4]f32) [6]ColorVertex {
    return .{
        .{ .pos = .{ x0, y0, z }, .color = color }, .{ .pos = .{ x1, y0, z }, .color = color }, .{ .pos = .{ x1, y1, z }, .color = color },
        .{ .pos = .{ x0, y0, z }, .color = color }, .{ .pos = .{ x1, y1, z }, .color = color }, .{ .pos = .{ x0, y1, z }, .color = color },
    };
}

/// A fullscreen quad with texture coordinate (0,0) at the top-left corner.
const fullscreen_tex = [6]TexVertex{
    .{ .pos = .{ -1, 1 }, .uv = .{ 0, 0 } }, .{ .pos = .{ 1, 1 }, .uv = .{ 1, 0 } },  .{ .pos = .{ 1, -1 }, .uv = .{ 1, 1 } },
    .{ .pos = .{ -1, 1 }, .uv = .{ 0, 0 } }, .{ .pos = .{ 1, -1 }, .uv = .{ 1, 1 } }, .{ .pos = .{ -1, -1 }, .uv = .{ 0, 1 } },
};

const identity_transform = [4]f32{ 0, 0, 1, 1 };

/// Draws `vertices` with the color pipeline and the identity transform.
fn drawColored(env: *Env, pass: *gpu.Pass, pip: gpu.Pipeline, vbuf: gpu.Buffer, count: u32, tint: [4]f32) void {
    _ = env;
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &tint);
    pass.draw(.{ .count = count });
}

/// The quadrant pattern: top-left red, top-right green, bottom-left blue, bottom-right white.
fn quadrantVertices() [24]ColorVertex {
    return rect(-1, 0, 0, 1, 0, red) ++ rect(0, 0, 1, 1, 0, green) ++ rect(-1, -1, 0, 0, 0, blue) ++ rect(0, -1, 1, 0, 0, white);
}
const quadrant_colors = [4][4]u8{ rgba8(red), rgba8(green), rgba8(blue), rgba8(white) };

// ---------------------------------------------------------------- scenes

pub const all = [_]Scene{
    .{ .name = "clear", .run = clear },
    .{ .name = "triangles", .run = triangles },
    .{ .name = "indexed_uint16", .run = indexedUint16 },
    .{ .name = "indexed_uint32_base_vertex", .run = indexedBaseVertex },
    .{ .name = "instancing", .run = instancing },
    .{ .name = "instancing_base_instance", .run = instancingBaseInstance },
    .{ .name = "uniform_updates", .run = uniformUpdates },
    .{ .name = "scissor", .run = scissor },
    .{ .name = "viewport", .run = viewport },
    .{ .name = "blend_alpha", .run = blendAlpha },
    .{ .name = "blend_max", .run = blendMax },
    .{ .name = "dual_source_blending", .run = dualSourceBlending },
    .{ .name = "depth_test", .run = depthTest },
    .{ .name = "stencil", .run = stencil },
    .{ .name = "texture_2d", .run = texture2d },
    .{ .name = "sampler_anisotropy", .run = samplerAnisotropy },
    .{ .name = "sampler_border_color", .run = samplerBorderColor },
    .{ .name = "sampler_comparison", .run = samplerComparison },
    .{ .name = "compressed_bc1", .run = compressedBc1 },
    .{ .name = "compressed_bc2", .run = compressedBc2 },
    .{ .name = "compressed_bc3", .run = compressedBc3 },
    .{ .name = "compressed_bc4", .run = compressedBc4 },
    .{ .name = "compressed_bc5", .run = compressedBc5 },
    .{ .name = "compressed_bc6h", .run = compressedBc6 },
    .{ .name = "compressed_bc7", .run = compressedBc7 },
    .{ .name = "compressed_etc2", .run = compressedEtc2 },
    .{ .name = "compressed_astc", .run = compressedAstc },
    .{ .name = "texture_mip_levels", .run = textureMips },
    .{ .name = "texture_mip_view_aliases", .run = textureMipViewAliases },
    .{ .name = "texture_mip_view_switching", .run = textureMipViewSwitching },
    .{ .name = "texture_layer_view_capability", .run = textureLayerViewCapability },
    .{ .name = "texture_array", .run = textureArray },
    .{ .name = "texture_3d", .run = texture3d },
    .{ .name = "texture_cube", .run = textureCube },
    .{ .name = "render_to_texture", .run = renderToTexture },
    .{ .name = "msaa_resolve", .run = msaaResolve },
    .{ .name = "msaa_texture_binding", .run = msaaTextureBinding },
    .{ .name = "multiple_render_targets", .run = multipleRenderTargets },
    .{ .name = "write_buffer_transient", .run = writeBufferTransient },
    .{ .name = "write_image_transient", .run = writeImageTransient },
    .{ .name = "write_unsealed", .run = writeUnsealed },
    .{ .name = "destroy_then_upload", .run = destroyThenUpload },
    .{ .name = "unsealed_draw_skipped", .run = unsealedDrawSkipped },
    .{ .name = "many_frames", .run = manyFrames },
    .{ .name = "copy_buffer_to_buffer", .run = copyBufferToBuffer },
    .{ .name = "copy_buffer_to_image", .run = copyBufferToImage },
    .{ .name = "render_formats", .run = renderFormats },
    .{ .name = "readback_regions", .run = readbackRegions },
    .{ .name = "shader_failure_recovery", .run = shaderFailureRecovery },
    .{ .name = "pipeline_cache_roundtrip", .run = pipelineCacheRoundtrip },
    .{ .name = "async_readback_tickets", .run = asyncReadbackTickets },
    .{ .name = "resource_churn", .run = resourceChurn },
    .{ .name = "randomized_backend_stream", .run = randomizedBackendStream },
    .{ .name = "pool_exhaustion_recovery", .run = poolExhaustionRecovery },
    .{ .name = "descriptor_exhaustion_recovery", .run = descriptorExhaustionRecovery },
    .{ .name = "d3d12_descriptor_ring_recovery", .run = d3d12DescriptorRingRecovery },
    .{ .name = "batched_initial_uploads", .run = batchedInitialUploads },
    .{ .name = "compute_buffer", .run = computeBuffer },
    .{ .name = "compute_image", .run = computeImage },
    .{ .name = "compute_image_r32ui", .run = computeImageR32ui },
    .{ .name = "compute_image_rgba16f", .run = computeImageRgba16f },
    .{ .name = "compute_image_rgba32f", .run = computeImageRgba32f },
    .{ .name = "large_dispatch", .run = largeDispatch },
    .{ .name = "compute_to_vertex", .run = computeToVertex },
};

fn clear(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    var pass = env.beginTarget(t, .{ 0.25, 0.5, 0.75, 1 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    for (0..size) |y| for (0..size) |x| try env.expectPixel(&pixels, x, y, .{ 64, 128, 191, 255 }, 1);
}

fn triangles(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const vertices = quadrantVertices();
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    drawColored(env, &pass, pip, vbuf, 24, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn indexedUint16(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    // a quad per quadrant from 4 vertices each
    var vertices: [16]ColorVertex = undefined;
    var indices: [24]u16 = undefined;
    const origins = [4][2]f32{ .{ -1, 0 }, .{ 0, 0 }, .{ -1, -1 }, .{ 0, -1 } };
    const colors = [4][4]f32{ red, green, blue, white };
    for (origins, colors, 0..) |o, c, q| {
        const corners = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        for (corners, 0..) |corner, i| vertices[q * 4 + i] = .{ .pos = .{ o[0] + corner[0], o[1] + corner[1], 0 }, .color = c };
        const base: u16 = @intCast(q * 4);
        for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |idx, i| indices[q * 6 + i] = base + idx;
    }
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const ibuf = try env.buffer(u16, &indices, .{ .index = true });
    defer env.dev.destroy(ibuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd, .index_type = .uint16 });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }}, .index_buffer = .{ .buffer = ibuf } });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &white);
    pass.draw(.{ .count = 24 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn indexedBaseVertex(env: *Env) !void {
    if (!env.dev.features().draw_base_vertex) return error.SkipScene;
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    // two quads in one buffer; the second is drawn with the indices of the first and base vertex 4
    const vertices = [8]ColorVertex{
        .{ .pos = .{ -1, -1, 0 }, .color = red },  .{ .pos = .{ 0, -1, 0 }, .color = red },   .{ .pos = .{ 0, 1, 0 }, .color = red },   .{ .pos = .{ -1, 1, 0 }, .color = red },
        .{ .pos = .{ 0, -1, 0 }, .color = green }, .{ .pos = .{ 1, -1, 0 }, .color = green }, .{ .pos = .{ 1, 1, 0 }, .color = green }, .{ .pos = .{ 0, 1, 0 }, .color = green },
    };
    const indices = [6]u32{ 0, 1, 2, 0, 2, 3 };
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const ibuf = try env.buffer(u32, &indices, .{ .index = true });
    defer env.dev.destroy(ibuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd, .index_type = .uint32 });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }}, .index_buffer = .{ .buffer = ibuf } });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &white);
    pass.draw(.{ .count = 6 });
    pass.draw(.{ .count = 6, .base_vertex = 4 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, .{ rgba8(red), rgba8(green), rgba8(red), rgba8(green) }, 0);
}

fn instancing(env: *Env) !void {
    try instancingRange(env, false);
}

fn instancingBaseInstance(env: *Env) !void {
    if (!env.dev.features().draw_base_instance) return error.SkipScene;
    try instancingRange(env, true);
}

fn instancingRange(env: *Env, use_base_instance: bool) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    // a quad covering the top-left quadrant, offset per instance
    const quad = [6][2]f32{ .{ -1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ -1, 0 }, .{ 0, 1 }, .{ -1, 1 } };
    const Instance = extern struct { offset: [4]f32, color: [4]f32 };
    const instances = [4]Instance{
        .{ .offset = .{ 0, 0, 0, 0 }, .color = red },
        .{ .offset = .{ 1, 0, 0, 0 }, .color = green },
        .{ .offset = .{ 0, -1, 0, 0 }, .color = blue },
        .{ .offset = .{ 1, -1, 0, 0 }, .color = white },
    };
    const vbuf = try env.buffer([2]f32, &quad, .{});
    defer env.dev.destroy(vbuf);
    const ibuf = try env.buffer(Instance, &instances, .{});
    defer env.dev.destroy(ibuf);
    const shd = try env.shader(shaders.instanced);
    defer env.dev.destroy(shd);
    const pip = try env.dev.createPipeline(.{
        .shader = shd,
        .vertex_buffers = &.{ .{}, .{ .step = .per_instance } },
        .vertex_attrs = &.{ .{ .format = .float2 }, .{ .format = .float4, .buffer = 1 }, .{ .format = .float4, .buffer = 1 } },
        .colors = &.{.{ .format = .rgba8 }},
        .depth = .{ .format = .none },
    });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{ .{ .buffer = vbuf }, .{ .buffer = ibuf } } });
    pass.setUniforms(shaders.instanced.uniform_blocks.color_fs_params, &white);
    if (use_base_instance) {
        // Two nonzero offsets must select distinct instance records, including
        // the final record; restarting at zero produces the wrong quadrants.
        pass.draw(.{ .count = 6, .instances = 1 });
        pass.draw(.{ .count = 6, .instances = 2, .first_instance = 1 });
        pass.draw(.{ .count = 6, .instances = 1, .first_instance = 3 });
    } else {
        pass.draw(.{ .count = 6, .instances = 4 });
    }
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn uniformUpdates(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    // one unit quad drawn into 16 vertical strips, each with its own transform and tint
    const quad = rect(0, -1, 1, 1, 0, white);
    const vbuf = try env.buffer(ColorVertex, &quad, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
    for (0..16) |i| {
        const strip: f32 = @floatFromInt(i);
        const transform = [4]f32{ -1 + strip / 8, 0, 1.0 / 8.0, 1 };
        const tint = [4]f32{ strip / 15, 1 - strip / 15, 0.5, 1 };
        pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &transform);
        pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &tint);
        pass.draw(.{ .count = 6 });
    }
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    for (0..16) |i| {
        const strip: f32 = @floatFromInt(i);
        try env.expectPixel(&pixels, i * 4 + 2, size / 2, rgba8(.{ strip / 15, 1 - strip / 15, 0.5, 1 }), 1);
    }
}

fn scissor(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const quad = rect(-1, -1, 1, 1, 0, green);
    const vbuf = try env.buffer(ColorVertex, &quad, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    pass.setScissor(.{ .x = 16, .y = 8, .width = 32, .height = 16 }, .top_left);
    drawColored(env, &pass, pip, vbuf, 6, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 16, 8, rgba8(green), 0);
    try env.expectPixel(&pixels, 47, 23, rgba8(green), 0);
    try env.expectPixel(&pixels, 15, 8, rgba8(black), 0);
    try env.expectPixel(&pixels, 16, 24, rgba8(black), 0);
    try env.expectPixel(&pixels, 48, 23, rgba8(black), 0);
    try env.expectPixel(&pixels, 16, 7, rgba8(black), 0);
}

fn viewport(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const vertices = quadrantVertices();
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    // the quadrant pattern scaled into the bottom-right quarter of the target
    pass.setViewport(.{ .x = 32, .y = 32, .width = 32, .height = 32 }, .top_left);
    drawColored(env, &pass, pip, vbuf, 24, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 40, 40, rgba8(red), 0);
    try env.expectPixel(&pixels, 56, 40, rgba8(green), 0);
    try env.expectPixel(&pixels, 40, 56, rgba8(blue), 0);
    try env.expectPixel(&pixels, 56, 56, rgba8(white), 0);
    try env.expectPixel(&pixels, 16, 16, rgba8(black), 0);
    try env.expectPixel(&pixels, 48, 16, rgba8(black), 0);
}

fn blendAlpha(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const quad = rect(-1, -1, 1, 1, 0, .{ 1, 0, 0, 0.5 });
    const vbuf = try env.buffer(ColorVertex, &quad, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd, .colors = &.{.{ .format = .rgba8, .blend = .{ .src_rgb = .src_alpha, .dst_rgb = .one_minus_src_alpha } }} });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, blue);
    drawColored(env, &pass, pip, vbuf, 6, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 32, 32, .{ 128, 0, 128, 128 }, 1);
}

fn blendMax(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const quad = rect(-1, -1, 1, 1, 0, .{ 0.25, 0.75, 0.5, 1 });
    const vbuf = try env.buffer(ColorVertex, &quad, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const blend: gpu.Blend = .{ .src_rgb = .one, .dst_rgb = .one, .op_rgb = .max, .src_alpha = .one, .dst_alpha = .one, .op_alpha = .max };
    const pip = try env.colorPipeline(.{ .shader = shd, .colors = &.{.{ .format = .rgba8, .blend = blend }} });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, .{ 0.5, 0.5, 0.5, 0.5 });
    drawColored(env, &pass, pip, vbuf, 6, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(.{ 0.5, 0.75, 0.5, 1 }), 1);
}

fn depthTest(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const depth = try env.dev.createImage(.{ .width = size, .height = size, .format = .depth, .usage = .{ .depth_stencil_attachment = true } });
    defer env.dev.destroy(depth);
    const depth_view = try env.dev.createView(.{ .depth_stencil_attachment = .{ .image = depth } });
    defer env.dev.destroy(depth_view);
    // far red over everything, then near green on the left half (wins) and a
    // far-er blue on the right half (rejected); depths in [0, 1] work with both
    // clip space conventions
    const vertices = rect(-1, -1, 1, 1, 0.5, red) ++ rect(-1, -1, 0, 1, 0.25, green) ++ rect(0, -1, 1, 1, 0.75, blue);
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd, .depth = .{ .format = .depth, .compare = .less, .write = true } });
    defer env.dev.destroy(pip);
    var pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{t.view}, .depth_stencil = depth_view } }, .colors = &.{.{ .load = .{ .clear = black } }}, .depth = .{ .load = .{ .clear = 1 } } });
    drawColored(env, &pass, pip, vbuf, 18, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 16, 32, rgba8(green), 0);
    try env.expectPixel(&pixels, 48, 32, rgba8(red), 0);
}

fn stencil(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const ds = try env.dev.createImage(.{ .width = size, .height = size, .format = .depth_stencil, .usage = .{ .depth_stencil_attachment = true } });
    defer env.dev.destroy(ds);
    const ds_view = try env.dev.createView(.{ .depth_stencil_attachment = .{ .image = ds } });
    defer env.dev.destroy(ds_view);
    const vertices = rect(-1, -1, 0, 1, 0, red) ++ rect(-1, -1, 1, 1, 0, green);
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    // the first pipeline writes stencil 1 on the left half without color, the
    // second draws green where the stencil equals 1
    const write = try env.colorPipeline(.{
        .shader = shd,
        .colors = &.{.{ .format = .rgba8, .write_mask = .none }},
        .depth = .{ .format = .depth_stencil },
        .stencil = .{ .enabled = true, .front = .{ .pass = .replace }, .back = .{ .pass = .replace }, .write_mask = 0xff, .read_mask = 0xff, .ref = 1 },
    });
    defer env.dev.destroy(write);
    const test_pip = try env.colorPipeline(.{
        .shader = shd,
        .depth = .{ .format = .depth_stencil },
        .stencil = .{ .enabled = true, .front = .{ .compare = .equal }, .back = .{ .compare = .equal }, .read_mask = 0xff, .ref = 1 },
    });
    defer env.dev.destroy(test_pip);
    var pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{t.view}, .depth_stencil = ds_view } }, .colors = &.{.{ .load = .{ .clear = black } }}, .stencil = .{ .load = .{ .clear = 0 } } });
    pass.setPipeline(write);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &white);
    pass.draw(.{ .count = 6 });
    pass.setPipeline(test_pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &white);
    pass.draw(.{ .first = 6, .count = 6 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 16, 32, rgba8(green), 0);
    try env.expectPixel(&pixels, 48, 32, rgba8(black), 0);
}

/// Draws a fullscreen textured quad sampling `view`, with lod_layer uniforms.
fn drawTextured(env: *Env, t: Env.Target, comptime program: anytype, view: gpu.View, sampler: gpu.Sampler, lod_layer: [4]f32) !void {
    const vbuf = try env.buffer(TexVertex, &fullscreen_tex, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(program);
    defer env.dev.destroy(shd);
    const pip = try env.texturedPipeline(shd);
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }}, .views = &.{view}, .samplers = &.{sampler} });
    pass.setUniforms(0, &lod_layer);
    pass.draw(.{ .count = 6 });
    pass.end();
    env.dev.commit();
}

fn solid(comptime n: usize, color: [4]u8) [n * 4]u8 {
    var res: [n * 4]u8 = undefined;
    for (0..n) |i| res[i * 4 ..][0..4].* = color;
    return res;
}

fn texture2d(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const texels = rgba8(red) ++ rgba8(green) ++ rgba8(blue) ++ rgba8(white);
    const img = try env.dev.createImage(.{ .width = 2, .height = 2, .data = &.{&texels} });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{ .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
    defer env.dev.destroy(smp);
    try drawTextured(env, t, shaders.textured, view, smp, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn textureMips(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const mip0 = solid(16, rgba8(red));
    const mip1 = solid(4, rgba8(green));
    const mip2 = solid(1, rgba8(blue));
    const img = try env.dev.createImage(.{ .width = 4, .height = 4, .mip_levels = 3, .data = &.{ &mip0, &mip1, &mip2 } });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{ .mipmap_filter = .nearest });
    defer env.dev.destroy(smp);
    for ([3]f32{ 0, 1, 2 }, [3][4]f32{ red, green, blue }) |lod, color| {
        try drawTextured(env, t, shaders.textured, view, smp, .{ lod, 0, 0, 0 });
        const pixels = try env.readRendered(t.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(color), 0);
    }
    // Mip ranges work through native views or the GL/GLES base/max-level path.
    const sub = try env.dev.createView(.{ .texture = .{ .image = img, .base_mip = 1 } });
    defer env.dev.destroy(sub);
    try drawTextured(env, t, shaders.textured, sub, smp, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(green), 0);
}

fn textureArray(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const layers = solid(4, rgba8(red)) ++ solid(4, rgba8(green)) ++ solid(4, rgba8(blue));
    const img = try env.dev.createImage(.{ .type = .array, .width = 2, .height = 2, .slices = 3, .data = &.{&layers} });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{});
    defer env.dev.destroy(smp);
    for ([3][4]f32{ red, green, blue }, 0..) |color, layer| {
        try drawTextured(env, t, shaders.textured_array, view, smp, .{ 0, @floatFromInt(layer), 0, 0 });
        const pixels = try env.readRendered(t.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(color), 0);
    }
}

fn texture3d(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const slices = solid(4, rgba8(red)) ++ solid(4, rgba8(green)) ++ solid(4, rgba8(blue)) ++ solid(4, rgba8(white));
    const img = try env.dev.createImage(.{ .type = .@"3d", .width = 2, .height = 2, .slices = 4, .data = &.{&slices} });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{});
    defer env.dev.destroy(smp);
    for ([4][4]f32{ red, green, blue, white }, 0..) |color, slice| {
        const w = (@as(f32, @floatFromInt(slice)) + 0.5) / 4;
        try drawTextured(env, t, shaders.textured_3d, view, smp, .{ 0, w, 0, 0 });
        const pixels = try env.readRendered(t.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(color), 0);
    }
}

fn textureCube(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const face_colors = [6][4]f32{ red, green, blue, white, .{ 1, 1, 0, 1 }, .{ 0, 1, 1, 1 } };
    var faces: [6 * 16]u8 = undefined;
    for (face_colors, 0..) |c, i| faces[i * 16 ..][0..16].* = solid(4, rgba8(c));
    const img = try env.dev.createImage(.{ .type = .cube, .width = 2, .height = 2, .data = &.{&faces} });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{});
    defer env.dev.destroy(smp);
    for (face_colors, 0..) |color, face| {
        try drawTextured(env, t, shaders.textured_cube, view, smp, .{ 0, 0, @floatFromInt(face), 0 });
        const pixels = try env.readRendered(t.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(color), 0);
    }
}

fn renderToTexture(env: *Env) !void {
    const offscreen = try env.sampledTarget();
    defer env.destroyTarget(offscreen);
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const vertices = quadrantVertices();
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(offscreen, black);
    drawColored(env, &pass, pip, vbuf, 24, white);
    pass.end();
    const smp = try env.dev.createSampler(.{ .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
    defer env.dev.destroy(smp);
    try drawTextured(env, t, shaders.textured, offscreen.texture, smp, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(t.image);
    // texture coordinate (0,0) is the first stored row, which on backends with
    // a bottom-left framebuffer origin (GL) is the bottom of the rendered image
    const expected: [4][4]u8 = if (env.dev.features().origin_top_left) quadrant_colors else .{ quadrant_colors[2], quadrant_colors[3], quadrant_colors[0], quadrant_colors[1] };
    try env.expectQuadrants(&pixels, expected, 0);
}

fn msaaResolve(env: *Env) !void {
    if (!env.dev.formatInfo(.rgba8).msaa) return error.SkipScene;
    const msaa = try env.dev.createImage(.{ .width = size, .height = size, .format = .rgba8, .sample_count = 4, .usage = .{ .color_attachment = true } });
    defer env.dev.destroy(msaa);
    const msaa_view = try env.dev.createView(.{ .color_attachment = .{ .image = msaa } });
    defer env.dev.destroy(msaa_view);
    const resolved = try env.dev.createImage(.{ .width = size, .height = size, .format = .rgba8, .usage = .{ .resolve_attachment = true, .copy_src = true } });
    defer env.dev.destroy(resolved);
    const resolve_view = try env.dev.createView(.{ .resolve_attachment = .{ .image = resolved } });
    defer env.dev.destroy(resolve_view);
    const vertices = quadrantVertices();
    const vbuf = try env.buffer(ColorVertex, &vertices, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd, .sample_count = 4 });
    defer env.dev.destroy(pip);
    var pass = env.dev.beginPass(.{
        .target = .{ .attachments = .{ .colors = &.{msaa_view}, .resolves = &.{resolve_view} } },
        .colors = &.{.{ .load = .{ .clear = black }, .store = .dont_care }},
    });
    drawColored(env, &pass, pip, vbuf, 24, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(resolved);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn msaaTextureBinding(env: *Env) !void {
    if (!env.dev.features().msaa_texture_bindings or !env.dev.formatInfo(.rgba8).msaa) return error.SkipScene;
    const image = try env.dev.createImage(.{ .width = size, .height = size, .format = .rgba8, .sample_count = 4, .usage = .{ .color_attachment = true } });
    defer env.dev.destroy(image);
    const attachment = try env.dev.createView(.{ .color_attachment = .{ .image = image } });
    defer env.dev.destroy(attachment);
    const texture = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(texture);
    var fill = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{attachment} } }, .colors = &.{.{ .load = .{ .clear = green }, .store = .store }} });
    fill.end();
    const descriptor = if (env.backend() == .wgpu) blk: {
        var desc = feature_shaders.multisample.desc(.dummy).?;
        desc.views = &.{.{ .slot = 0, .stage = .fragment, .kind = .{ .texture = .{ .multisampled = true } }, .bindings = .{ .wgsl = 0 } }};
        desc.samplers = &.{.{ .slot = 0, .stage = .fragment, .bindings = .{ .wgsl = 1 } }};
        desc.texture_sampler_pairs = &.{.{ .stage = .fragment, .view = 0, .sampler = 0 }};
        const code =
            \\@group(1) @binding(0) var sampled_msaa: texture_multisampled_2d<f32>;
            \\@vertex fn vs_main(@location(0) position: vec2<f32>) -> @builtin(position) vec4<f32> { return vec4<f32>(position, 0.0, 1.0); }
            \\@fragment fn fs_main() -> @location(0) vec4<f32> {
            \\    return (textureLoad(sampled_msaa, vec2<i32>(0), 0) + textureLoad(sampled_msaa, vec2<i32>(0), 1) + textureLoad(sampled_msaa, vec2<i32>(0), 2) + textureLoad(sampled_msaa, vec2<i32>(0), 3)) * 0.25;
            \\}
        ;
        desc.stages = .{ .render = .{ .vertex = .{ .code = .{ .source = code }, .entry = "vs_main" }, .fragment = .{ .code = .{ .source = code }, .entry = "fs_main" } } };
        break :blk desc;
    } else if (env.legacy_gl) feature_shaders.multisample.glsl330 else feature_shaders.multisample.desc(env.backend()) orelse return error.NoShaderForBackend;
    const shader = try env.dev.createShader(descriptor);
    defer env.dev.destroy(shader);
    const pipeline = try env.dev.createPipeline(.{ .shader = shader, .vertex_attrs = &.{.{ .format = .float2 }}, .colors = &.{.{ .format = .rgba8 }}, .depth = .{ .format = .none } });
    defer env.dev.destroy(pipeline);
    const positions = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const buffer = try env.buffer([2]f32, &positions, .{});
    defer env.dev.destroy(buffer);
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const sampler = try env.dev.createSampler(.{});
    defer env.dev.destroy(sampler);
    var pass = env.beginTarget(target, black);
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{texture}, .samplers = &.{sampler} });
    pass.draw(.{ .count = 3 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(green), 0);
}

fn multipleRenderTargets(env: *Env) !void {
    if (env.dev.limits().max_color_attachments < 2) return error.SkipScene;
    const a = try env.target(.rgba8);
    defer env.destroyTarget(a);
    const b = try env.target(.rgba8);
    defer env.destroyTarget(b);
    const quad = [6][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const vbuf = try env.buffer([2]f32, &quad, .{});
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.mrt);
    defer env.dev.destroy(shd);
    const pip = try env.dev.createPipeline(.{
        .shader = shd,
        .vertex_attrs = &.{.{ .format = .float2 }},
        .colors = &.{ .{ .format = .rgba8 }, .{ .format = .rgba8 } },
        .depth = .{ .format = .none },
    });
    defer env.dev.destroy(pip);
    var pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{ a.view, b.view } } }, .colors = &.{ .{ .load = .{ .clear = black } }, .{ .load = .{ .clear = black } } } });
    pass.setPipeline(pip);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
    const params = [2][4]f32{ red, .{ 0, 0.5, 1, 1 } };
    pass.setUniforms(0, &params);
    pass.draw(.{ .count = 6 });
    pass.end();
    env.dev.commit();
    const pa = try env.readRendered(a.image);
    const pb = try env.readRendered(b.image);
    try env.expectPixel(&pa, 32, 32, rgba8(red), 0);
    try env.expectPixel(&pb, 32, 32, rgba8(.{ 0, 0.5, 1, 1 }), 0);
}

fn writeBufferTransient(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const vbuf = try env.dev.createBuffer(.{ .size = @sizeOf([6]ColorVertex), .usage = .{ .writes = .transient } });
    defer env.dev.destroy(vbuf);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    for ([4][4]f32{ red, green, blue, white }) |color| {
        const quad = rect(-1, -1, 1, 1, 0, color);
        env.dev.writeBuffer(vbuf, 0, std.mem.sliceAsBytes(&quad));
        var pass = env.beginTarget(t, black);
        drawColored(env, &pass, pip, vbuf, 6, white);
        pass.end();
        env.dev.commit();
        const pixels = try env.readRendered(t.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(color), 0);
    }
}

fn writeImageTransient(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const img = try env.dev.createImage(.{ .width = 2, .height = 2, .usage = .{ .writes = .transient } });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{});
    defer env.dev.destroy(smp);
    for ([3][4]f32{ red, green, blue }) |color| {
        const texels = solid(4, rgba8(color));
        env.dev.writeImage(img, .{}, &texels, .{});
        try drawTextured(env, t, shaders.textured, view, smp, .{ 0, 0, 0, 0 });
        const pixels = try env.readRendered(t.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(color), 0);
    }
}

fn writeUnsealed(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const img = try env.dev.createImage(.{ .width = 2, .height = 2, .usage = .{ .writes = .unsealed } });
    defer env.dev.destroy(img);
    // written in two halves before sealing
    const top = rgba8(red) ++ rgba8(green);
    const bottom = rgba8(blue) ++ rgba8(white);
    env.dev.writeImage(img, .{ .height = 1 }, &top, .{});
    env.dev.writeImage(img, .{ .y = 1 }, &bottom, .{});
    env.dev.seal(img);
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{ .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
    defer env.dev.destroy(smp);
    try drawTextured(env, t, shaders.textured, view, smp, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);

    const buf = try env.dev.createBuffer(.{ .size = 16, .usage = .{ .writes = .unsealed, .copy_src = true } });
    defer env.dev.destroy(buf);
    const values = [4]u32{ 1, 2, 3, 4 };
    env.dev.writeBuffer(buf, 0, std.mem.sliceAsBytes(values[0..2]));
    env.dev.writeBuffer(buf, 8, std.mem.sliceAsBytes(values[2..4]));
    env.dev.seal(buf);
    var out: [4]u32 = undefined;
    try env.readBuffer(buf, 0, std.mem.sliceAsBytes(&out));
    if (!std.mem.eql(u32, &out, &values)) return env.fail("unsealed buffer reads {any}", .{out});
}

fn copyBufferToBuffer(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const vertices = quadrantVertices();
    const src = try env.dev.createBuffer(.{ .usage = .{ .copy_src = true }, .data = std.mem.sliceAsBytes(&vertices) });
    defer env.dev.destroy(src);
    const dst = try env.dev.createBuffer(.{ .size = @sizeOf(@TypeOf(vertices)), .usage = .{ .vertex = true, .copy_src = true, .writes = .copy } });
    defer env.dev.destroy(dst);
    env.dev.copyBuffer(.{ .src = src, .dst = dst, .size = @sizeOf(@TypeOf(vertices)) });
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    drawColored(env, &pass, pip, dst, 24, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn copyBufferToImage(env: *Env) !void {
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const texels = rgba8(red) ++ rgba8(green) ++ rgba8(blue) ++ rgba8(white);
    // the source is a staging buffer, the only kind D3D11 can copy into images
    const staging = try env.dev.createBuffer(.{ .size = 512, .usage = .{ .staging = true, .copy_src = true, .writes = .transient } });
    defer env.dev.destroy(staging);
    // rows 256 bytes apart, as WebGPU requires for copies from GPU buffers
    var data: [512]u8 = @splat(0);
    @memcpy(data[0..8], texels[0..8]);
    @memcpy(data[256..264], texels[8..16]);
    env.dev.writeBuffer(staging, 0, &data);
    env.dev.commit();
    const img = try env.dev.createImage(.{ .width = 2, .height = 2, .usage = .{ .writes = .copy, .copy_src = true } });
    defer env.dev.destroy(img);
    env.dev.copyBufferToImage(.{ .src = staging, .layout = .{ .bytes_per_row = 256 }, .dst = img });
    env.dev.commit();
    var copied: [16]u8 = undefined;
    try env.readImage(img, .{}, &copied, .{});
    if (!std.mem.eql(u8, &copied, &texels)) return env.fail("copied texels {any}, expected {any}", .{ copied, texels });
    const view = try env.dev.createView(.{ .texture = .{ .image = img } });
    defer env.dev.destroy(view);
    const smp = try env.dev.createSampler(.{ .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
    defer env.dev.destroy(smp);
    try drawTextured(env, t, shaders.textured, view, smp, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(t.image);
    try env.expectQuadrants(&pixels, quadrant_colors, 0);
}

fn renderFormats(env: *Env) !void {
    const Case = struct { format: gpu.PixelFormat, expected: []const u8 };
    const half = 0x3800; // 0.5 as an IEEE half float
    const f32_half: u32 = @bitCast(@as(f32, 0.5));
    const cases = [_]Case{
        .{ .format = .r8, .expected = &.{128} },
        .{ .format = .rg8, .expected = &.{ 128, 64 } },
        .{ .format = .rgba16f, .expected = std.mem.asBytes(&[4]u16{ half, 0x3400, 0x3c00, 0x3c00 }) },
        .{ .format = .r32f, .expected = std.mem.asBytes(&f32_half) },
        .{ .format = .rgba32f, .expected = std.mem.asBytes(&[4]f32{ 0.5, 0.25, 1, 1 }) },
    };
    var tested: usize = 0;
    for (cases) |case| {
        const info = env.dev.formatInfo(case.format);
        if (!info.render) continue;
        tested += 1;
        const img = try env.dev.createImage(.{ .width = 4, .height = 4, .format = case.format, .usage = .{ .color_attachment = true, .copy_src = true } });
        defer env.dev.destroy(img);
        const view = try env.dev.createView(.{ .color_attachment = .{ .image = img } });
        defer env.dev.destroy(view);
        var pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{view} } }, .colors = &.{.{ .load = .{ .clear = .{ 0.5, 0.25, 1, 1 } } }} });
        pass.end();
        env.dev.commit();
        var out: [4 * 4 * 16]u8 = undefined;
        const bytes = 16 * info.bytes_per_pixel;
        try env.readImage(img, .{}, out[0..bytes], .{});
        for (0..16) |i| {
            const px = out[i * info.bytes_per_pixel ..][0..info.bytes_per_pixel];
            const tolerance: u8 = if (case.format == .r8 or case.format == .rg8) 1 else 0;
            for (px, case.expected) |g, w| {
                if (@abs(@as(i16, g) - w) > tolerance) return env.fail("{s} clear reads {any}, expected {any}", .{ @tagName(case.format), px, case.expected });
            }
        }
    }
    if (tested == 0) return error.SkipScene;
}

fn computeBuffer(env: *Env) !void {
    if (!env.dev.features().compute) return error.SkipScene;
    const count = 256;
    const buf = try env.dev.createBuffer(.{ .size = count * 4, .usage = .{ .storage = true, .copy_src = true } });
    defer env.dev.destroy(buf);
    const view = try env.dev.createView(.{ .storage_buffer = .{ .buffer = buf } });
    defer env.dev.destroy(view);
    const shd = try env.shader(compute_shaders.fill_buffer);
    defer env.dev.destroy(shd);
    const pip = try env.dev.createPipeline(.{ .shader = shd, .compute = true });
    defer env.dev.destroy(pip);
    var pass = env.dev.beginComputePass("compute_buffer");
    pass.setPipeline(pip);
    pass.setBindings(.{ .views = &.{view} });
    const params = [4]i32{ 7, 3, 0, 0 };
    pass.setUniforms(0, &params);
    pass.dispatch(count / 64, 1, 1);
    pass.end();
    env.dev.commit();
    var values: [count]u32 = undefined;
    try env.readBuffer(buf, 0, std.mem.sliceAsBytes(&values));
    for (values, 0..) |v, i| {
        if (v != 7 + 3 * i) return env.fail("values[{d}] = {d}, expected {d}", .{ i, v, 7 + 3 * i });
    }
}

fn computeImage(env: *Env) !void {
    if (!env.dev.features().compute or !env.dev.formatInfo(.rgba8).write) return error.SkipScene;
    const img = try env.dev.createImage(.{ .width = 16, .height = 16, .usage = .{ .storage = true, .copy_src = true } });
    defer env.dev.destroy(img);
    const view = try env.dev.createView(.{ .storage_image = .{ .image = img } });
    defer env.dev.destroy(view);
    const shd = try env.shader(compute_shaders.fill_image);
    defer env.dev.destroy(shd);
    const pip = try env.dev.createPipeline(.{ .shader = shd, .compute = true });
    defer env.dev.destroy(pip);
    var pass = env.dev.beginComputePass("compute_image");
    pass.setPipeline(pip);
    pass.setBindings(.{ .views = &.{view} });
    pass.dispatch(2, 4, 1);
    pass.end();
    env.dev.commit();
    var pixels: [16 * 16][4]u8 = undefined;
    try env.readImage(img, .{}, std.mem.sliceAsBytes(&pixels), .{});
    for (0..16) |y| for (0..16) |x| {
        const want = [4]u8{ @intCast(x * 16), @intCast(y * 16), 128, 255 };
        const got = pixels[y * 16 + x];
        for (got, want) |g, w| if (@abs(@as(i16, g) - w) > 1) return env.fail("texel ({d},{d}) is {any}, expected {any}", .{ x, y, got, want });
    };
}

fn computeToVertex(env: *Env) !void {
    if (!env.dev.features().compute) return error.SkipScene;
    const t = try env.target(.rgba8);
    defer env.destroyTarget(t);
    const buf = try env.dev.createBuffer(.{ .size = 6 * 32, .usage = .{ .vertex = true, .storage = true } });
    defer env.dev.destroy(buf);
    const view = try env.dev.createView(.{ .storage_buffer = .{ .buffer = buf } });
    defer env.dev.destroy(view);
    const cs = try env.shader(compute_shaders.gen_quad);
    defer env.dev.destroy(cs);
    const cpip = try env.dev.createPipeline(.{ .shader = cs, .compute = true });
    defer env.dev.destroy(cpip);
    var compute = env.dev.beginComputePass("generate");
    compute.setPipeline(cpip);
    compute.setBindings(.{ .views = &.{view} });
    const params = [2][4]f32{ .{ -1, -1, 1, 2 }, green };
    compute.setUniforms(0, &params);
    compute.dispatch(1, 1, 1);
    compute.end();
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.dev.createPipeline(.{
        .shader = shd,
        .vertex_buffers = &.{.{ .stride = 32 }},
        .vertex_attrs = &.{ .{ .format = .float3, .offset = 0 }, .{ .format = .float4, .offset = 16 } },
        .colors = &.{.{ .format = .rgba8 }},
        .depth = .{ .format = .none },
    });
    defer env.dev.destroy(pip);
    var pass = env.beginTarget(t, black);
    drawColored(env, &pass, pip, buf, 6, white);
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(t.image);
    try env.expectPixel(&pixels, 16, 32, rgba8(green), 0);
    try env.expectPixel(&pixels, 48, 32, rgba8(black), 0);
}

// A new initial upload must not advance retirement past a draw recorded earlier
// in the same frame. Repeated frame-slot reuse makes premature release visible.
fn destroyThenUpload(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    const vertices = rect(-1, -1, 1, 1, 0, red);
    for (0..100) |_| {
        const buf = try env.buffer(ColorVertex, &vertices, .{ .vertex = true });
        var pass = env.beginTarget(target, black);
        drawColored(env, &pass, pip, buf, 6, white);
        pass.end();
        env.dev.destroy(buf);
        const replacement = try env.buffer(ColorVertex, &vertices, .{ .vertex = true });
        env.dev.destroy(replacement);
        env.dev.commit();
    }
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, size / 2, size / 2, rgba8(red), 0);
}

// Unsealed buffers are CPU initialization resources, not drawable resources.
// Earlier work must retain its data when an unsealed upload happens afterwards.
fn unsealedDrawSkipped(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    const vertices = rect(-1, -1, 1, 1, 0, red);
    const buf = try env.dev.createBuffer(.{ .size = @sizeOf(@TypeOf(vertices)), .usage = .{ .vertex = true, .writes = .unsealed } });
    defer env.dev.destroy(buf);
    var pass = env.beginTarget(target, blue);
    drawColored(env, &pass, pip, buf, 6, white);
    pass.end();
    env.dev.writeBuffer(buf, 0, std.mem.sliceAsBytes(&vertices));
    env.dev.seal(buf);
    env.dev.commit();
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, size / 2, size / 2, rgba8(blue), 0);
    pass = env.beginTarget(target, black);
    drawColored(env, &pass, pip, buf, 6, white);
    pass.end();
    env.dev.commit();
    const sealed = try env.readRendered(target.image);
    try env.expectPixel(&sealed, size / 2, size / 2, rgba8(red), 0);
}

fn manyFrames(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const shd = try env.shader(shaders.color);
    defer env.dev.destroy(shd);
    const pip = try env.colorPipeline(.{ .shader = shd });
    defer env.dev.destroy(pip);
    const buf = try env.dev.createBuffer(.{ .size = 6 * @sizeOf(ColorVertex), .usage = .{ .vertex = true, .writes = .transient } });
    defer env.dev.destroy(buf);
    for (0..100) |frame| {
        const color = if (frame % 2 == 0) green else red;
        const vertices = rect(-1, -1, 1, 1, 0, color);
        env.dev.writeBuffer(buf, 0, std.mem.sliceAsBytes(&vertices));
        var pass = env.beginTarget(target, black);
        drawColored(env, &pass, pip, buf, 6, white);
        pass.end();
        env.dev.commit();
    }
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, size / 2, size / 2, rgba8(red), 0);
}

fn readbackRegions(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    var pass = env.beginTarget(target, red);
    pass.end();
    env.dev.commit();
    var pixels: [32]u8 = @splat(0xA5);
    try env.readImage(target.image, .{ .x = 1, .y = 2, .width = 3, .height = 2, .slices = 1 }, &pixels, .{ .bytes_per_row = 20 });
    for (0..2) |row| for (0..3) |col| {
        const got = pixels[row * 20 + col * 4 ..][0..4];
        if (!std.mem.eql(u8, got, &rgba8(red))) return env.fail("padded readback pixel is {any}", .{got});
    };
    // Synchronous reads preserve the caller's padding. Owned ticket snapshots
    // instead define their own padding as zero (the browser harness uses those).
    if (env.read_image == null and !env.prefer_async) for (pixels[12..20]) |padding| {
        if (padding != 0xA5) return env.fail("readback overwrote row padding", .{});
    };
    const values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const buf = try env.buffer(u8, &values, .{ .copy_src = true });
    defer env.dev.destroy(buf);
    var out: [7]u8 = undefined;
    try env.readBuffer(buf, 3, &out);
    if (!std.mem.eql(u8, &out, values[3..10])) return env.fail("unaligned readback is {any}", .{out});
    // Abandon a real map before it completes; later requests/device teardown
    // must drain its callback without leaking or dereferencing freed userdata.
    var cancelled = try env.dev.requestReadBuffer(buf, 0, values.len);
    cancelled.deinit();
}

fn shaderFailureRecovery(env: *Env) !void {
    if (env.backend() != .wgpu or @import("builtin").cpu.arch.isWasm()) return error.SkipScene;
    env.expected_diagnostic = .wgpu_create_shader_module_failed;
    const result = env.dev.createShader(.{ .stages = .{ .compute = .{ .function = .{ .code = .{ .source = "@compute @workgroup_size(1) fn main() { invalid WGSL; }" } } } } });
    if (result) |shader| {
        env.dev.destroy(shader);
        return env.fail("invalid WGSL unexpectedly created a shader", .{});
    } else |err| if (err != error.CreationFailed) return err;
    // The next valid dispatch/readback must succeed without an uncaptured error.
    try computeBuffer(env);
}

fn pipelineCacheRoundtrip(env: *Env) !void {
    if (env.backend() != .vulkan) return error.SkipScene;
    var options = env.native_options orelse return error.SkipScene;
    const bytes = try env.dev.pipelineCacheData(env.allocator);
    defer env.allocator.free(bytes);
    if (bytes.len < 32) return env.fail("pipeline cache has no valid header ({d} bytes)", .{bytes.len});
    options.backend.vulkan.pipeline_cache_data = bytes;
    var second = try gpu.Device.init(env.allocator, options);
    defer second.deinit();
    var second_env: Env = .{ .dev = &second, .allocator = env.allocator, .prefer_async = env.prefer_async };
    try triangles(&second_env);
    // Initial data is borrowed only during init; the cache survives independently.
    const saved = try second.pipelineCacheData(env.allocator);
    defer env.allocator.free(saved);
    if (saved.len < 32) return env.fail("reloaded pipeline cache has no header", .{});
    try triangles(env);
}

fn awaitTicket(ticket: *gpu.Readback) ![]const u8 {
    if (@import("builtin").cpu.arch.isWasm()) return error.SkipScene; // browser uses event-loop hooks
    for (0..1_000_000) |_| {
        if (try ticket.poll()) |bytes| return bytes;
        std.Thread.yield() catch {};
    }
    return error.ReadbackTimeout;
}
fn asyncReadbackTickets(env: *Env) !void {
    if (@import("builtin").cpu.arch.isWasm()) return error.SkipScene;
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const source = try env.buffer(u8, &values, .{ .copy_src = true });
    var pass = env.beginTarget(target, red);
    pass.end();
    env.dev.commit();
    var pixels = try env.dev.requestReadImage(target.image, .{ .x = 1, .y = 2, .width = 3, .height = 2, .slices = 1 }, .{ .bytes_per_row = 20 });
    defer pixels.deinit();
    var buffer = try env.dev.requestReadBuffer(source, 3, 7);
    defer buffer.deinit();
    env.dev.destroy(source);
    const odd = try env.buffer(u8, values[0..13], .{ .copy_src = true });
    var tail = try env.dev.requestReadBuffer(odd, 12, 1);
    defer tail.deinit();
    env.dev.destroy(odd);
    if (!std.mem.eql(u8, values[12..13], try awaitTicket(&tail))) return env.fail("async tail mismatch", .{});
    if (!std.mem.eql(u8, values[3..10], try awaitTicket(&buffer))) return env.fail("async buffer mismatch", .{});
    const data = try awaitTicket(&pixels);
    for (0..2) |row| for (0..3) |col| if (!std.mem.eql(u8, data[row * 20 + col * 4 ..][0..4], &rgba8(red))) return env.fail("async image mismatch", .{});
    for (data[12..20]) |byte| if (byte != 0) return env.fail("async padding is not zero", .{});
}
fn resourceChurn(env: *Env) !void {
    for (0..2048) |i| {
        const buffer = try env.dev.createBuffer(.{ .size = 32, .usage = .{ .vertex = true, .writes = .transient } });
        env.dev.destroy(buffer);
        if (i % 32 == 31) env.dev.commit();
    }
    env.dev.commit();
    try triangles(env);
}

fn poolExhaustionRecovery(env: *Env) !void {
    if (@import("builtin").cpu.arch.isWasm()) return error.SkipScene;
    var options = env.native_options orelse return error.SkipScene;
    options.pools.buffers = 4;
    var device = try gpu.Device.init(env.allocator, options);
    defer {
        device.deinit();
        // Both wrappers borrow the same native GL context. Its bindings changed
        // while the second device ran; invalidate the first wrapper's cache.
        env.dev.resetStateCache();
    }
    const values = [_]u8{ 3, 1, 4, 1, 5, 9, 2, 6 };
    var handles: [4]gpu.Buffer = undefined;
    var live: usize = 0;
    defer for (handles[0..live]) |handle| device.destroy(handle);
    for (&handles) |*handle| {
        handle.* = try device.createBuffer(.{ .data = &values, .usage = .{ .copy_src = true } });
        live += 1;
    }
    env.expected_diagnostic = .buffer_pool_exhausted;
    if (device.createBuffer(.{ .data = &values, .usage = .{ .copy_src = true } })) |unexpected| {
        device.destroy(unexpected);
        return env.fail("buffer pool exceeded its configured capacity", .{});
    } else |err| if (err != error.PoolExhausted) return err;
    const stale = handles[0];
    device.destroy(stale);
    handles[0] = .invalid;
    handles[0] = try device.createBuffer(.{ .data = &values, .usage = .{ .copy_src = true } });
    if (handles[0] == stale or device.state(stale) != .invalid) return env.fail("reused slot accepted a stale handle", .{});
    device.commit();
    var ticket = try device.requestReadBuffer(handles[0], 0, values.len);
    defer ticket.deinit();
    if (!std.mem.eql(u8, &values, try awaitTicket(&ticket))) return env.fail("recovered pool readback mismatch", .{});
}

// Fixed endpoint/index fixtures, independent of the tested GPU's encoder.
// Khronos Data Format 1.4, S3TC/RGTC chapters:
// https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html
const bc_red = [_]u8{ 0, 0xf8, 0xe0, 7, 0, 0, 0, 0 }; // RGB565 red/green, endpoint 0
const bc_one = [_]u8{ 255, 0, 0, 0, 0, 0, 0, 0 }; // UNORM endpoint 0 = 1
fn compressedBlock(env: *Env, format: gpu.PixelFormat, block: []const u8, expected: [4]u8) !void {
    if (!env.dev.formatInfo(format).sample) return error.SkipScene;
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const image = try env.dev.createImage(.{ .width = 4, .height = 4, .format = format, .data = &.{block} });
    defer env.dev.destroy(image);
    const view = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(view);
    const sampler = try env.dev.createSampler(.{});
    defer env.dev.destroy(sampler);
    try drawTextured(env, target, shaders.textured, view, sampler, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(target.image);
    for (0..size) |y| for (0..size) |x| try env.expectPixel(&pixels, x, y, expected, 0);
}
fn compressedBc1(env: *Env) !void {
    try compressedBlock(env, .bc1_rgba, &bc_red, rgba8(red));
}
fn compressedBc2(env: *Env) !void {
    try compressedBlock(env, .bc2_rgba, &(@as([8]u8, @splat(255)) ++ bc_red), rgba8(red));
}
fn compressedBc3(env: *Env) !void {
    try compressedBlock(env, .bc3_rgba, &(bc_one ++ bc_red), rgba8(red));
}
fn compressedBc4(env: *Env) !void {
    try compressedBlock(env, .bc4_r, &bc_one, rgba8(red));
}
fn compressedBc5(env: *Env) !void {
    try compressedBlock(env, .bc5_rg, &(bc_one ++ bc_one), .{ 255, 255, 0, 255 });
}

fn compressedBc6(env: *Env) !void {
    // BC6H mode 00, all endpoint deltas and indices zero: RGB=0, implicit A=1.
    // https://learn.microsoft.com/en-us/windows/win32/direct3d11/bc6h-format
    try compressedBlock(env, .bc6h_rgbuf, &@as([16]u8, @splat(0)), rgba8(black));
}
fn compressedBc7(env: *Env) !void {
    // BC7 mode 6 (unary 0000001), both RGBAP endpoints zero: transparent black.
    // https://learn.microsoft.com/en-us/windows/uwp/graphics-concepts/bc7-format
    const block = [_]u8{0x40} ++ @as([15]u8, @splat(0));
    try compressedBlock(env, .bc7_rgba, &block, .{ 0, 0, 0, 0 });
}

fn compressedEtc2(env: *Env) !void {
    // ETC2 individual mode: both bases=0, table=0, selector=0 (+2).
    try compressedBlock(env, .etc2_rgb8, &@as([8]u8, @splat(0)), .{ 2, 2, 2, 255 });
}
fn compressedAstc(env: *Env) !void {
    // LDR void extent, all extent coordinates 0x1fff (whole block), RGBA16
    // endpoints (65535,0,0,65535). 128-bit block stored little endian.
    const block = [_]u8{ 0xfc, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0xff, 0xff };
    try compressedBlock(env, .astc_4x4_rgba, &block, rgba8(red));
}

fn descriptorExhaustionRecovery(env: *Env) !void {
    if (env.backend() != .vulkan) return error.SkipScene;
    var options = env.native_options orelse return error.SkipScene;
    if (options.backend.vulkan.use_descriptor_buffer) return error.SkipScene;
    options.backend.vulkan.descriptor_set_capacity = 1;
    var device = try gpu.Device.init(env.allocator, options);
    defer device.deinit();
    var local: Env = .{ .dev = &device, .allocator = env.allocator, .prefer_async = env.prefer_async };
    const target = try local.target(.rgba8);
    defer local.destroyTarget(target);
    const vertices = rect(-1, -1, 1, 1, 0, white);
    const buffer = try local.buffer(ColorVertex, &vertices, .{});
    defer device.destroy(buffer);
    const shader = try local.shader(shaders.color);
    defer device.destroy(shader);
    const pipeline = try local.colorPipeline(.{ .shader = shader });
    defer device.destroy(pipeline);
    var pass = local.beginTarget(target, black);
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }} });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &red);
    pass.draw(.{ .count = 6 });
    env.expected_diagnostic = .vulkan_descriptor_pool_exhausted;
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &green);
    pass.draw(.{ .count = 6 }); // Must skip, retaining the earlier red result.
    pass.end();
    device.commit();
    const first = try local.readRendered(target.image);
    try local.expectPixel(&first, 32, 32, rgba8(red), 0);
    pass = local.beginTarget(target, black);
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }} });
    pass.setUniforms(shaders.color.uniform_blocks.color_vs_params, &identity_transform);
    pass.setUniforms(shaders.color.uniform_blocks.color_fs_params, &green);
    pass.draw(.{ .count = 6 });
    pass.end();
    device.commit();
    const recovered = try local.readRendered(target.image);
    try local.expectPixel(&recovered, 32, 32, rgba8(green), 0);
}

fn d3d12DescriptorRingRecovery(env: *Env) !void {
    if (env.backend() != .d3d12) return error.SkipScene;
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const mip0 = solid(4, rgba8(red));
    const mip1 = rgba8(green);
    const image = try env.dev.createImage(.{ .width = 2, .height = 2, .mip_levels = 2, .data = &.{ &mip0, &mip1 } });
    defer env.dev.destroy(image);
    const view = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(view);
    const sampler = try env.dev.createSampler(.{});
    defer env.dev.destroy(sampler);
    const buffer = try env.buffer(TexVertex, &fullscreen_tex, .{});
    defer env.dev.destroy(buffer);
    const shader = try env.shader(shaders.textured);
    defer env.dev.destroy(shader);
    const pipeline = try env.texturedPipeline(shader);
    defer env.dev.destroy(pipeline);
    var pass = env.beginTarget(target, black);
    pass.setPipeline(pipeline);
    const bindings: gpu.Bindings = .{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{view}, .samplers = &.{sampler} };
    const red_lod = [4]f32{ 0, 0, 0, 0 };
    const green_lod = [4]f32{ 1, 0, 0, 0 };
    pass.setUniforms(0, &red_lod);
    // D3D12's 2048-entry sampler heap is split into two 1024-entry frames.
    // This shader consumes exactly one sampler descriptor per binding update.
    for (0..1024) |_| {
        pass.setBindings(bindings);
        pass.draw(.{ .count = 6 });
    }
    env.expected_diagnostic = .d3d12_descriptor_ring_overflow;
    pass.setBindings(bindings);
    pass.setUniforms(0, &green_lod);
    pass.draw(.{ .count = 6 }); // Failed bindings must skip this green draw.
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(red), 0);
    try drawTextured(env, target, shaders.textured, view, sampler, green_lod);
    const recovered = try env.readRendered(target.image);
    try env.expectPixel(&recovered, 32, 32, rgba8(green), 0);
}

fn batchedInitialUploads(env: *Env) !void {
    if (env.backend() != .vulkan and env.backend() != .d3d12) return error.SkipScene;
    var options = env.native_options orelse return error.SkipScene;
    if (options.backend == .vulkan) options.backend.vulkan.copy_staging_buffer_size = 64;
    var device = try gpu.Device.init(env.allocator, options);
    defer device.deinit();
    device.setStatsEnabled(true);
    var local: Env = .{ .dev = &device, .allocator = env.allocator, .prefer_async = env.prefer_async };
    var buffers: [32]gpu.Buffer = undefined;
    var count: usize = 0;
    defer for (buffers[0..count]) |buffer| device.destroy(buffer);
    var source: [257]u8 = undefined;
    for (&buffers, 0..) |*buffer, i| {
        for (&source, 0..) |*byte, j| byte.* = @truncate(i + j + 1);
        buffer.* = try device.createBuffer(.{ .data = &source, .usage = .{ .copy_src = true } });
        count += 1;
        @memset(&source, 0xcc); // Caller memory may change immediately after creation.
    }
    var mip0 = solid(16, rgba8(red));
    var mip1 = solid(4, rgba8(green));
    const image = try device.createImage(.{ .width = 4, .height = 4, .mip_levels = 2, .data = &.{ &mip0, &mip1 } });
    defer device.destroy(image);
    @memset(&mip0, 0);
    @memset(&mip1, 0);
    const before = device.stats().cur_frame;
    if (device.backend() == .vulkan) {
        if (before.vk.num_queue_submits != 0 or before.vk.num_queue_wait_idle != 0) return env.fail("initial uploads submitted or waited per resource", .{});
    } else if (before.d3d12.num_queue_submits != 0 or before.d3d12.num_one_shot_submits != 0) return env.fail("D3D12 initial uploads submitted per resource", .{});
    device.commit();
    const submitted = device.stats().prev_frame;
    const submits = if (device.backend() == .vulkan) submitted.vk.num_queue_submits else submitted.d3d12.num_queue_submits;
    if (submits != 1) return env.fail("upload batch used {d} queue submissions", .{submits});
    for (buffers, 0..) |buffer, i| {
        var ticket = try device.requestReadBuffer(buffer, 0, source.len);
        defer ticket.deinit();
        const bytes = try awaitTicket(&ticket);
        for (bytes, 0..) |byte, j| if (byte != @as(u8, @truncate(i + j + 1))) return env.fail("batched buffer {d} byte {d} mismatch", .{ i, j });
    }
    const target = try local.target(.rgba8);
    defer local.destroyTarget(target);
    const view = try device.createView(.{ .texture = .{ .image = image } });
    defer device.destroy(view);
    const sampler = try device.createSampler(.{});
    defer device.destroy(sampler);
    for ([2][4]f32{ red, green }, 0..) |expected, mip| {
        try drawTextured(&local, target, shaders.textured, view, sampler, .{ @floatFromInt(mip), 0, 0, 0 });
        const pixels = try local.readRendered(target.image);
        try local.expectPixel(&pixels, 32, 32, rgba8(expected), 0);
    }
    // Compatibility reads must also flush a producer created after the last commit.
    const immediate = try device.createBuffer(.{ .data = &[_]u8{ 1, 2, 3, 4 }, .usage = .{ .copy_src = true } });
    defer device.destroy(immediate);
    var ticket = try device.requestReadBuffer(immediate, 0, 4);
    defer ticket.deinit();
    if (!std.mem.eql(u8, try awaitTicket(&ticket), &.{ 1, 2, 3, 4 })) return env.fail("read before explicit commit missed pending uploads", .{});
}

fn textureMipViewAliases(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const mip0 = solid(16, rgba8(red));
    const mip1 = solid(4, rgba8(green));
    const image = try env.dev.createImage(.{ .width = 4, .height = 4, .mip_levels = 2, .data = &.{ &mip0, &mip1 } });
    defer env.dev.destroy(image);
    const full = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(full);
    const sub = try env.dev.createView(.{ .texture = .{ .image = image, .base_mip = 1 } });
    defer env.dev.destroy(sub);
    const sampler = try env.dev.createSampler(.{});
    defer env.dev.destroy(sampler);
    const buffer = try env.buffer(TexVertex, &fullscreen_tex, .{});
    defer env.dev.destroy(buffer);
    const shader = try env.shader(shaders.texture_view_aliases);
    defer env.dev.destroy(shader);
    const pipeline = try env.texturedPipeline(shader);
    defer env.dev.destroy(pipeline);
    const fallback = (env.backend() == .gl or env.backend() == .gles) and !env.dev.features().gl_texture_views;
    var pass = env.beginTarget(target, black);
    pass.setPipeline(pipeline);
    if (fallback) env.expected_diagnostic = .gl_texture_view_mip_alias_conflict;
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{ sub, full }, .samplers = &.{sampler} });
    pass.draw(.{ .count = 6 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, if (fallback) rgba8(black) else .{ 128, 128, 0, 255 }, 1);
}
fn textureLayerViewCapability(env: *Env) !void {
    const texels = solid(4, rgba8(red)) ++ solid(4, rgba8(green));
    const image = try env.dev.createImage(.{ .type = .array, .width = 2, .height = 2, .slices = 2, .data = &.{&texels} });
    defer env.dev.destroy(image);
    const fallback = (env.backend() == .gl or env.backend() == .gles) and !env.dev.features().gl_texture_views;
    if (fallback) env.expected_diagnostic = .gl_texture_view_slice_range_unsupported;
    if (env.dev.createView(.{ .texture = .{ .image = image, .base_layer = 1, .layer_count = 1 } })) |view| {
        defer env.dev.destroy(view);
        if (fallback) return env.fail("unsupported array-layer view was silently accepted", .{});
        const target = try env.target(.rgba8);
        defer env.destroyTarget(target);
        const sampler = try env.dev.createSampler(.{});
        defer env.dev.destroy(sampler);
        try drawTextured(env, target, shaders.textured_array, view, sampler, .{ 0, 0, 0, 0 });
        const pixels = try env.readRendered(target.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(green), 0);
    } else |err| {
        if (!fallback or err != error.CreationFailed) return err;
    }
}

fn textureMipViewSwitching(env: *Env) !void {
    const image = try env.dev.createImage(.{ .width = 4, .height = 4, .mip_levels = 2, .format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    defer env.dev.destroy(image);
    const base = try env.dev.createView(.{ .color_attachment = .{ .image = image } });
    defer env.dev.destroy(base);
    const mip = try env.dev.createView(.{ .color_attachment = .{ .image = image, .mip_level = 1 } });
    defer env.dev.destroy(mip);
    for ([2]gpu.View{ base, mip }, [2][4]f32{ red, green }) |attachment, color| {
        var clearing_pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{attachment} } }, .colors = &.{.{ .load = .{ .clear = color } }} });
        clearing_pass.end();
    }
    env.dev.commit();
    const full = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(full);
    const sub = try env.dev.createView(.{ .texture = .{ .image = image, .base_mip = 1 } });
    defer env.dev.destroy(sub);
    const sampler = try env.dev.createSampler(.{});
    defer env.dev.destroy(sampler);
    const buffer = try env.buffer(TexVertex, &fullscreen_tex, .{});
    defer env.dev.destroy(buffer);
    const shader = try env.shader(shaders.textured);
    defer env.dev.destroy(shader);
    const pipeline = try env.texturedPipeline(shader);
    defer env.dev.destroy(pipeline);
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const lod = [4]f32{ 0, 0, 0, 0 };
    var pass = env.beginTarget(target, black);
    pass.setPipeline(pipeline);
    pass.setUniforms(0, &lod);
    pass.setScissor(.{ .x = 0, .y = 0, .width = size / 2, .height = size }, .top_left);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{sub}, .samplers = &.{sampler} });
    pass.draw(.{ .count = 6 });
    pass.setScissor(.{ .x = size / 2, .y = 0, .width = size / 2, .height = size }, .top_left);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{full}, .samplers = &.{sampler} });
    pass.draw(.{ .count = 6 });
    // Leave the restricted view current: later absolute image read/attachment
    // operations must restore the backing range, rather than inherit this state.
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{sub}, .samplers = &.{sampler} });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 16, 32, rgba8(green), 0);
    try env.expectPixel(&pixels, 48, 32, rgba8(red), 0);
    var parent: [4 * 4 * 4]u8 = undefined;
    try env.readImage(image, .{}, &parent, .{});
    for (0..16) |pixel| if (!std.mem.eql(u8, parent[pixel * 4 ..][0..4], &rgba8(red))) return env.fail("absolute mip read inherited a sampler view range", .{});
    // Two units keep the second texture active. Switching only A's range must
    // select unit zero even when its texture/sampler cache entry is unchanged.
    const other_image = try env.dev.createImage(.{ .width = 1, .height = 1, .data = &.{&rgba8(blue)} });
    defer env.dev.destroy(other_image);
    const other_view = try env.dev.createView(.{ .texture = .{ .image = other_image } });
    defer env.dev.destroy(other_view);
    const alias_shader = try env.shader(shaders.texture_view_aliases);
    defer env.dev.destroy(alias_shader);
    const alias_pipeline = try env.texturedPipeline(alias_shader);
    defer env.dev.destroy(alias_pipeline);
    pass = env.beginTarget(target, black);
    pass.setPipeline(alias_pipeline);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{ sub, other_view }, .samplers = &.{sampler} });
    pass.draw(.{ .count = 6 });
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }}, .views = &.{ full, other_view }, .samplers = &.{sampler} });
    pass.draw(.{ .count = 6 });
    pass.end();
    env.dev.commit();
    const switched = try env.readRendered(target.image);
    try env.expectPixel(&switched, 32, 32, .{ 128, 0, 128, 255 }, 1);
    var clearing_pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .colors = &.{base} } }, .colors = &.{.{ .load = .{ .clear = blue } }} });
    clearing_pass.end();
    env.dev.commit();
    try env.readImage(image, .{}, &parent, .{});
    for (0..16) |pixel| if (!std.mem.eql(u8, parent[pixel * 4 ..][0..4], &rgba8(blue))) return env.fail("attachment inherited a sampler view range", .{});
}

fn dualSourceBlending(env: *Env) !void {
    if (!env.dev.features().dual_source_blending) return error.SkipScene;
    var descriptor = if (env.backend() == .wgpu) feature_shaders.dual_source.desc(.dummy).? else if (env.legacy_gl) feature_shaders.dual_source.glsl330 else feature_shaders.dual_source.desc(env.backend()) orelse return error.NoShaderForBackend;
    if (env.backend() == .wgpu) {
        // The pinned shdc WGSL translator does not emit blend_src. Keep native
        // feature coverage, rather than silently disabling a supported device.
        // https://www.w3.org/TR/WGSL/#extension-dual_source_blending
        const code =
            \\enable dual_source_blending;
            \\struct Output {
            \\    @location(0) @blend_src(0) primary_color: vec4<f32>,
            \\    @location(0) @blend_src(1) secondary_color: vec4<f32>,
            \\}
            \\@vertex fn vs_main(@location(0) position: vec2<f32>) -> @builtin(position) vec4<f32> {
            \\    return vec4<f32>(position, 0.0, 1.0);
            \\}
            \\@fragment fn fs_main() -> Output {
            \\    return Output(vec4<f32>(1.0), vec4<f32>(0.25, 0.5, 0.75, 1.0));
            \\}
        ;
        descriptor.stages = .{ .render = .{ .vertex = .{ .code = .{ .source = code }, .entry = "vs_main" }, .fragment = .{ .code = .{ .source = code }, .entry = "fs_main" } } };
    }
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const shader = try env.dev.createShader(descriptor);
    defer env.dev.destroy(shader);
    const pipeline = try env.dev.createPipeline(.{ .shader = shader, .vertex_attrs = &.{.{ .format = .float2 }}, .colors = &.{.{ .format = .rgba8, .blend = .{ .src_rgb = .src1_color, .dst_rgb = .zero, .src_alpha = .one, .dst_alpha = .zero } }}, .depth = .{ .format = .none } });
    defer env.dev.destroy(pipeline);
    const positions = [_][2]f32{ .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const buffer = try env.buffer([2]f32, &positions, .{});
    defer env.dev.destroy(buffer);
    var pass = env.beginTarget(target, black);
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = buffer }} });
    pass.draw(.{ .count = 3 });
    pass.end();
    env.dev.commit();
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, .{ 64, 128, 191, 255 }, 1);
}

fn samplerAnisotropy(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const texels = solid(64, rgba8(blue));
    const image = try env.dev.createImage(.{ .width = 8, .height = 8, .data = &.{&texels} });
    defer env.dev.destroy(image);
    const view = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(view);
    const sampler = try env.dev.createSampler(.{ .min_filter = .linear, .mag_filter = .linear, .mipmap_filter = .linear, .max_anisotropy = 8 });
    defer env.dev.destroy(sampler);
    try drawTextured(env, target, shaders.textured, view, sampler, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(blue), 0);
}
fn samplerBorderColor(env: *Env) !void {
    if (!env.dev.features().image_clamp_to_border) return error.SkipScene;
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const texels = solid(4, rgba8(blue));
    const image = try env.dev.createImage(.{ .width = 2, .height = 2, .data = &.{&texels} });
    defer env.dev.destroy(image);
    const view = try env.dev.createView(.{ .texture = .{ .image = image } });
    defer env.dev.destroy(view);
    const sampler = try env.dev.createSampler(.{ .wrap_u = .clamp_to_border, .wrap_v = .clamp_to_border, .border_color = .opaque_white });
    defer env.dev.destroy(sampler);
    try drawTextured(env, target, shaders.border_sample, view, sampler, .{ 0, 0, 0, 0 });
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(blue), 0);
    try env.expectPixel(&pixels, 8, 32, rgba8(white), 0);
    try env.expectPixel(&pixels, 48, 48, rgba8(white), 0);
}
fn samplerComparison(env: *Env) !void {
    const depth_image = try env.dev.createImage(.{ .width = 4, .height = 4, .format = .depth, .usage = .{ .depth_stencil_attachment = true } });
    defer env.dev.destroy(depth_image);
    const attachment = try env.dev.createView(.{ .depth_stencil_attachment = .{ .image = depth_image } });
    defer env.dev.destroy(attachment);
    const texture = try env.dev.createView(.{ .texture = .{ .image = depth_image } });
    defer env.dev.destroy(texture);
    const sampler = try env.dev.createSampler(.{ .compare = .less_equal, .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
    defer env.dev.destroy(sampler);
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    for ([2]f32{ 0.25, 0.75 }, [2][4]f32{ black, white }) |depth, expected| {
        var clearing_pass = env.dev.beginPass(.{ .target = .{ .attachments = .{ .depth_stencil = attachment } }, .depth = .{ .load = .{ .clear = depth }, .store = .store } });
        clearing_pass.end();
        env.dev.commit();
        try drawTextured(env, target, shaders.shadow_compare, texture, sampler, .{ 0.5, 0, 0, 0 });
        const pixels = try env.readRendered(target.image);
        try env.expectPixel(&pixels, 32, 32, rgba8(expected), 0);
    }
}

fn storageImage(env: *Env, format: gpu.PixelFormat, comptime program: anytype) !gpu.Image {
    if (!env.dev.features().compute or !env.dev.formatInfo(format).write) return error.SkipScene;
    const image = try env.dev.createImage(.{ .width = 8, .height = 4, .format = format, .usage = .{ .storage = true, .copy_src = true } });
    errdefer env.dev.destroy(image);
    const view = try env.dev.createView(.{ .storage_image = .{ .image = image } });
    defer env.dev.destroy(view);
    const shader = try env.shader(program);
    defer env.dev.destroy(shader);
    const pipeline = try env.dev.createPipeline(.{ .shader = shader, .compute = true });
    defer env.dev.destroy(pipeline);
    var pass = env.dev.beginComputePass("typed_storage_image");
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .views = &.{view} });
    pass.dispatch(1, 1, 1);
    pass.end();
    env.dev.commit();
    return image;
}
fn computeImageR32ui(env: *Env) !void {
    const image = try storageImage(env, .r32ui, compute_shaders.fill_r32ui);
    defer env.dev.destroy(image);
    var values: [32]u32 = undefined;
    try env.readImage(image, .{}, std.mem.sliceAsBytes(&values), .{});
    for (values, 0..) |value, index| if (value != index + 11) return env.fail("r32ui texel {d}: {d}", .{ index, value });
}
fn computeImageRgba16f(env: *Env) !void {
    const image = try storageImage(env, .rgba16f, compute_shaders.fill_rgba16f);
    defer env.dev.destroy(image);
    var values: [32][4]f16 = undefined;
    try env.readImage(image, .{}, std.mem.sliceAsBytes(&values), .{});
    for (values) |pixel| for (pixel, [4]f16{ 0.25, 0.5, 0.75, 1 }) |value, expected| if (value != expected) return env.fail("rgba16f stored {any}", .{pixel});
}
fn computeImageRgba32f(env: *Env) !void {
    const image = try storageImage(env, .rgba32f, compute_shaders.fill_rgba32f);
    defer env.dev.destroy(image);
    var values: [32][4]f32 = undefined;
    try env.readImage(image, .{}, std.mem.sliceAsBytes(&values), .{});
    for (values) |pixel| for (pixel, [4]f32{ 0.25, 0.5, 0.75, 1 }) |value, expected| if (value != expected) return env.fail("rgba32f stored {any}", .{pixel});
}
fn largeDispatch(env: *Env) !void {
    if (!env.dev.features().compute) return error.SkipScene;
    const count = 1 << 20;
    const buffer = try env.dev.createBuffer(.{ .size = count * 4, .usage = .{ .storage = true, .copy_src = true } });
    defer env.dev.destroy(buffer);
    const view = try env.dev.createView(.{ .storage_buffer = .{ .buffer = buffer } });
    defer env.dev.destroy(view);
    const shader = try env.shader(compute_shaders.fill_buffer);
    defer env.dev.destroy(shader);
    const pipeline = try env.dev.createPipeline(.{ .shader = shader, .compute = true });
    defer env.dev.destroy(pipeline);
    var pass = env.dev.beginComputePass("large_dispatch");
    pass.setPipeline(pipeline);
    pass.setBindings(.{ .views = &.{view} });
    const params = [4]i32{ 7, 3, 0, 0 };
    pass.setUniforms(0, &params);
    pass.dispatch(count / 64, 1, 1);
    pass.end();
    env.dev.commit();
    const values = try env.allocator.alloc(u32, count);
    defer env.allocator.free(values);
    try env.readBuffer(buffer, 0, std.mem.sliceAsBytes(values));
    for (values, 0..) |value, index| if (value != 7 + index * 3) return env.fail("large dispatch item {d}: {d}", .{ index, value });
}

// Deterministic valid-operation robustness stream: the same seed and operations
// run on every real backend, with native diagnostics checked by the runner.
fn randomizedBackendStream(env: *Env) !void {
    const target = try env.target(.rgba8);
    defer env.destroyTarget(target);
    const shader = try env.shader(shaders.color);
    defer env.dev.destroy(shader);
    const pipeline = try env.colorPipeline(.{ .shader = shader });
    defer env.dev.destroy(pipeline);
    var buffers: [8]gpu.Buffer = @splat(.invalid);
    defer for (buffers) |buffer| if (buffer != .invalid) env.dev.destroy(buffer);
    var random: u32 = 0x6d2b79f5;
    var expected = white;
    for (0..128) |_| {
        var pass = env.beginTarget(target, black);
        for (0..32) |_| {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            const slot = random & 7;
            // Recycle resources after earlier draws have referenced them in the
            // open frame. New uploads must preserve both ordering and lifetime.
            if (buffers[slot] == .invalid or random & 0x18 == 0) {
                if (buffers[slot] != .invalid) env.dev.destroy(buffers[slot]);
                buffers[slot] = .invalid;
                const vertices = rect(-1, -1, 1, 1, 0, white);
                buffers[slot] = try env.buffer(ColorVertex, &vertices, .{});
            }
            expected = .{ if (random & 0x100 != 0) 1 else 0, if (random & 0x200 != 0) 1 else 0, if (random & 0x400 != 0) 1 else 0, 1 };
            drawColored(env, &pass, pipeline, buffers[slot], 6, expected);
        }
        pass.end();
        env.dev.commit();
    }
    const pixels = try env.readRendered(target.image);
    try env.expectPixel(&pixels, 32, 32, rgba8(expected), 0);
}
