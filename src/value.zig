const std = @import("std");
const Register = @import("instruction.zig").Register;

pub const ValueTag = enum { int, bool, closure, nil };
pub const Closure = struct { addr: usize, arity: usize };

pub const Value = union(ValueTag) {
    int: i64,
    bool: bool,
    closure: Closure,
    nil,

    pub fn format(
        self: Value,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .bool => |b| try writer.print("{}", .{b}),
            .closure => |f| try writer.print("fn:{d} => r{d}", .{ f.addr, f.arity }),
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
