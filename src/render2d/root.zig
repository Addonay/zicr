//! Ordered 2D drawing over zicr.gpu. The application owns presentation and commit.
const draw = @import("draw_list.zig");
pub const Vec2 = draw.Vec2;
pub const Rect = draw.Rect;
pub const Color = draw.Color;
pub const Transform = draw.Transform;
pub const Camera = draw.Camera;
pub const Texture = draw.Texture;
pub const Quad = draw.Quad;
pub const DrawList = draw.DrawList;
pub const Options = draw.Options;
test {
    @import("std").testing.refAllDecls(draw);
}

pub const Renderer = @import("renderer.zig").Renderer;
pub const RendererOptions = @import("renderer.zig").Options;
pub const Stats = @import("renderer.zig").Stats;

test {
    _ = @import("renderer.zig");
}

/// Reusable double-precision vector geometry.
pub const Path = @import("path.zig").Path;
pub const Point = @import("geometry.zig").Point;
pub const Affine = @import("geometry.zig").Affine;
pub const FillRule = @import("path.zig").FillRule;
pub const FlatPath = @import("path.zig").FlatPath;
pub const FlattenOptions = @import("path.zig").FlattenOptions;
pub const flattenPath = @import("path.zig").flatten;
test {
    _ = @import("path_tests.zig");
    _ = @import("geometry.zig");
}

test {
    _ = @import("coverage_tests.zig");
}

pub const FillOptions = draw.FillOptions;

pub const StrokeOptions = @import("stroke.zig").Options;
pub const StrokeCap = @import("stroke.zig").Cap;
pub const StrokeJoin = @import("stroke.zig").Join;
pub const strokeOutline = @import("stroke.zig").outline;
test {
    _ = @import("stroke_tests.zig");
}

/// Full renderer recording and material API (implementation phase, unverified).
pub const Scene = @import("scene.zig").Scene;
pub const Canvas = @import("canvas.zig").Canvas;
pub const Paint = @import("paint.zig").Paint;
pub const Gradient = @import("paint.zig").Gradient;
pub const GradientStop = @import("paint.zig").Stop;
pub const Pattern = @import("paint.zig").Pattern;
pub const ImageSource = @import("paint.zig").ImageSource;
pub const Image = @import("image.zig").Image;
pub const ImageFormat = @import("image.zig").Format;
pub const ImageLayout = @import("image.zig").Layout;
pub const ImageSampling = @import("image.zig").Sampling;
pub const ColorSpace = @import("color.zig").Space;
pub const PremultipliedColor = @import("color.zig").Pixel;
pub const CompositeMode = @import("composite.zig").Mode;
pub const FilterGraph = @import("filter.zig").Graph;
pub const Filter = @import("filter.zig").Kind;
test { _ = @import("paint_tests.zig"); _ = @import("scene_tests.zig"); }

pub const StrokeStyle = @import("scene.zig").StrokeStyle;
