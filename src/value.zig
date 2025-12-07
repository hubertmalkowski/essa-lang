const std = @import("std");
const Register = @import("instruction.zig").Register;

pub const ValueTag = enum { int, bool, closure, nil };

pub const ObjectType = enum { closure };
pub const Object = struct { marked: bool, next: ?*Object, type: ObjectType };

pub const Closure = struct { object: Object, addr: usize, arity: usize, captures: []Value };

pub const Value = union(ValueTag) {
    int: i64,
    bool: bool,
    closure: *Closure,
    nil,

    pub fn format(
        self: Value,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .bool => |b| try writer.print("{}", .{b}),
            .closure => |f| try writer.print("fn:{d} arity=r{d} copies={any}", .{ f.*.addr, f.arity, f.captures }),
            .nil => try writer.writeAll("nil"),
        }
    }

    pub fn isInt(self: Value) bool {
        return self == .int;
    }

    pub fn isDigit(self: Value) bool {
        return self.isInt();
    }

    pub fn isBool(self: Value) bool {
        return self == .bool;
    }

    pub fn isClosure(self: Value) bool {
        return self == .closure;
    }
};
