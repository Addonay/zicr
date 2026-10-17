//! Shared helpers for the tests ported from the upstream sokol repository
//! (tests/functional/sokol_gfx_test.c), the equivalents of its test_logger,
//! setup() and create_* helpers.
const std = @import("std");
pub const gfx = @import("internal.zig");
pub const core = @import("core.zig");

pub const max_log_items = 32;
pub var num_log_called: usize = 0;
pub var log_items: [max_log_items]gfx.LogItem = @splat(.ok);

fn testLogger(_: ?[*:0]const u8, _: u32, log_item_id: u32, _: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    if (num_log_called < max_log_items) {
        log_items[num_log_called] = @fromBackingInt(@intCast(log_item_id));
        num_log_called += 1;
    }
}

pub fn resetLogItems() void {
    num_log_called = 0;
    log_items = @splat(.ok);
}

/// Sets up the dummy backend with the capturing test logger, like the upstream setup().
pub fn setup(desc: gfx.Desc) void {
    resetLogItems();
    var desc_with_logger = desc;
    desc_with_logger.logger.func = testLogger;
    gfx.setup(std.testing.allocator, .dummy, desc_with_logger) catch |err| std.debug.panic("setup failed: {s}", .{@errorName(err)});
}

pub fn createBuffer() gfx.Buffer {
    const data = [_]f32{ 1, 2, 3, 4 };
    return gfx.makeBuffer(.{ .data = gfx.Range.fromSlice(f32, &data) });
}

pub fn createImage() gfx.Image {
    return gfx.makeImage(.{ .usage = .{ .color_attachment = true }, .width = 256, .height = 128 });
}

pub fn createShader() gfx.Shader {
    return gfx.makeShader(.{});
}

pub fn createPipeline() gfx.Pipeline {
    var desc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(.{}) };
    desc.layout.attrs[0].format = .float3;
    return gfx.makePipeline(desc);
}

pub fn createView() gfx.View {
    return gfx.makeView(.{ .color_attachment = .{ .image = gfx.makeImage(.{ .usage = .{ .color_attachment = true }, .width = 128, .height = 128 }) } });
}
