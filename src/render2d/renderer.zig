//! GPU execution of an ordered draw list. Owns GPU objects; borrows the Device.
const std = @import("std");
const gpu = @import("gpu");
const draw = @import("draw_list.zig");

pub const Options = struct {
    max_quads: u32 = 16384,
    color_format: gpu.PixelFormat = .rgba8,
    depth_format: gpu.PixelFormat = .none,
    sample_count: u32 = 1,
};
pub const Error = error{ DeviceLost, InvalidDimensions, CapacityExceeded, AlreadySubmitted, InvalidTexture, UnbalancedClips, InvalidTarget };
pub const Stats = struct { quads: u32 = 0, batches: u32 = 0, upload_bytes: usize = 0 };

/// Do not copy after initialization. Destroy before its borrowed Device.
/// Call `submit` at most once per Device commit; use multiple renderers for
/// independent passes. A submission never commits or presents the frame.
pub const Renderer = struct {
    device: *gpu.Device,
    shader: gpu.Shader,
    pipeline: gpu.Pipeline,
    vertices: gpu.Buffer,
    white_image: gpu.Image,
    white_view: gpu.View,
    sampler: gpu.Sampler,
    capacity: u32,
    config: Options,
    last_frame: ?u32 = null,
    stats: Stats = .{},

    /// `shader_desc` comes from src/render2d/shaders.glsl through addShaderModule.
    /// The shader descriptor is consumed during initialization, not retained.
    pub fn init(device: *gpu.Device, shader_desc: gpu.ShaderDesc, options: Options) !Renderer {
        if (options.max_quads == 0 or options.max_quads > std.math.maxInt(u32) / 6 or options.sample_count == 0) return error.InvalidDimensions;
        const shader = try device.createShader(shader_desc);
        errdefer device.destroy(shader);
        const pipeline = try device.createPipeline(.{
            .shader = shader,
            .vertex_buffers = &.{.{ .stride = @sizeOf(draw.Vertex) }},
            .vertex_attrs = &.{ .{ .format = .float2, .offset = @offsetOf(draw.Vertex, "position") }, .{ .format = .float2, .offset = @offsetOf(draw.Vertex, "uv") }, .{ .format = .float4, .offset = @offsetOf(draw.Vertex, "color") }, .{ .format = .float, .offset = @offsetOf(draw.Vertex, "premultiplied") } },
            .colors = &.{.{ .format = options.color_format, .blend = .{ .src_rgb = .one, .dst_rgb = .one_minus_src_alpha, .src_alpha = .one, .dst_alpha = .one_minus_src_alpha } }},
            .depth = .{ .format = options.depth_format },
            .sample_count = options.sample_count,
            .label = "zicr 2D painter-order pipeline",
        });
        errdefer device.destroy(pipeline);
        const vertices = try device.createBuffer(.{ .size = @as(usize, options.max_quads) * 6 * @sizeOf(draw.Vertex), .usage = .{ .vertex = true, .writes = .transient }, .label = "zicr 2D frame vertices" });
        errdefer device.destroy(vertices);
        const pixel = [_]u8{ 255, 255, 255, 255 };
        const white_image = try device.createImage(.{ .width = 1, .height = 1, .format = .rgba8, .data = &.{&pixel} });
        errdefer device.destroy(white_image);
        const white_view = try device.createView(.{ .texture = .{ .image = white_image } });
        errdefer device.destroy(white_view);
        const sampler = try device.createSampler(.{ .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
        return .{ .device = device, .shader = shader, .pipeline = pipeline, .vertices = vertices, .white_image = white_image, .white_view = white_view, .sampler = sampler, .capacity = options.max_quads * 6, .config = options };
    }
    fn validateTarget(self: *Renderer, list: *const draw.DrawList, target: gpu.PassDesc) Error!gpu.Image {
        if (target.colors.len > 1) return error.InvalidTarget;
        switch (target.target) {
            .swapchain => |sc| {
                if (sc.invalid or sc.width != list.width or sc.height != list.height) return error.InvalidTarget;
                if (sc.color_format) |format| if (format != self.config.color_format) return error.InvalidTarget;
                if (sc.depth_format) |format| if (format != self.config.depth_format) return error.InvalidTarget;
                if (sc.sample_count) |samples| if (samples != self.config.sample_count) return error.InvalidTarget;
                return .invalid;
            },
            .attachments => |attachments| {
                if (attachments.colors.len != 1 or attachments.resolves.len > 1) return error.InvalidTarget;
                const view = self.device.viewInfo(attachments.colors[0]) orelse return error.InvalidTarget;
                if (view.state != .valid or view.type != .colorattachment) return error.InvalidTarget;
                const image = self.device.imageInfo(view.image) orelse return error.InvalidTarget;
                // The initial renderer targets full-size base-mip attachment views.
                if (image.width != list.width or image.height != list.height or image.format != self.config.color_format or image.sample_count != self.config.sample_count) return error.InvalidTarget;
                if (self.config.depth_format == .none) {
                    if (attachments.depth_stencil != .invalid) return error.InvalidTarget;
                } else {
                    const depth_view = self.device.viewInfo(attachments.depth_stencil) orelse return error.InvalidTarget;
                    if (depth_view.state != .valid or depth_view.type != .depthstencilattachment) return error.InvalidTarget;
                    const depth = self.device.imageInfo(depth_view.image) orelse return error.InvalidTarget;
                    if (depth.format != self.config.depth_format or depth.width != image.width or depth.height != image.height or depth.sample_count != image.sample_count) return error.InvalidTarget;
                }
                if (attachments.resolves.len == 1 and attachments.resolves[0] != .invalid) {
                    const resolve_view = self.device.viewInfo(attachments.resolves[0]) orelse return error.InvalidTarget;
                    if (resolve_view.state != .valid or resolve_view.type != .resolveattachment) return error.InvalidTarget;
                    const resolve = self.device.imageInfo(resolve_view.image) orelse return error.InvalidTarget;
                    if (image.sample_count == 1 or resolve.sample_count != 1 or resolve.format != image.format or resolve.width != image.width or resolve.height != image.height) return error.InvalidTarget;
                }
                return view.image;
            },
        }
    }
    pub fn deinit(self: *Renderer) void {
        self.device.destroy(self.pipeline);
        self.device.destroy(self.shader);
        self.device.destroy(self.vertices);
        self.device.destroy(self.white_view);
        self.device.destroy(self.white_image);
        self.device.destroy(self.sampler);
        self.* = undefined;
    }
    /// Begin/end one pass with exactly the caller's load/store actions. Geometry
    /// and texture metadata are checked before starting the pass or uploading.
    /// Target dimensions must match DrawList.reset; target formats must match init.
    pub fn submit(self: *Renderer, list: *const draw.DrawList, target: gpu.PassDesc) Error!void {
        if (self.device.status() == .lost) return error.DeviceLost;
        if (list.width <= 0 or list.height <= 0) return error.InvalidDimensions;
        if (list.clip_depth != 0) return error.UnbalancedClips;
        if (list.vertex_count > self.capacity) return error.CapacityExceeded;
        const frame = self.device.stats().prev_frame.frame_index;
        if (self.last_frame == frame) return error.AlreadySubmitted;
        const attachment_image = try self.validateTarget(list, target);
        for (list.batchData()) |batch| {
            if (batch.texture.view != .invalid) {
                const view = self.device.viewInfo(batch.texture.view) orelse return error.InvalidTexture;
                if (view.state != .valid or view.type != .texture) return error.InvalidTexture;
                if (view.image == attachment_image) return error.InvalidTexture;
                const image = self.device.imageInfo(view.image) orelse return error.InvalidTexture;
                const format = self.device.formatInfo(image.format);
                if (image.type != .@"2d" or image.sample_count != 1 or !format.sample or !format.filter or format.depth) return error.InvalidTexture;
            }
            if (batch.texture.sampler != .invalid and self.device.state(batch.texture.sampler) != .valid) return error.InvalidTexture;
        }
        const bytes = std.mem.sliceAsBytes(list.vertexData());
        if (bytes.len != 0) self.device.writeBuffer(self.vertices, 0, bytes);
        var pass = self.device.beginPass(target);
        pass.setViewport(.{ .width = list.width, .height = list.height }, .top_left);
        if (list.batch_count != 0) pass.setPipeline(self.pipeline);
        for (list.batchData()) |batch| {
            pass.setScissor(batch.clip, .top_left);
            pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = self.vertices }}, .views = &.{if (batch.texture.view == .invalid) self.white_view else batch.texture.view}, .samplers = &.{if (batch.texture.sampler == .invalid) self.sampler else batch.texture.sampler} });
            pass.draw(.{ .first = batch.first, .count = batch.count });
        }
        pass.end();
        self.last_frame = frame;
        self.stats = .{ .quads = list.vertex_count / 6, .batches = list.batch_count, .upload_bytes = bytes.len };
        if (self.device.status() == .lost) return error.DeviceLost;
    }
};

const dummy_shader: gpu.ShaderDesc = .{
    .stages = .{ .render = .{ .vertex = .{ .code = .{ .source = "vs" } }, .fragment = .{ .code = .{ .source = "fs" } } } },
    .attrs = &.{ .{ .base_type = .float }, .{ .base_type = .float }, .{ .base_type = .float }, .{ .base_type = .float } },
    .views = &.{.{ .slot = 0, .stage = .fragment, .kind = .{ .texture = .{} } }},
    .samplers = &.{.{ .slot = 0, .stage = .fragment }},
    .texture_sampler_pairs = &.{.{ .stage = .fragment, .view = 0, .sampler = 0 }},
};

test "renderer rejects foreign resources and unbalanced clips before submitting" {
    var device = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer device.deinit();
    var other = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer other.deinit();
    var renderer = try Renderer.init(&device, dummy_shader, .{ .max_quads = 2 });
    defer renderer.deinit();
    var list = try draw.DrawList.init(std.testing.allocator, .{ .max_quads = 2 });
    defer list.deinit();
    const image = try other.createImage(.{ .width = 1, .height = 1, .data = &.{&.{ 1, 2, 3, 255 }} });
    defer other.destroy(image);
    const view = try other.createView(.{ .texture = .{ .image = image } });
    defer other.destroy(view);
    const target: gpu.PassDesc = .{ .target = .{ .swapchain = .{ .width = 8, .height = 8, .color_format = .rgba8, .depth_format = .none } } };
    try list.reset(8, 8, null);
    try list.quad(.{ .rect = .{ .width = 8, .height = 8 }, .texture = .{ .view = view } });
    try std.testing.expectError(error.InvalidTexture, renderer.submit(&list, target));
    try list.reset(8, 8, null);
    try list.pushClip(.{ .width = 4, .height = 4 });
    try std.testing.expectError(error.UnbalancedClips, renderer.submit(&list, target));
    try list.popClip();
    try list.rect(.{ .width = 8, .height = 8 }, .{});
    try renderer.submit(&list, target);
    try std.testing.expectError(error.AlreadySubmitted, renderer.submit(&list, target));
    device.commit();
    try renderer.submit(&list, target);
    device.commit();
    try std.testing.expectEqual(@as(u32, 1), renderer.stats.quads);
}

test "GPU initialization failure releases partially created resources" {
    const Ignore = struct {
        fn diagnostic(_: gpu.Diagnostic) void {}
    };
    var device = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy, .pools = .{ .samplers = 1 }, .diagnostics = Ignore.diagnostic });
    defer device.deinit();
    device.setStatsEnabled(true);
    const occupied = try device.createSampler(.{});
    defer device.destroy(occupied);
    try std.testing.expectError(error.PoolExhausted, Renderer.init(&device, dummy_shader, .{}));
    const resources = device.stats().total;
    try std.testing.expectEqual(@as(u32, 0), resources.shaders.alive);
    try std.testing.expectEqual(@as(u32, 0), resources.pipelines.alive);
    try std.testing.expectEqual(@as(u32, 0), resources.buffers.alive);
    try std.testing.expectEqual(@as(u32, 0), resources.images.alive);
    try std.testing.expectEqual(@as(u32, 0), resources.views.alive);
    try std.testing.expectEqual(@as(u32, 1), resources.samplers.alive);
}

test "capacity, target mismatch and device loss fail before frame submission" {
    const Ignore = struct {
        fn diagnostic(_: gpu.Diagnostic) void {}
    };
    var device = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy, .diagnostics = Ignore.diagnostic });
    defer device.deinit();
    var renderer = try Renderer.init(&device, dummy_shader, .{ .max_quads = 1 });
    defer renderer.deinit();
    var list = try draw.DrawList.init(std.testing.allocator, .{ .max_quads = 2 });
    defer list.deinit();
    try list.reset(8, 8, null);
    try list.rect(.{ .width = 2, .height = 2 }, .{});
    try list.rect(.{ .x = 2, .width = 2, .height = 2 }, .{});
    const target: gpu.PassDesc = .{ .target = .{ .swapchain = .{ .width = 8, .height = 8, .color_format = .rgba8, .depth_format = .none } } };
    try std.testing.expectError(error.CapacityExceeded, renderer.submit(&list, target));
    try list.reset(8, 8, null);
    try list.rect(.{ .width = 2, .height = 2 }, .{});
    var wrong = target;
    wrong.target.swapchain.width = 4;
    try std.testing.expectError(error.InvalidTarget, renderer.submit(&list, wrong));
    wrong = target;
    wrong.target.swapchain.color_format = .bgra8;
    try std.testing.expectError(error.InvalidTarget, renderer.submit(&list, wrong));
    try renderer.submit(&list, target);
    device.commit();
    device.notifyLost(-1);
    try std.testing.expectError(error.DeviceLost, renderer.submit(&list, target));
}
