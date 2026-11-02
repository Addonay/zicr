//! Tests of the public zicr.gpu API on the dummy backend.
const std = @import("std");
const gpu = @import("root.zig");

const Diagnostics = struct {
    var items: [64]gpu.LogItem = undefined;
    var count: usize = 0;

    fn record(diag: gpu.Diagnostic) void {
        if (count < items.len) {
            items[count] = diag.item;
            count += 1;
        }
    }
    fn reset() void {
        count = 0;
    }
    fn contains(item: gpu.LogItem) bool {
        return std.mem.indexOfScalar(gpu.LogItem, items[0..count], item) != null;
    }
};

fn testDevice(options: gpu.Options) !gpu.Device {
    Diagnostics.reset();
    var opts = options;
    opts.diagnostics = Diagnostics.record;
    return gpu.Device.init(std.testing.allocator, opts);
}

test "independent devices report their backend" {
    var dev = try testDevice(.{ .backend = .dummy });
    defer dev.deinit();
    try std.testing.expectEqual(gpu.Backend.dummy, dev.backend());
    var second = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer second.deinit();
    try std.testing.expectEqual(gpu.Backend.dummy, second.backend());
    try std.testing.expect(dev.limits().max_color_attachments > 0);
    try std.testing.expectEqual(@as(u32, 4), dev.formatInfo(.rgba8).bytes_per_pixel);
}

test "unavailable backends and invalid options fail without a device" {
    try std.testing.expectError(error.BackendUnavailable, gpu.Device.init(std.testing.allocator, .{ .backend = .{ .metal = .{ .device = @ptrFromInt(8) } } }));
    try std.testing.expectError(error.InvalidOptions, gpu.Device.init(std.testing.allocator, .{ .backend = .dummy, .pools = .{ .buffers = 0 } }));
    var dev = try testDevice(.{ .backend = .dummy });
    dev.deinit();
}

test "buffers are created from slices and invalid descriptors return errors" {
    var dev = try testDevice(.{ .backend = .dummy, .pools = .{ .buffers = 2 } });
    defer dev.deinit();
    const vertices = [_]f32{ 0, 1, 2, 3, 4, 5 };
    const vbuf = try dev.createBuffer(.{ .data = std.mem.sliceAsBytes(&vertices), .label = "vertices" });
    const info = dev.bufferInfo(vbuf).?;
    try std.testing.expectEqual(gpu.ResourceState.valid, info.state);
    try std.testing.expectEqual(@as(usize, 24), info.size);
    try std.testing.expect(info.usage.vertex);

    // an immutable buffer without data is invalid; the failed resource is released
    try std.testing.expectError(error.InvalidDescriptor, dev.createBuffer(.{ .size = 16 }));
    try std.testing.expect(Diagnostics.contains(.validate_bufferdesc_expect_data));
    const transient = try dev.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } });
    try std.testing.expectError(error.PoolExhausted, dev.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } }));

    dev.destroy(transient);
    try std.testing.expectEqual(gpu.ResourceState.invalid, dev.state(transient));
    _ = try dev.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } });
}

test "unsealed writes go through writeBuffer until the buffer is sealed" {
    var dev = try testDevice(.{ .backend = .dummy, .validation = .report });
    defer dev.deinit();
    const buf = try dev.createBuffer(.{ .size = 16, .usage = .{ .writes = .unsealed } });
    try std.testing.expectEqual(gpu.ResourceState.unsealed, dev.state(buf));
    const data: [16]u8 = @splat(1);
    dev.writeBuffer(buf, 0, &data);
    try std.testing.expectEqual(@as(usize, 0), Diagnostics.count);
    dev.seal(buf);
    try std.testing.expectEqual(gpu.ResourceState.valid, dev.state(buf));
    // a sealed write-unsealed buffer can't be written transiently
    dev.writeBuffer(buf, 0, &data);
    try std.testing.expect(Diagnostics.contains(.validate_writebuffertransient_usage));
}

test "images, views and samplers describe resources with Zig types" {
    var dev = try testDevice(.{ .backend = .dummy });
    defer dev.deinit();
    const pixels: [4 * 4 * 4]u8 = @splat(255);
    const img = try dev.createImage(.{ .width = 4, .height = 4, .data = &.{&pixels} });
    const info = dev.imageInfo(img).?;
    try std.testing.expectEqual(gpu.PixelFormat.rgba8, info.format);
    try std.testing.expectEqual(@as(u32, 1), info.mip_levels);

    const rt = try dev.createImage(.{ .width = 8, .height = 8, .usage = .{ .color_attachment = true } });
    const view = try dev.createView(.{ .color_attachment = .{ .image = rt } });
    try std.testing.expectEqual(gpu.ViewType.colorattachment, dev.viewInfo(view).?.type);
    try std.testing.expectEqual(rt, dev.viewInfo(view).?.image);

    const tex = try dev.createView(.{ .texture = .{ .image = img } });
    try std.testing.expectEqual(gpu.ViewType.texture, dev.viewInfo(tex).?.type);
    try std.testing.expectError(error.InvalidDescriptor, dev.createView(.{ .texture = .{ .image = img, .base_mip = 3 } }));

    _ = try dev.createSampler(.{ .min_filter = .linear, .mag_filter = .linear, .max_lod = 0 });
    try std.testing.expectError(error.InvalidDescriptor, dev.createSampler(.{ .max_anisotropy = 8 }));
}

test "a full frame records passes with pipelines, bindings, uniforms and draws" {
    var dev = try testDevice(.{ .backend = .dummy });
    defer dev.deinit();
    const shader = try dev.createShader(.{
        .stages = .{ .render = .{ .vertex = .{ .code = .{ .source = "vs" } }, .fragment = .{ .code = .{ .source = "fs" } } } },
        .uniform_blocks = &.{.{ .slot = 0, .stage = .vertex, .size = 16 }},
        .views = &.{.{ .slot = 0, .stage = .fragment, .kind = .{ .texture = .{} } }},
        .samplers = &.{.{ .slot = 0, .stage = .fragment }},
        .texture_sampler_pairs = &.{.{ .stage = .fragment, .view = 0, .sampler = 0 }},
    });
    const pip = try dev.createPipeline(.{
        .shader = shader,
        .vertex_attrs = &.{ .{ .format = .float2 }, .{ .format = .ubyte4n } },
        .index_type = .uint16,
    });
    const vertices: [12]f32 = @splat(0);
    const indices = [_]u16{ 0, 1, 2 };
    const vbuf = try dev.createBuffer(.{ .data = std.mem.sliceAsBytes(&vertices) });
    const ibuf = try dev.createBuffer(.{ .usage = .{ .index = true }, .data = std.mem.sliceAsBytes(&indices) });
    const pixels: [16]u8 = @splat(0);
    const img = try dev.createImage(.{ .width = 2, .height = 2, .data = &.{&pixels} });
    const tex = try dev.createView(.{ .texture = .{ .image = img } });
    const smp = try dev.createSampler(.{});

    var pass = dev.beginPass(.{ .target = .{ .swapchain = .{ .width = 64, .height = 64 } }, .colors = &.{.{ .load = .{ .clear = .{ 0, 0, 0, 1 } } }} });
    pass.setViewport(.{ .width = 64, .height = 64 }, .top_left);
    pass.setPipeline(pip);
    pass.setBindings(.{
        .vertex_buffers = &.{.{ .buffer = vbuf }},
        .index_buffer = .{ .buffer = ibuf },
        .views = &.{tex},
        .samplers = &.{smp},
    });
    const params: [4]f32 = .{ 1, 2, 3, 4 };
    pass.setUniforms(0, &params);
    pass.draw(.{ .count = 3 });
    pass.draw(.{ .count = 3, .instances = 2 });
    pass.end();
    dev.commit();

    try std.testing.expectEqual(@as(usize, 0), Diagnostics.count);
    const stats = dev.stats();
    try std.testing.expectEqual(@as(u32, 2), stats.prev_frame.num_draw);
    try std.testing.expectEqual(@as(u32, 16), stats.prev_frame.size_apply_uniforms);
}

test "report mode skips invalid commands, depth-only pipelines have no colors" {
    var dev = try testDevice(.{ .backend = .dummy, .validation = .report });
    defer dev.deinit();
    const shader = try dev.createShader(.{ .stages = .{ .render = .{ .vertex = .{ .code = .{ .source = "vs" } }, .fragment = .{ .code = .{ .source = "fs" } } } } });
    const depth_only = try dev.createPipeline(.{ .shader = shader, .colors = &.{}, .depth = .{ .format = .depth, .write = true, .compare = .less_equal } });
    const depth_img = try dev.createImage(.{ .width = 16, .height = 16, .format = .depth, .usage = .{ .depth_stencil_attachment = true } });
    const depth_view = try dev.createView(.{ .depth_stencil_attachment = .{ .image = depth_img } });

    var pass = dev.beginPass(.{ .target = .{ .attachments = .{ .depth_stencil = depth_view } } });
    pass.setPipeline(depth_only);
    pass.draw(.{ .count = 3 });
    pass.end();
    try std.testing.expectEqual(@as(usize, 0), Diagnostics.count);

    // a render pipeline doesn't match a compute pass: reported, and the draw is skipped
    var compute = dev.beginComputePass("compute");
    compute.setPipeline(depth_only);
    compute.dispatch(1, 1, 1);
    compute.end();
    try std.testing.expect(Diagnostics.contains(.validate_apip_renderpass_expected));
    dev.commit();
    try std.testing.expectEqual(@as(u32, 0), dev.stats().prev_frame.num_draw -| 1);
}

test "commit listeners receive their user data" {
    var dev = try testDevice(.{ .backend = .dummy });
    defer dev.deinit();
    const Counter = struct {
        fn bump(user_data: ?*anyopaque) void {
            const n: *u32 = @ptrCast(@alignCast(user_data.?));
            n.* += 1;
        }
    };
    var n: u32 = 0;
    try std.testing.expect(dev.addCommitListener(.{ .func = Counter.bump, .user_data = &n }));
    try std.testing.expect(!dev.addCommitListener(.{ .func = Counter.bump, .user_data = &n }));
    dev.commit();
    dev.commit();
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expect(dev.removeCommitListener(.{ .func = Counter.bump, .user_data = &n }));
}

test "readback validates the request and fills the destination" {
    var dev = try testDevice(.{ .backend = .dummy });
    defer dev.deinit();
    const data: [16]u8 = @splat(7);
    const readable = try dev.createBuffer(.{ .usage = .{ .copy_src = true }, .data = &data });
    var out: [8]u8 = @splat(1);
    try dev.readBuffer(readable, 4, &out);
    // the dummy backend has no GPU memory and reads zeros
    try std.testing.expectEqualSlices(u8, &(@as([8]u8, @splat(0))), &out);
    const plain = try dev.createBuffer(.{ .data = &data });
    try std.testing.expectError(error.ReadFailed, dev.readBuffer(plain, 0, &out));
    try std.testing.expect(Diagnostics.contains(.validate_readbuffer_usage));
    try std.testing.expectError(error.ReadFailed, dev.readBuffer(readable, 12, &out));
    try std.testing.expect(Diagnostics.contains(.validate_readbuffer_range));

    const rt = try dev.createImage(.{ .width = 8, .height = 4, .usage = .{ .color_attachment = true, .copy_src = true } });
    var pixels: [8 * 4 * 4]u8 = undefined;
    try dev.readImage(rt, .{}, &pixels, .{});
    try std.testing.expectError(error.ReadFailed, dev.readImage(rt, .{ .x = 4, .width = 8 }, &pixels, .{}));
    try std.testing.expect(Diagnostics.contains(.validate_readimage_region));
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.ReadFailed, dev.readImage(rt, .{}, &small, .{}));
    try std.testing.expect(Diagnostics.contains(.validate_readimage_dst_size));
}

test "owned readback tickets retain results after source destruction and validate pitches" {
    var dev = try testDevice(.{ .backend = .dummy });
    defer dev.deinit();
    const source = try dev.createBuffer(.{ .usage = .{ .copy_src = true }, .data = &@as([16]u8, @splat(1)) });
    var ticket = try dev.requestReadBuffer(source, 3, 7);
    defer ticket.deinit();
    dev.destroy(source);
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0)), (try ticket.poll()).?);
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0)), (try ticket.poll()).?);
    try std.testing.expectError(error.ReadFailed, dev.requestReadBuffer(source, 0, 4));

    const image = try dev.createImage(.{ .width = 4, .height = 2, .usage = .{ .color_attachment = true, .copy_src = true } });
    defer dev.destroy(image);
    var pixels = try dev.requestReadImage(image, .{}, .{ .bytes_per_row = 32 });
    defer pixels.deinit();
    const data = (try pixels.poll()).?;
    try std.testing.expectEqual(@as(usize, 48), data.len);
    for (data) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectError(error.ReadFailed, dev.requestReadImage(image, .{ .width = 5 }, .{}));
    try std.testing.expectError(error.ReadFailed, dev.requestReadImage(image, .{}, .{ .bytes_per_row = 1 }));
    try std.testing.expectError(error.ReadFailed, dev.requestReadImage(image, .{ .mip_level = 100 }, .{}));
}

test "devices isolate pools, handles, passes and shutdown from raw API" {
    const raw = gpu.raw;
    try raw.setup(std.testing.allocator, .dummy, .{});
    defer raw.shutdown();
    const raw_buffer = raw.makeBuffer(.{ .size = 16, .usage = .{ .write_transient = true } });
    var first = try testDevice(.{ .backend = .dummy, .pools = .{ .buffers = 1 } });
    var second = try testDevice(.{ .backend = .dummy, .pools = .{ .buffers = 1 } });
    defer second.deinit();
    const a = try first.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } });
    const b = try second.createBuffer(.{ .size = 32, .usage = .{ .writes = .transient } });
    try std.testing.expect(a != b);
    try std.testing.expectEqual(gpu.ResourceState.invalid, second.state(a));
    second.destroy(a);
    try std.testing.expectEqual(@as(usize, 32), second.bufferInfo(b).?.size);
    try std.testing.expectEqual(raw.ResourceState.valid, raw.queryBufferState(raw_buffer));
    var pass_a = first.beginPass(.{ .target = .{ .swapchain = .{ .width = 8, .height = 8 } } });
    var pass_b = second.beginPass(.{ .target = .{ .swapchain = .{ .width = 16, .height = 16 } } });
    pass_a.end();
    first.commit();
    pass_b.end();
    second.commit();
    try std.testing.expectEqual(@as(u32, 1), first.stats().prev_frame.num_passes);
    try std.testing.expectEqual(@as(u32, 1), second.stats().prev_frame.num_passes);
    first.deinit();
    try std.testing.expectEqual(gpu.ResourceState.valid, second.state(b));
    try std.testing.expectEqual(raw.ResourceState.valid, raw.queryBufferState(raw_buffer));
}

test "independent devices run on separate threads" {
    const Worker = struct {
        fn run() void {
            var dev = gpu.Device.init(std.heap.page_allocator, .{ .backend = .dummy }) catch @panic("device init");
            defer dev.deinit();
            for (0..1000) |_| {
                const buf = dev.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } }) catch @panic("buffer init");
                std.debug.assert(dev.state(buf) == .valid);
                dev.destroy(buf);
                dev.commit();
            }
        }
    };
    const first = try std.Thread.spawn(.{}, Worker.run, .{});
    const second = try std.Thread.spawn(.{}, Worker.run, .{});
    first.join();
    second.join();
}

test "device loss is sticky, delivered once, isolated and recoverable" {
    const Loss = struct {
        var calls: u32 = 0;
        var code: i32 = 0;
        fn received(event: gpu.DeviceLoss) void {
            calls += 1;
            code = event.native_code;
        }
    };
    Loss.calls = 0;
    var first = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy, .on_device_lost = Loss.received });
    var other = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer other.deinit();
    const old = try first.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } });
    first.notifyLost(-4);
    first.notifyLost(-7);
    try std.testing.expectEqual(@as(u32, 0), Loss.calls);
    try std.testing.expect(first.status() == .lost);
    try std.testing.expectEqual(@as(i32, -4), Loss.code);
    try std.testing.expect(first.status() == .lost);
    try std.testing.expectEqual(@as(u32, 1), Loss.calls);
    try std.testing.expectError(error.DeviceLost, first.createBuffer(.{ .size = 16 }));
    try std.testing.expect(other.status() == .ready);
    first.deinit();
    var recovered = try gpu.Device.init(std.testing.allocator, .{ .backend = .dummy });
    defer recovered.deinit();
    _ = try recovered.createBuffer(.{ .size = 16, .usage = .{ .writes = .transient } });
    try std.testing.expectEqual(gpu.ResourceState.invalid, recovered.state(old));
}
