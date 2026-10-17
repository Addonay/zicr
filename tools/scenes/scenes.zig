//! The cross-backend scene suite: each scene renders or computes with the
//! public zicr.gpu API, reads the result back and compares it with values
//! computed on the CPU. The same scenes run unchanged on every backend.
const std = @import("std");
const gpu = @import("zicr").gpu;
const shaders = @import("scene_shaders");
const compute_shaders = @import("scene_compute_shaders");

pub const size = 64;
pub const Pixels = [size * size][4]u8;

pub const Scene = struct {
    name: []const u8,
    run: *const fn (env: *Env) anyerror!void,
};

pub const Env = struct {
    dev: *gpu.Device,
    allocator: std.mem.Allocator,
    /// Failure details of the last scene.
    message: [256]u8 = undefined,
    message_len: usize = 0,

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
        const desc = program.desc(env.backend()) orelse return error.NoShaderForBackend;
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
        try env.dev.readImage(image, .{}, std.mem.sliceAsBytes(&pixels), .{});
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
    .{ .name = "uniform_updates", .run = uniformUpdates },
    .{ .name = "scissor", .run = scissor },
    .{ .name = "viewport", .run = viewport },
    .{ .name = "blend_alpha", .run = blendAlpha },
    .{ .name = "blend_max", .run = blendMax },
    .{ .name = "depth_test", .run = depthTest },
    .{ .name = "stencil", .run = stencil },
    .{ .name = "texture_2d", .run = texture2d },
    .{ .name = "texture_mip_levels", .run = textureMips },
    .{ .name = "texture_array", .run = textureArray },
    .{ .name = "texture_3d", .run = texture3d },
    .{ .name = "texture_cube", .run = textureCube },
    .{ .name = "render_to_texture", .run = renderToTexture },
    .{ .name = "msaa_resolve", .run = msaaResolve },
    .{ .name = "multiple_render_targets", .run = multipleRenderTargets },
    .{ .name = "write_buffer_transient", .run = writeBufferTransient },
    .{ .name = "write_image_transient", .run = writeImageTransient },
    .{ .name = "write_unsealed", .run = writeUnsealed },
    .{ .name = "copy_buffer_to_buffer", .run = copyBufferToBuffer },
    .{ .name = "copy_buffer_to_image", .run = copyBufferToImage },
    .{ .name = "render_formats", .run = renderFormats },
    .{ .name = "compute_buffer", .run = computeBuffer },
    .{ .name = "compute_image", .run = computeImage },
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
    pass.draw(.{ .count = 6, .instances = 4 });
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
    // a view restricted to mip levels 1 and 2 starts at green; GL needs texture
    // views (GL 4.3+, not GLES) to restrict mip ranges
    const backend = env.backend();
    if ((backend == .gl or backend == .gles) and !env.dev.features().gl_texture_views) return;
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
    try env.dev.readBuffer(buf, 0, std.mem.sliceAsBytes(&out));
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
    try env.dev.readImage(img, .{}, &copied, .{});
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
        try env.dev.readImage(img, .{}, out[0..bytes], .{});
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
    try env.dev.readBuffer(buf, 0, std.mem.sliceAsBytes(&values));
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
    try env.dev.readImage(img, .{}, std.mem.sliceAsBytes(&pixels), .{});
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
