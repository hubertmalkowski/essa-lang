const std = @import("std");
const emitter = @import("emitter.zig");
const semantic_analysis = @import("semantic_analysis.zig");

pub const Expr = union(enum) {
    integer: i64,
    boolean: bool,
    unit: void,
    identifier: []const u8,
    binary: *BinaryExpr,
    if_expr: *IfExpr,
    fn_expr: *FnExpr,
    call: *CallExpr,

    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self) {
            .integer, .boolean, .unit, .identifier => {
                // No allocation, nothing to free
            },
            .binary => |bin| {
                bin.left.deinit(allocator);
                bin.right.deinit(allocator);
                allocator.destroy(bin);
            },
            .if_expr => |if_e| {
                if_e.condition.deinit(allocator);
                if_e.then_branch.deinit(allocator);
                if_e.else_branch.deinit(allocator);
                allocator.destroy(if_e);
            },
            .fn_expr => |fn_e| {
                allocator.free(fn_e.params);
                fn_e.body.deinit(allocator);
                if (fn_e.scope) |scope| {
                    scope.deinit();
                }
                allocator.destroy(fn_e);
            },
            .call => |c| {
                c.function.deinit(allocator);
                for (c.args) |arg| {
                    arg.deinit(allocator);
                }
                allocator.free(c.args);
                allocator.destroy(c);
            },
        }
    }

    pub fn format(self: Expr, writer: anytype) !void {
        switch (self) {
            .integer => |val| try writer.print("{d}", .{val}),
            .boolean => |val| try writer.print("{}", .{val}),
            .unit => try writer.writeAll("()"),
            .identifier => |name| try writer.print("{s}", .{name}),
            .binary => |bin| {
                try writer.writeAll("(");
                try bin.left.format(writer);
                try writer.print(" {s} ", .{@tagName(bin.op)});
                try bin.right.format(writer);
                try writer.writeAll(")");
            },
            .if_expr => |if_e| {
                try writer.writeAll("(if ");
                try if_e.condition.format(writer);
                try writer.writeAll(" then ");
                try if_e.then_branch.format(writer);
                try writer.writeAll(" else ");
                try if_e.else_branch.format(writer);
                try writer.writeAll(")");
            },
            .fn_expr => |fn_e| {
                try writer.writeAll("(fn [");
                for (fn_e.params, 0..) |param, i| {
                    try writer.print("{s}", .{param});
                    if (i < fn_e.params.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
                try writer.writeAll("] ");
                try fn_e.body.format(writer);
                try writer.writeAll(")");
            },
            .call => |c| {
                try writer.writeAll("call(");
                try c.function.format(writer);
                for (c.args) |arg| {
                    try writer.writeAll(" ");
                    try arg.format(writer);
                }
                try writer.writeAll(")");
            },
        }
    }
};

pub const BinaryExpr = struct {
    left: Expr,
    op: BinaryOp,
    right: Expr,
};

pub const BinaryOp = enum { Add, Sub, Mul, Div, Eq, Lt, Gt };

pub const IfExpr = struct {
    condition: Expr,
    then_branch: Expr,
    else_branch: Expr,
};

pub const FnExpr = struct {
    params: [][]const u8, // parameter names
    body: Expr,
    scope: ?*semantic_analysis.Scope,
};

pub const CallExpr = struct {
    function: Expr,
    args: []Expr,
};

pub const Definition = struct {
    name: []const u8,
    value: Expr,
};

pub const Statement = union(enum) {
    definition: Definition,
    debug: Expr,

    pub fn deinit(self: Statement, allocator: std.mem.Allocator) void {
        switch (self) {
            .definition => |def| def.value.deinit(allocator),
            .debug => |expr| expr.deinit(allocator),
        }
    }

    pub fn format(self: Statement, writer: anytype) !void {
        switch (self) {
            .definition => |def| {
                try writer.print("{s} = ", .{def.name});
                try def.value.format(writer);
            },
            .debug => |expr| {
                try writer.writeAll("debug ");
                try expr.format(writer);
            },
        }
    }
};

pub const Ast = struct {
    statements: []Statement,
    scope: ?*semantic_analysis.Scope,

    pub fn deinit(self: *const Ast, allocator: std.mem.Allocator) void {
        for (self.statements) |stmt| {
            stmt.deinit(allocator);
        }
        if (self.scope) |scope| {
            scope.deinit();
        }
        allocator.free(self.statements);
    }

    pub fn format(self: *const Ast, writer: anytype) !void {
        for (self.statements) |stmt| {
            try stmt.format(writer);
            try writer.writeAll("\n");
        }
    }
};

test "ast printer formats simple expressions" {
    const allocator = std.testing.allocator;

    // Create: let x = (5 + 3)
    const bin_expr = try allocator.create(BinaryExpr);
    bin_expr.* = BinaryExpr{
        .left = Expr{ .integer = 5 },
        .op = .Add,
        .right = Expr{ .integer = 3 },
    };

    const statements = try allocator.alloc(Statement, 1);
    statements[0] = Statement{
        .definition = Definition{
            .name = "x",
            .value = Expr{ .binary = bin_expr },
        },
    };

    const ast = Ast{ .statements = statements, .scope = null };
    defer ast.deinit(allocator);

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();
    try ast.format(writer);

    const expected = "x = (5 Add 3)\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}

test "ast printer formats if expressions" {
    const allocator = std.testing.allocator;

    // Create: debug (if true then 1 else 2)
    const if_expr = try allocator.create(IfExpr);
    if_expr.* = IfExpr{
        .condition = Expr{ .boolean = true },
        .then_branch = Expr{ .integer = 1 },
        .else_branch = Expr{ .integer = 2 },
    };

    const statements = try allocator.alloc(Statement, 1);
    statements[0] = Statement{
        .debug = Expr{ .if_expr = if_expr },
    };

    const ast = Ast{ .statements = statements, .scope = null };
    defer ast.deinit(allocator);

    var buffer: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const writer = fbs.writer();
    try ast.format(writer);

    const expected = "debug (if true then 1 else 2)\n";
    try std.testing.expectEqualStrings(expected, fbs.getWritten());
}
