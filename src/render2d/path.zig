//! Reusable, allocator-owned curves. No GPU lifetime or flattening is hidden in Path.
const std = @import("std");
const geo = @import("geometry.zig");
pub const Point = geo.Point;
pub const Affine = geo.Affine;
pub const FillRule = enum { nonzero, even_odd };
pub const Quad = struct { control: Point, end: Point };
pub const Conic = struct { control: Point, end: Point, weight: f64 };
pub const Cubic = struct { control1: Point, control2: Point, end: Point };
pub const Command = union(enum) { move_to: Point, line_to: Point, quad_to: Quad, conic_to: Conic, cubic_to: Cubic, close };
pub const Error = std.mem.Allocator.Error || error{ InvalidCoordinate, MissingCurrentPoint, InvalidWeight, InvalidRadius, ComplexityLimit };

/// Do not copy an owning path. Mutations increment revision for geometry caches.
/// Command slices are borrowed until the next mutation. Failed operations leave
/// earlier commands and current-point state unchanged.
pub const Path = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    current: ?Point = null,
    start: ?Point = null,
    revision: u64 = 0,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Path) void {
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn clear(self: *Path) void {
        self.commands.clearRetainingCapacity();
        self.current = null;
        self.start = null;
        self.closed = false;
        self.revision +%= 1;
    }
    pub fn data(self: *const Path) []const Command {
        return self.commands.items;
    }
    pub fn moveTo(self: *Path, end: Point) Error!void {
        if (!end.finite()) return error.InvalidCoordinate;
        try self.commands.append(self.allocator, .{ .move_to = end });
        self.start = end;
        self.current = end;
        self.closed = false;
        self.revision +%= 1;
    }
    pub fn lineTo(self: *Path, end: Point) Error!void {
        if (!end.finite()) return error.InvalidCoordinate;
        if (self.current == null) return error.MissingCurrentPoint;
        try self.commands.append(self.allocator, .{ .line_to = end });
        self.current = end;
        self.closed = false;
        self.revision +%= 1;
    }
    pub fn quadTo(self: *Path, control: Point, end: Point) Error!void {
        if (!control.finite() or !end.finite()) return error.InvalidCoordinate;
        if (self.current == null) return error.MissingCurrentPoint;
        try self.commands.append(self.allocator, .{ .quad_to = .{ .control = control, .end = end } });
        self.current = end;
        self.closed = false;
        self.revision +%= 1;
    }
    /// Finite weights greater than -1 describe bounded rational quadratics.
    /// Circular/elliptical arcs use positive weights; singular conics are rejected.
    pub fn conicTo(self: *Path, control: Point, end: Point, weight: f64) Error!void {
        if (!control.finite() or !end.finite()) return error.InvalidCoordinate;
        if (!std.math.isFinite(weight) or weight <= -1) return error.InvalidWeight;
        if (self.current == null) return error.MissingCurrentPoint;
        try self.commands.append(self.allocator, .{ .conic_to = .{ .control = control, .end = end, .weight = weight } });
        self.current = end;
        self.closed = false;
        self.revision +%= 1;
    }
    pub fn cubicTo(self: *Path, control1: Point, control2: Point, end: Point) Error!void {
        if (!control1.finite() or !control2.finite() or !end.finite()) return error.InvalidCoordinate;
        if (self.current == null) return error.MissingCurrentPoint;
        try self.commands.append(self.allocator, .{ .cubic_to = .{ .control1 = control1, .control2 = control2, .end = end } });
        self.current = end;
        self.closed = false;
        self.revision +%= 1;
    }
    pub fn close(self: *Path) Error!void {
        if (self.current == null) return error.MissingCurrentPoint;
        if (self.closed) return;
        try self.commands.append(self.allocator, .close);
        self.current = self.start;
        self.closed = true;
        self.revision +%= 1;
    }
    pub fn addRect(self: *Path, rect: geo.Rect) Error!void {
        if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return error.InvalidCoordinate;
        const right = rect.x + rect.width;
        const bottom = rect.y + rect.height;
        if (!std.math.isFinite(right) or !std.math.isFinite(bottom)) return error.InvalidCoordinate;
        try self.commands.ensureUnusedCapacity(self.allocator, 5);
        self.commands.appendSliceAssumeCapacity(&.{ .{ .move_to = .{ .x = rect.x, .y = rect.y } }, .{ .line_to = .{ .x = right, .y = rect.y } }, .{ .line_to = .{ .x = right, .y = bottom } }, .{ .line_to = .{ .x = rect.x, .y = bottom } }, .close });
        self.current = .{ .x = rect.x, .y = rect.y };
        self.start = self.current;
        self.closed = true;
        self.revision +%= 1;
    }
    /// Append a transformed independent copy, including when appending to self.
    pub fn append(self: *Path, other: *const Path, transform: Affine) Error!void {
        var copy = try other.transformed(self.allocator, transform);
        defer copy.deinit();
        if (copy.commands.items.len == 0) return;
        try self.commands.appendSlice(self.allocator, copy.commands.items);
        self.current = copy.current;
        self.start = copy.start;
        self.closed = copy.closed;
        self.revision +%= 1;
    }
    pub fn transformed(self: *const Path, allocator: std.mem.Allocator, transform: Affine) Error!Path {
        if (!transform.finite()) return error.InvalidCoordinate;
        var result = Path.init(allocator);
        errdefer result.deinit();
        try result.commands.ensureTotalCapacity(allocator, self.commands.items.len);
        for (self.data()) |command| switch (command) {
            .move_to => |p| try result.moveTo(transform.point(p)),
            .line_to => |p| try result.lineTo(transform.point(p)),
            .quad_to => |q| try result.quadTo(transform.point(q.control), transform.point(q.end)),
            .conic_to => |q| try result.conicTo(transform.point(q.control), transform.point(q.end), q.weight),
            .cubic_to => |c| try result.cubicTo(transform.point(c.control1), transform.point(c.control2), transform.point(c.end)),
            .close => try result.close(),
        };
        return result;
    }
    /// Reverse contour order and each contour's direction without flattening or
    /// changing curve types. Closed contours retain their implicit closing edge.
    pub fn reversed(self: *const Path, allocator: std.mem.Allocator) Error!Path {
        var segments: std.ArrayList(ReverseSegment) = .empty;
        defer segments.deinit(allocator);
        var contours: std.ArrayList(ReverseContour) = .empty;
        defer contours.deinit(allocator);
        var current: ?Point = null;
        var start: Point = .{};
        var active = false;
        for (self.data()) |command| switch (command) {
            .move_to => |point| {
                try contours.append(allocator, .{ .first = segments.items.len, .count = 0, .start = point, .end = point, .closed = false });
                current = point;
                start = point;
                active = true;
            },
            .close => {
                if (current == null) return error.MissingCurrentPoint;
                if (active) contours.items[contours.items.len - 1].closed = true;
                current = start;
                active = false;
            },
            else => {
                const from = current orelse return error.MissingCurrentPoint;
                if (!active) {
                    try contours.append(allocator, .{ .first = segments.items.len, .count = 0, .start = from, .end = from, .closed = false });
                    start = from;
                    active = true;
                }
                try segments.append(allocator, .{ .from = from, .command = command });
                const contour = &contours.items[contours.items.len - 1];
                contour.count += 1;
                contour.end = commandEnd(command);
                current = contour.end;
            },
        };
        var result = Path.init(allocator);
        errdefer result.deinit();
        for (0..contours.items.len) |i| {
            const contour = contours.items[contours.items.len - 1 - i];
            try result.moveTo(contour.end);
            for (0..contour.count) |j| {
                const segment = segments.items[contour.first + contour.count - 1 - j];
                switch (segment.command) {
                    .line_to => try result.lineTo(segment.from),
                    .quad_to => |q| try result.quadTo(q.control, segment.from),
                    .conic_to => |q| try result.conicTo(q.control, segment.from, q.weight),
                    .cubic_to => |c| try result.cubicTo(c.control2, c.control1, segment.from),
                    else => unreachable,
                }
            }
            if (contour.closed) try result.close();
        }
        return result;
    }
    /// Retain only open or closed contours, preserving curve commands. Used
    /// when stroke alignment applies to closed figures but open runs stay centered.
    pub fn selected(self:*const Path,allocator:std.mem.Allocator,want_closed:bool) Error!Path {
        var result=Path.init(allocator);errdefer result.deinit();var part=Path.init(allocator);defer part.deinit();var resume_point:?Point=null;
        for(self.data())|command|switch(command){
            .move_to=>|point|{if(part.data().len>0 and !want_closed)try result.append(&part,.{});part.clear();try part.moveTo(point);resume_point=point;},
            .close=>{if(part.current==null)return error.MissingCurrentPoint;try part.close();resume_point=part.current;if(want_closed)try result.append(&part,.{});part.clear();},
            else=>{
                if(part.current==null)try part.moveTo(resume_point orelse return error.MissingCurrentPoint);
                switch(command){.line_to=>|point|try part.lineTo(point),.quad_to=>|q|try part.quadTo(q.control,q.end),.conic_to=>|q|try part.conicTo(q.control,q.end,q.weight),.cubic_to=>|c|try part.cubicTo(c.control1,c.control2,c.end),else=>unreachable,}
                resume_point=part.current;
            },
        };
        if(part.data().len>0 and !want_closed)try result.append(&part,.{});return result;
    }
    /// Analytic extrema bounds of retained curves (including move positions).
    pub fn bounds(self: *const Path) error{ InvalidCoordinate, MissingCurrentPoint }!?geo.Bounds {
        var result: ?geo.Bounds = null;
        var current: ?Point = null;
        var start: Point = .{};
        for (self.data()) |command| switch (command) {
            .move_to => |point| {
                try includeBound(&result, point);
                current = point;
                start = point;
            },
            .close => {
                if (current == null) return error.MissingCurrentPoint;
                current = start;
            },
            else => {
                const from = current orelse return error.MissingCurrentPoint;
                const end = commandEnd(command);
                try includeBound(&result, end);
                if (command != .line_to) for (0..2) |axis| {
                    const roots = extremaRoots(from, command, axis);
                    for (roots.values[0..roots.count]) |t| if (t > 0 and t < 1) try includeBound(&result, evaluate(from, command, t));
                };
                current = end;
            },
        };
        return result;
    }
    /// Center-parameterized elliptical arc, divided into exact rational conics.
    /// Connects to the current point, or moves to the start if the path is empty.
    pub fn arc(self: *Path, center: Point, radii: Point, rotation: f64, start_angle: f64, sweep: f64) Error!void {
        if (!center.finite() or !radii.finite() or !std.math.isFinite(rotation) or !std.math.isFinite(start_angle) or !std.math.isFinite(sweep)) return error.InvalidCoordinate;
        if (radii.x < 0 or radii.y < 0) return error.InvalidRadius;
        const count_f = @ceil(@abs(sweep) / (std.math.pi / 2.0));
        if (count_f > 65536) return error.ComplexityLimit;
        const count: u32 = @intFromFloat(count_f);
        const transform = Affine.mul(Affine.translation(center.x, center.y), Affine.mul(Affine.rotation(rotation), Affine.scaling(radii.x, radii.y)));
        const phase: Point = .{ .x = @cos(start_angle), .y = @sin(start_angle) };
        const first = transform.point(phase);
        if (!first.finite()) return error.InvalidCoordinate;
        var part = Path.init(self.allocator);
        defer part.deinit();
        // Build in temporary storage so invalid arithmetic or OOM cannot append
        // only half an arc to the destination.
        if (self.current) |current| {
            try part.moveTo(current);
            if (!current.eql(first)) try part.lineTo(first);
        } else try part.moveTo(first);
        if (count > 0) {
            const step = sweep / @as(f64, @floatFromInt(count));
            for (0..count) |i| {
                const a0 = step * @as(f64, @floatFromInt(i));
                const a1 = step * @as(f64, @floatFromInt(i + 1));
                const middle = (a0 + a1) * 0.5;
                const weight = @cos(step * 0.5);
                const control = rotatePhase(phase, middle);
                try part.conicTo(transform.point(.{ .x = control.x / weight, .y = control.y / weight }), transform.point(rotatePhase(phase, a1)), weight);
            }
        }
        const commands = if (self.current != null) part.data()[1..] else part.data();
        if (commands.len == 0) return;
        try self.commands.appendSlice(self.allocator, commands);
        if (self.current == null) self.start = first;
        self.current = part.current;
        self.closed = false;
        self.revision +%= 1;
    }
    /// SVG endpoint-form elliptical arc. Rotation is in radians; clockwise
    /// corresponds to SVG's sweep flag in the +Y-down coordinate system.
    /// Negative radii are made positive; coincident endpoints draw nothing and
    /// zero radii degenerate to a line, as required by SVG arc semantics.
    pub fn svgArcTo(self: *Path, radii: Point, rotation: f64, large_arc: bool, clockwise: bool, end: Point) Error!void {
        const from = self.current orelse return error.MissingCurrentPoint;
        if (!radii.finite() or !end.finite() or !std.math.isFinite(rotation)) return error.InvalidCoordinate;
        if (from.eql(end)) return;
        var rx = @abs(radii.x);
        var ry = @abs(radii.y);
        if (rx == 0 or ry == 0) return self.lineTo(end);
        const cosine = @cos(rotation);
        const sine = @sin(rotation);
        const dx = from.x * 0.5 - end.x * 0.5;
        const dy = from.y * 0.5 - end.y * 0.5;
        const x = cosine * dx + sine * dy;
        const y = -sine * dx + cosine * dy;
        const correction = std.math.hypot(x / rx, y / ry);
        if (!std.math.isFinite(correction)) return error.InvalidRadius;
        if (correction > 1) {
            rx *= correction;
            ry *= correction;
        }
        if (!std.math.isFinite(rx) or !std.math.isFinite(ry)) return error.InvalidRadius;
        const u = x / rx;
        const v = y / ry;
        const length2 = u * u + v * v;
        if (length2 <= 0 or !std.math.isFinite(length2)) return error.InvalidCoordinate;
        const factor = @sqrt(@max(0, (1 - length2) / length2)) * @as(f64, if (large_arc == clockwise) -1 else 1);
        const cx = factor * rx * v;
        const cy = -factor * ry * u;
        const center: Point = .{ .x = cosine * cx - sine * cy + from.x * 0.5 + end.x * 0.5, .y = sine * cx + cosine * cy + from.y * 0.5 + end.y * 0.5 };
        const a: Point = .{ .x = (x - cx) / rx, .y = (y - cy) / ry };
        const b: Point = .{ .x = (-x - cx) / rx, .y = (-y - cy) / ry };
        const start = std.math.atan2(a.y, a.x);
        var sweep = std.math.atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y);
        if (clockwise and sweep < 0) sweep += 2.0 * std.math.pi;
        if (!clockwise and sweep > 0) sweep -= 2.0 * std.math.pi;
        var part = Path.init(self.allocator);
        defer part.deinit();
        try part.arc(center, .{ .x = rx, .y = ry }, rotation, start, sweep);
        // Preserve exact endpoint identity instead of adding roundoff connectors.
        if (part.commands.items.len < 2) return error.InvalidCoordinate;
        part.commands.items[part.commands.items.len - 1].conic_to.end = end;
        try self.commands.appendSlice(self.allocator, part.data()[1..]);
        self.current = end;
        self.closed = false;
        self.revision +%= 1;
    }
    pub fn addPolygon(self: *Path, points: []const Point, close_contour: bool) Error!void {
        if (points.len == 0) return;
        for (points) |point| if (!point.finite()) return error.InvalidCoordinate;
        try self.commands.ensureUnusedCapacity(self.allocator, points.len + @intFromBool(close_contour));
        self.commands.appendAssumeCapacity(.{ .move_to = points[0] });
        for (points[1..]) |point| self.commands.appendAssumeCapacity(.{ .line_to = point });
        if (close_contour) self.commands.appendAssumeCapacity(.close);
        self.start = points[0];
        self.current = if (close_contour) points[0] else points[points.len - 1];
        self.closed = close_contour;
        self.revision +%= 1;
    }
    pub fn roundedRect(self: *Path, rect: geo.Rect, radii: Point) Error!void {
        if (!radii.finite() or radii.x < 0 or radii.y < 0) return error.InvalidRadius;
        if (!std.math.isFinite(rect.x) or !std.math.isFinite(rect.y) or !std.math.isFinite(rect.width) or !std.math.isFinite(rect.height)) return error.InvalidCoordinate;
        const width = @abs(rect.width);
        const height = @abs(rect.height);
        const rx = @min(radii.x, width * 0.5);
        const ry = @min(radii.y, height * 0.5);
        if (rx == 0 or ry == 0) return self.addRect(rect);
        const weight = @sqrt(@as(f64, 0.5));
        var part = Path.init(self.allocator);
        defer part.deinit();
        try part.moveTo(.{ .x = rx });
        try part.lineTo(.{ .x = width - rx });
        try part.conicTo(.{ .x = width }, .{ .x = width, .y = ry }, weight);
        try part.lineTo(.{ .x = width, .y = height - ry });
        try part.conicTo(.{ .x = width, .y = height }, .{ .x = width - rx, .y = height }, weight);
        try part.lineTo(.{ .x = rx, .y = height });
        try part.conicTo(.{ .y = height }, .{ .y = height - ry }, weight);
        try part.lineTo(.{ .y = ry });
        try part.conicTo(.{}, .{ .x = rx }, weight);
        try part.close();
        try self.append(&part, .{ .a = if (rect.width < 0) -1 else 1, .d = if (rect.height < 0) -1 else 1, .tx = rect.x, .ty = rect.y });
    }
    pub fn circle(self: *Path, center: Point, radius: f64) Error!void {
        return self.ellipse(center, .{ .x = radius, .y = radius }, 0);
    }
    /// Starts a new closed contour; radii must be nonnegative.
    pub fn ellipse(self: *Path, center: Point, radii: Point, rotation: f64) Error!void {
        var part = Path.init(self.allocator);
        defer part.deinit();
        try part.arc(center, radii, rotation, 0, 2.0 * std.math.pi);
        try part.close();
        try self.append(&part, .{});
    }
};

pub const FlattenOptions = struct {
    transform: Affine = .{},
    /// Maximum deviation from the output polyline, measured in device pixels.
    tolerance: f64 = 0.25,
    max_depth: u8 = 24,
    max_points: usize = 1 << 20,
};
pub const Contour = struct { first: usize, count: usize, closed: bool };
pub const FlattenError = std.mem.Allocator.Error || error{ InvalidCoordinate, InvalidTolerance, FlattenLimit };
pub const FlatPath = struct {
    allocator: std.mem.Allocator,
    points: std.ArrayList(Point) = .empty,
    contours: std.ArrayList(Contour) = .empty,
    pub fn deinit(self: *FlatPath) void {
        self.points.deinit(self.allocator);
        self.contours.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn bounds(self: *const FlatPath) ?geo.Bounds {
        if (self.points.items.len == 0) return null;
        var result: geo.Bounds = .{ .min = self.points.items[0], .max = self.points.items[0] };
        for (self.points.items[1..]) |p| result.include(p);
        return result;
    }
    /// Polyline metric in the same output coordinates/tolerance used to flatten.
    /// Open contours remain open for metrics, even though filling closes them.
    pub fn length(self:*const FlatPath) error{InvalidCoordinate}!f64 {
        var total:f64=0;
        for(self.contours.items)|contour|{const points=self.contourPoints(contour);if(points.len<2)continue;const count=points.len-@as(usize,if(contour.closed)0 else 1);for(0..count)|i|{const a=points[i];const b=points[(i+1)%points.len];total+=std.math.hypot(b.x-a.x,b.y-a.y);if(!std.math.isFinite(total))return error.InvalidCoordinate;}}
        return total;
    }
    pub fn sampleAtLength(self:*const FlatPath,distance:f64) error{InvalidCoordinate}!?PathSample {
        if(!std.math.isFinite(distance))return error.InvalidCoordinate;var remaining=@max(0,distance);var last:?PathSample=null;
        for(self.contours.items,0..)|contour,contour_index|{
            const points=self.contourPoints(contour);if(points.len==0)continue;
            if(last==null)last=.{.position=points[0],.tangent=.{},.contour=contour_index};
            if(points.len<2)continue;const count=points.len-@as(usize,if(contour.closed)0 else 1);
            for(0..count)|i|{const a=points[i];const b=points[(i+1)%points.len];const dx=b.x-a.x;const dy=b.y-a.y;const size=std.math.hypot(dx,dy);if(!std.math.isFinite(size))return error.InvalidCoordinate;if(size==0)continue;const tangent:Point=.{.x=dx/size,.y=dy/size};if(remaining<=size)return .{.position=Point.lerp(a,b,remaining/size),.tangent=tangent,.contour=contour_index};remaining-=size;last=.{.position=b,.tangent=tangent,.contour=contour_index};}
        }
        return last;
    }
    pub fn hitTest(self:*const FlatPath,point:Point,rule:FillRule,boundary_tolerance:f64) error{InvalidCoordinate}!Hit {
        if(!point.finite() or !std.math.isFinite(boundary_tolerance) or boundary_tolerance<0)return error.InvalidCoordinate;
        var winding:i64=0;
        for(self.contours.items)|contour|{
            const points=self.contourPoints(contour);if(points.len<2)continue;var a=points[points.len-1];
            for(points)|b|{
                const orientation=(@as(f128,b.x)-a.x)*(@as(f128,point.y)-a.y)-(@as(f128,point.x)-a.x)*(@as(f128,b.y)-a.y);
                const in_box=point.x>=@min(a.x,b.x) and point.x<=@max(a.x,b.x) and point.y>=@min(a.y,b.y) and point.y<=@max(a.y,b.y);
                if((orientation==0 and in_box) or (boundary_tolerance>0 and geo.distanceToSegment(point,a,b)<=boundary_tolerance))return .boundary;
                if(a.y<=point.y and b.y>point.y and orientation>0)winding+=1;
                if(a.y>point.y and b.y<=point.y and orientation<0)winding-=1;a=b;
            }
        }
        return if(if(rule==.nonzero)winding!=0 else @mod(winding,2)!=0).inside else .outside;
    }
    pub fn contourPoints(self: *const FlatPath, contour: Contour) []const Point {
        return self.points.items[contour.first..][0..contour.count];
    }
};

/// Adaptive de Casteljau subdivision in device space. Bounded negative-weight
/// conics subdivide before applying the positive-weight control-hull error bound. Every failure frees the partial result.
pub fn flatten(path: *const Path, allocator: std.mem.Allocator, options: FlattenOptions) FlattenError!FlatPath {
    if (!std.math.isFinite(options.tolerance) or options.tolerance <= 0 or options.max_depth > 48 or options.max_points == 0) return error.InvalidTolerance;
    if (!options.transform.finite()) return error.InvalidCoordinate;
    var output: FlatPath = .{ .allocator = allocator };
    errdefer output.deinit();
    var writer: Writer = .{ .output = &output, .options = options };
    var current: ?Point = null;
    var start: Point = .{};
    var active = false;
    for (path.data()) |command| switch (command) {
        .move_to => |p| {
            current = options.transform.point(p);
            start = current.?;
            if (!start.finite()) return error.InvalidCoordinate;
            try writer.begin(start);
            active = true;
        },
        .close => {
            if (current == null) return error.InvalidCoordinate;
            if (active) output.contours.items[output.contours.items.len - 1].closed = true;
            current = start;
            active = false;
        },
        else => {
            const from = current orelse return error.InvalidCoordinate;
            if (!active) {
                try writer.begin(from);
                active = true;
            }
            switch (command) {
                .line_to => |p| {
                    current = options.transform.point(p);
                    try writer.point(current.?);
                },
                .quad_to => |q| {
                    const control = options.transform.point(q.control);
                    const end = options.transform.point(q.end);
                    try writer.curve(.{ from, control, end, end }, 3, 0);
                    current = end;
                },
                .cubic_to => |c| {
                    const c1 = options.transform.point(c.control1);
                    const c2 = options.transform.point(c.control2);
                    const end = options.transform.point(c.end);
                    try writer.curve(.{ from, c1, c2, end }, 4, 0);
                    current = end;
                },
                .conic_to => |q| {
                    const control = options.transform.point(q.control);
                    const end = options.transform.point(q.end);
                    const normalization = @max(1, q.weight);
                    try writer.conic(.{ HPoint.from(from, 1 / normalization), HPoint.from(control, q.weight / normalization), HPoint.from(end, 1 / normalization) }, 0);
                    current = end;
                },
                else => unreachable,
            }
        },
    };
    return output;
}
const HPoint = struct {
    x: f64,
    y: f64,
    w: f64,
    fn from(p: Point, w: f64) HPoint {
        return .{ .x = p.x * w, .y = p.y * w, .w = w };
    }
    fn half(a: HPoint, b: HPoint) HPoint {
        return .{ .x = a.x * 0.5 + b.x * 0.5, .y = a.y * 0.5 + b.y * 0.5, .w = a.w * 0.5 + b.w * 0.5 };
    }
    fn project(p: HPoint) Point {
        return .{ .x = p.x / p.w, .y = p.y / p.w };
    }
};
const Writer = struct {
    output: *FlatPath,
    options: FlattenOptions,
    fn begin(self: *Writer, p: Point) FlattenError!void {
        try self.output.contours.append(self.output.allocator, .{ .first = self.output.points.items.len, .count = 0, .closed = false });
        try self.point(p);
    }
    fn point(self: *Writer, p: Point) FlattenError!void {
        if (!p.finite()) return error.InvalidCoordinate;
        const contour = &self.output.contours.items[self.output.contours.items.len - 1];
        if (contour.count > 0 and self.output.points.items[self.output.points.items.len - 1].eql(p)) return;
        if (self.output.points.items.len >= self.options.max_points) return error.FlattenLimit;
        try self.output.points.append(self.output.allocator, p);
        contour.count += 1;
    }
    fn curve(self: *Writer, points: [4]Point, count: usize, depth: u8) FlattenError!void {
        for (points[0..count]) |p| if (!p.finite()) return error.InvalidCoordinate;
        var distance: f64 = 0;
        for (points[1 .. count - 1]) |p| distance = @max(distance, geo.distanceToSegment(p, points[0], points[count - 1]));
        if (distance <= self.options.tolerance) return self.point(points[count - 1]);
        if (depth >= self.options.max_depth) return error.FlattenLimit;
        var work = points;
        var left = points;
        var right = points;
        for (1..count) |level| {
            for (0..count - level) |i| work[i] = Point.lerp(work[i], work[i + 1], 0.5);
            left[level] = work[0];
            right[count - level - 1] = work[count - level - 1];
        }
        try self.curve(left, count, depth + 1);
        try self.curve(right, count, depth + 1);
    }
    fn conic(self: *Writer, points: [3]HPoint, depth: u8) FlattenError!void {
        const a = points[0].project();
        const b = points[2].project();
        if (!a.finite() or !b.finite()) return error.InvalidCoordinate;
        const control = if (points[1].w == 0) a else points[1].project();
        if (!control.finite()) return error.InvalidCoordinate;
        if (points[1].w >= 0 and geo.distanceToSegment(control, a, b) <= self.options.tolerance) return self.point(b);
        if (depth >= self.options.max_depth) return error.FlattenLimit;
        const ab = HPoint.half(points[0], points[1]);
        const bc = HPoint.half(points[1], points[2]);
        const middle = HPoint.half(ab, bc);
        try self.conic(.{ points[0], ab, middle }, depth + 1);
        try self.conic(.{ middle, bc, points[2] }, depth + 1);
    }
};

fn rotatePhase(phase: Point, angle: f64) Point {
    const cosine = @cos(angle);
    const sine = @sin(angle);
    return .{ .x = phase.x * cosine - phase.y * sine, .y = phase.x * sine + phase.y * cosine };
}

const ReverseSegment = struct { from: Point, command: Command };
const ReverseContour = struct { first: usize, count: usize, start: Point, end: Point, closed: bool };
fn commandEnd(command: Command) Point {
    return switch (command) {
        .move_to, .line_to => |point| point,
        .quad_to => |q| q.end,
        .conic_to => |q| q.end,
        .cubic_to => |c| c.end,
        .close => unreachable,
    };
}
fn includeBound(bounds: *?geo.Bounds, point: Point) error{InvalidCoordinate}!void {
    if (!point.finite()) return error.InvalidCoordinate;
    if (bounds.*) |*value| value.include(point) else bounds.* = .{ .min = point, .max = point };
}
fn coordinate(point: Point, axis: usize) f64 {
    return if (axis == 0) point.x else point.y;
}
const Roots = struct { values: [2]f64 = .{ 0, 0 }, count: usize = 0 };
fn polynomialRoots(a: f64, b: f64, c: f64) Roots {
    if (a == 0) return if (b == 0) .{} else .{ .values = .{ -c / b, 0 }, .count = 1 };
    const discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return .{};
    if (discriminant == 0) return .{ .values = .{ -b / (2 * a), 0 }, .count = 1 };
    const q = -0.5 * (b + std.math.copysign(@sqrt(discriminant), b));
    return .{ .values = .{ q / a, c / q }, .count = 2 };
}
fn extremaRoots(from: Point, command: Command, axis: usize) Roots {
    const end = commandEnd(command);
    var p0 = coordinate(from, axis);
    var p1: f64 = undefined;
    var p2: f64 = undefined;
    var p3 = coordinate(end, axis);
    switch (command) {
        .quad_to => |q| {
            p1 = coordinate(q.control, axis);
            p2 = p3;
        },
        .conic_to => |q| {
            p1 = coordinate(q.control, axis);
            p2 = p3;
        },
        .cubic_to => |c| {
            p1 = coordinate(c.control1, axis);
            p2 = coordinate(c.control2, axis);
        },
        else => return .{},
    }
    const scale = @max(@abs(p0), @max(@abs(p1), @max(@abs(p2), @abs(p3))));
    if (scale == 0) return .{};
    p0 /= scale;
    p1 /= scale;
    p2 /= scale;
    p3 /= scale;
    return switch (command) {
        .quad_to => polynomialRoots(0, p0 - 2 * p1 + p2, p1 - p0),
        .cubic_to => polynomialRoots(-p0 + 3 * p1 - 3 * p2 + p3, 2 * (p0 - 2 * p1 + p2), p1 - p0),
        .conic_to => |q| blk: {
            const normal = @max(1, q.weight);
            const w = q.weight / normal;
            const inverse = 1 / normal;
            break :blk polynomialRoots((w - inverse) * (p2 - p0), (2 * w - inverse) * p0 - 2 * w * p1 + inverse * p2, w * (p1 - p0));
        },
        else => unreachable,
    };
}
fn evaluate(from: Point, command: Command, t: f64) Point {
    return switch (command) {
        .quad_to => |q| Point.lerp(Point.lerp(from, q.control, t), Point.lerp(q.control, q.end, t), t),
        .cubic_to => |c| blk: {
            const a = Point.lerp(from, c.control1, t);
            const b = Point.lerp(c.control1, c.control2, t);
            const d = Point.lerp(c.control2, c.end, t);
            break :blk Point.lerp(Point.lerp(a, b, t), Point.lerp(b, d, t), t);
        },
        .conic_to => |q| blk: {
            const u = 1 - t;
            const normal = @max(1, q.weight);
            const a = u * u / normal;
            const b = 2 * u * t * (q.weight / normal);
            const c = t * t / normal;
            const sum = a + b + c;
            break :blk .{ .x = from.x * (a / sum) + q.control.x * (b / sum) + q.end.x * (c / sum), .y = from.y * (a / sum) + q.control.y * (b / sum) + q.end.y * (c / sum) };
        },
        else => unreachable,
    };
}

pub const Hit=enum{outside,inside,boundary};
pub const PathSample=struct{position:Point,tangent:Point,contour:usize};
