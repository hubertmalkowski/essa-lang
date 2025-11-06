const std = @import("std");

pub const ValueTag = enum { int, bool, nil };

pub const Value = union(ValueTag) {
    int: i64,
    bool: bool,
    nil,

    pub fn format(
        self: Value,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .int => |i| try writer.print("{d}", .{i}),
            .bool => |b| try writer.print("{}", .{b}),
            .nil => try writer.writeAll("nil"),
        }
    }

    pub fn isInt(self: Value) bool {
        return self == .int;
    }

    pub fn isBool(self: Value) bool {
        return self == .bool;
    }

    pub fn isDigit(self: Value) bool {
        return self.isInt();
    }
};
