//! Descriptor conversion for the independent C benchmark only.
const std = @import("std");
pub fn toC(comptime C: type, z: anytype) C {
    const Z = @TypeOf(z);
    switch (@typeInfo(C)) {
        .@"struct" => |info| {
            var res: C = std.mem.zeroes(C);
            inline for (info.field_names, info.field_types) |name, FieldType| {
                if (comptime std.mem.eql(u8, name, "logger") or std.mem.eql(u8, name, "allocator")) continue;
                if (comptime @hasField(Z, name)) {
                    @field(res, name) = toC(FieldType, @field(z, name));
                }
            }
            return res;
        },
        .array => |info| {
            var res: C = undefined;
            for (&res, z) |*dst, src| dst.* = toC(info.child, src);
            return res;
        },
        .int => return switch (@typeInfo(Z)) {
            .@"enum" => @intCast(@backingInt(z)),
            .bool => @intFromBool(z),
            else => @intCast(z),
        },
        .float, .bool => return z,
        .pointer => return if (@typeInfo(Z) == .optional) (if (z) |p| @ptrCast(@constCast(p)) else null) else @ptrCast(@constCast(z)),
        .optional => return if (z) |p| @ptrCast(@constCast(p)) else null,
        else => @compileError("unsupported conversion to " ++ @typeName(C)),
    }
}
