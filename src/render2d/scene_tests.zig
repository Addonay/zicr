//! Implementation-phase tests; intentionally not executed until the full design exists.
const std=@import("std");
const scenes=@import("scene.zig");
const Canvas=@import("canvas.zig").Canvas;
const paints=@import("paint.zig");
test "scene snapshots gradient stops and immutable clip state survives save restore" {
    var scene=try scenes.Scene.init(std.testing.allocator);defer scene.deinit();
    var canvas=try Canvas.init(&scene);defer canvas.deinit();
    var stops=[2]paints.Stop{.{.offset=0,.color=.{.r=1}},.{.offset=1,.color=.{.b=1}}};
    try canvas.setPaint(.{.linear=.{.gradient=.{.stops=&stops},.start=.{},.end=.{.x=10}}});
    stops[0].color=.white;
    canvas.beginPath();
    try canvas.current_path.addRect(.{.width=10,.height=10});
    try canvas.clip(.nonzero,false);const original=canvas.state.clip;
    try canvas.save();canvas.resetClip();try canvas.translate(3,4);try canvas.restore();
    try std.testing.expectEqual(original,canvas.state.clip);
    try std.testing.expectEqual(@as(f64,0),canvas.state.transform.tx);
    try canvas.fillRect(.{.width=10,.height=10});
    const recorded=scene.paintValue(canvas.state.paint).linear.gradient;
    try std.testing.expectEqual(@as(f64,1),recorded.stops[0].color.r);
    try std.testing.expectEqual(@as(f64,0),recorded.stops[0].color.g);
}
test "foreign and stale scene resource handles are rejected" {
    var a=try scenes.Scene.init(std.testing.allocator);defer a.deinit();
    var b=try scenes.Scene.init(std.testing.allocator);defer b.deinit();
    var canvas=try Canvas.init(&a);defer canvas.deinit();
    const foreign=try b.addPaint(.{.solid=.white});var state=canvas.state;state.paint=foreign;
    const path=try a.addPath(&canvas.current_path);
    try std.testing.expectError(error.InvalidHandle,a.fill(path,state,.nonzero));
    const saved=canvas.state;try a.reset();
    var fresh=try Canvas.init(&a);defer fresh.deinit();
    const next=try a.addPath(&fresh.current_path);
    try std.testing.expectError(error.InvalidHandle,a.fill(next,saved,.nonzero));
}
test "restore does not accidentally cross an explicit layer boundary" {
    var scene=try scenes.Scene.init(std.testing.allocator);defer scene.deinit();var canvas=try Canvas.init(&scene);defer canvas.deinit();
    try canvas.save();try canvas.beginLayer(.{.opacity=0.5});
    try std.testing.expectError(error.LayerStateMismatch,canvas.restore());
    try canvas.endLayer();try canvas.restore();try scene.validate();
}
