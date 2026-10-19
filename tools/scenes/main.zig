//! Runs the cross-backend scene suite.
//!
//! usage: zicr-scenes [--backend gl|gles|gl_legacy|gles_legacy|vulkan|wgpu|d3d11|d3d12]...
//!                    [--filter text] [--portable-limits]
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
    var first_item: gpu.LogItem = .ok;

    fn record(diag: gpu.Diagnostic) void {
        if (diag.level != .err and diag.level != .panic) return;
        if (errors == 0) {
            first_item = diag.item;
            const msg = std.fmt.bufPrint(&first, "{s}", .{diag.message orelse @tagName(diag.item)}) catch &first;
            first_len = msg.len;
        }
        errors += 1;
    }
};

const platform_variants: []const harness.Variant = switch (builtin.os.tag) {
    .linux => &.{ .gl, .gles, .gl_legacy, .gles_legacy, .vulkan, .vulkan_descriptor_buffer, .wgpu },
    .windows => &.{ .d3d11, .d3d12, .vulkan },
    .macos, .ios => &.{.metal},
    else => &.{},
};

const Totals = struct { passed: u32 = 0, failed: u32 = 0, skipped: u32 = 0 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var variants: std.ArrayList(harness.Variant) = .empty;
    var filter: ?[]const u8 = null;
    var portable_limits = false;
    var require_validation = false;
    var prefer_async = false;
    var window_smoke = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--window-smoke")) {
            window_smoke = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--async-readback")) {
            prefer_async = true;
            continue;
        }
        if ((std.mem.eql(u8, args[i], "--require-d3d12-validation") or std.mem.eql(u8, args[i], "--require-native-validation"))) {
            require_validation = true;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--portable-limits")) {
            portable_limits = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingArgumentValue;
        if (std.mem.eql(u8, args[i], "--backend")) {
            try variants.append(init.arena.allocator(), std.meta.stringToEnum(harness.Variant, args[i + 1]) orelse return error.UnknownBackend);
        } else if (std.mem.eql(u8, args[i], "--filter")) {
            filter = args[i + 1];
        } else return error.UnknownArgument;
        i += 1;
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
                    try runVariant(Context, gpa, v, filter, portable_limits, require_validation, prefer_async, window_smoke, &totals);
                }
            },
        }
    }
    std.debug.print("\nscenes: {d} passed, {d} failed, {d} skipped\n", .{ totals.passed, totals.failed, totals.skipped });
    if (totals.failed > 0) std.process.exit(1);
}

fn runVariant(comptime Context: type, gpa: std.mem.Allocator, variant: harness.Variant, filter: ?[]const u8, portable_limits: bool, require_validation: bool, prefer_async: bool, window_smoke: bool, totals: *Totals) !void {
    const creation = if (window_smoke) blk: {
        if (comptime @hasDecl(Context, "createWindow")) break :blk Context.createWindow(gpa, variant);
        std.debug.print("{s}: window host is not implemented\n", .{@tagName(variant)});
        totals.failed += 1;
        return;
    } else Context.create(gpa, variant);
    const ctx = creation catch |err| {
        std.debug.print("{s}: device creation failed: {s}\n", .{ @tagName(variant), @errorName(err) });
        totals.failed += 1;
        return;
    };
    defer ctx.destroy();
    if (ctx.takeNativeErrors() != 0) {
        std.debug.print("{s}: native validation failed during context creation\n", .{@tagName(variant)});
        totals.failed += 1;
        return;
    }
    if (comptime @hasDecl(Context, "validationAvailable")) {
        if (require_validation and !ctx.validationAvailable()) {
            std.debug.print("{s}: required native GPU validation is unavailable\n", .{@tagName(variant)});
            totals.failed += 1;
            return;
        }
    } else if (require_validation) {
        std.debug.print("{s}: no native validation availability probe\n", .{@tagName(variant)});
        totals.failed += 1;
        return;
    }
    var options = ctx.options();
    options.diagnostics = Diagnostics.record;
    options.portable_limits = portable_limits;
    options.validation = .report;
    var dev = gpu.Device.init(gpa, options) catch |err| {
        std.debug.print("{s}: gpu device init failed: {s}\n", .{ @tagName(variant), @errorName(err) });
        totals.failed += 1;
        return;
    };
    defer {
        Diagnostics.errors = 0;
        dev.deinit();
        const native = ctx.takeNativeErrors();
        if (native > 0 or Diagnostics.errors > 0) {
            std.debug.print("{s}: teardown failed: {d} native errors, {d} diagnostics\n", .{ @tagName(variant), native, Diagnostics.errors });
            totals.failed += 1;
        }
    }
    std.debug.print("\n{s} ({s})\n", .{ @tagName(variant), ctx.description() });
    if (ctx.takeNativeErrors() != 0) {
        std.debug.print("{s}: native validation failed during GPU initialization\n", .{@tagName(variant)});
        totals.failed += 1;
        return;
    }
    if (window_smoke) {
        if (comptime @hasDecl(Context, "present")) {
            for (0..32) |frame| {
                const swapchain: gpu.Swapchain = if (comptime @hasDecl(Context, "acquireSwapchain")) try ctx.acquireSwapchain() else .{ .width = 64, .height = 64, .color_format = .rgba8, .depth_format = .none, .native = .{ .gl = .{} } };
                var pass = dev.beginPass(.{ .target = .{ .swapchain = swapchain }, .colors = &.{.{ .load = .{ .clear = if (frame & 1 == 0) .{ 1, 0, 0, 1 } else .{ 0, 0, 1, 1 } }, .store = .store }} });
                pass.end();
                dev.commit();
                if (comptime @hasDecl(Context, "verifyWindow")) {
                    if (frame == 31) try ctx.verifyWindow(&dev);
                }
                ctx.present(frame == 31) catch |err| {
                    std.debug.print("  FAIL window_presentation: {s}\n", .{@errorName(err)});
                    totals.failed += 1;
                    return;
                };
            }
            if (ctx.takeNativeErrors() != 0 or Diagnostics.errors != 0) {
                std.debug.print("  FAIL window_presentation: diagnostics\n", .{});
                totals.failed += 1;
            } else {
                std.debug.print("  ok   window_presentation (32 frames, final pixel verified)\n", .{});
                totals.passed += 1;
            }
            return;
        }
    }
    for (scenes.all) |scene| {
        if (filter) |f| if (std.mem.indexOf(u8, scene.name, f) == null) continue;
        Diagnostics.errors = 0;
        var env: scenes.Env = .{ .dev = &dev, .allocator = gpa, .native_options = options, .prefer_async = prefer_async, .legacy_gl = variant == .gl_legacy };
        const result = scene.run(&env);
        const native = ctx.takeNativeErrors();
        if (dev.status() == .lost) {
            std.debug.print("  FAIL {s}: device lost\n", .{scene.name});
            totals.failed += 1;
            break;
        }
        if (result) |_| {
            const diagnostics_match = if (env.expected_diagnostic) |expected|
                Diagnostics.errors == 1 and Diagnostics.first_item == expected
            else
                Diagnostics.errors == 0;
            if (!diagnostics_match) {
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
