const std = @import("std");
const vm_zig = @import("vm_zig");
const Value = @import("value.zig").Value;
comptime {
    _ = @import("vm.zig");
}

pub fn main() !void {
    const val1 = Value{ .int = 42 };
    const val2 = Value{ .bool = true };
    const val3 = Value{ .nil = {} };

    std.debug.print("val1: {f}\n", .{val1});
    std.debug.print("val2: {f}\n", .{val2});
    std.debug.print("val3: {f}\n", .{val3});
}
