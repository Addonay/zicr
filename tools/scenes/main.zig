//! Runs the cross-backend scene suite.
//!
//! usage: zicr-scenes [--backend gl|gles|gles_legacy|vulkan|wgpu|d3d11]... [--filter text]
//! Without --backend, all backends of the platform run.
const std = @import("std");
const builtin = @import("builtin");
const gpu = @import("zicr").gpu;
const harness = @import("harness");
const scenes = @import("scenes.zig");

const Diagnostics = struct {
    var errors: u32 = 0;
    var first: [200]u8 = undefined;
    var first_len: usize = 0;

    fn record(diag: gpu.Diagnostic) void {
        if (diag.level != .err and diag.level != .panic) return;
        if (errors == 0) {
            const msg = std.fmt.bufPrint(&first, "{s}", .{diag.message orelse @tagName(diag.item)}) catch &first;
            first_len = msg.len;
        }
        errors += 1;
    }
};

const platform_variants: []const harness.Variant = switch (builtin.os.tag) {
    .linux => &.{ .gl, .gles, .vulkan, .wgpu },
    .windows => &.{ .d3d11, .d3d12, .vulkan },
    else => &.{},
};

const Totals = struct { passed: u32 = 0, failed: u32 = 0, skipped: u32 = 0 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var variants: std.ArrayList(harness.Variant) = .empty;
    var filter: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingArgumentValue;
        if (std.mem.eql(u8, args[i], "--backend")) {
            try variants.append(init.arena.allocator(), std.meta.stringToEnum(harness.Variant, args[i + 1]) orelse return error.UnknownBackend);
        } else if (std.mem.eql(u8, args[i], "--filter")) {
            filter = args[i + 1];
        } else return error.UnknownArgument;
    }
    const selected = if (variants.items.len > 0) variants.items else platform_variants;

    var totals: Totals = .{};
    for (selected) |variant| {
        switch (variant) {
            inline else => |v| {
                const Context = harness.contextFor(v);
                if (Context == void) {
                    std.debug.print("{s}: not available on this platform\n", .{@tagName(v)});
                    totals.skipped += 1;
                } else {
                    try runVariant(Context, gpa, v, filter, &totals);
                }
            },
        }
    }
    std.debug.print("\nscenes: {d} passed, {d} failed, {d} skipped\n", .{ totals.passed, totals.failed, totals.skipped });
    if (totals.failed > 0) std.process.exit(1);
}

fn runVariant(comptime Context: type, gpa: std.mem.Allocator, variant: harness.Variant, filter: ?[]const u8, totals: *Totals) !void {
    const ctx = Context.create(gpa, variant) catch |err| {
        std.debug.print("{s}: device creation failed: {s}\n", .{ @tagName(variant), @errorName(err) });
        totals.failed += 1;
        return;
    };
    defer ctx.destroy();
    var options = ctx.options();
    options.diagnostics = Diagnostics.record;
    options.validation = .report;
    var dev = gpu.Device.init(gpa, options) catch |err| {
        std.debug.print("{s}: gpu device init failed: {s}\n", .{ @tagName(variant), @errorName(err) });
        totals.failed += 1;
        return;
    };
    defer dev.deinit();
    std.debug.print("\n{s} ({s})\n", .{ @tagName(variant), ctx.description() });
    _ = ctx.takeNativeErrors();
    for (scenes.all) |scene| {
        if (filter) |f| if (std.mem.indexOf(u8, scene.name, f) == null) continue;
        Diagnostics.errors = 0;
        var env: scenes.Env = .{ .dev = &dev, .allocator = gpa };
        const result = scene.run(&env);
        const native = ctx.takeNativeErrors();
        if (result) |_| {
            if (Diagnostics.errors > 0) {
                std.debug.print("  FAIL {s}: {d} diagnostics, first: {s}\n", .{ scene.name, Diagnostics.errors, Diagnostics.first[0..Diagnostics.first_len] });
                totals.failed += 1;
            } else if (native > 0) {
                std.debug.print("  FAIL {s}: {d} native API errors\n", .{ scene.name, native });
                totals.failed += 1;
            } else {
                std.debug.print("  ok   {s}\n", .{scene.name});
                totals.passed += 1;
            }
        } else |err| switch (err) {
            error.SkipScene => {
                std.debug.print("  skip {s}\n", .{scene.name});
                totals.skipped += 1;
            },
            error.Mismatch => {
                std.debug.print("  FAIL {s}: {s}\n", .{ scene.name, env.failure() });
                if (Diagnostics.errors > 0) std.debug.print("       {d} diagnostics, first: {s}\n", .{ Diagnostics.errors, Diagnostics.first[0..Diagnostics.first_len] });
                totals.failed += 1;
            },
            else => {
                const first = if (Diagnostics.errors > 0) Diagnostics.first[0..Diagnostics.first_len] else "";
                std.debug.print("  FAIL {s}: {s} {s}\n", .{ scene.name, @errorName(err), first });
                totals.failed += 1;
            },
        }
    }
}
