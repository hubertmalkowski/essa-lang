const std = @import("std");
const Register = @import("instruction.zig").Register;
const syntax = @import("ast.zig");
const Parser = @import("parser.zig").Parser;

pub fn analize(allocator: std.mem.Allocator, ast: *syntax.Ast) !void {
    try buildCaptures(allocator, ast);
    try assignRegisters(ast);
}

const VariableType = enum { param, local, capture };

const CaptureInfo = struct {
    name: []const u8,
    source_reg: Register,
};

pub const Scope = struct {
    parent: ?*Scope,
    captures: std.StringHashMap(void),
    variables: std.StringHashMap(VariableType),
    allocator: std.mem.Allocator,
    type: union(enum) { closed, open },
    register_map: ?std.StringHashMap(Register) = null,
    capture_layout: ?[]Register = null,
    next_register: Register = 0,

    pub fn init(allocator: std.mem.Allocator) !*Scope {
        const scope = try allocator.create(Scope);
        scope.* = Scope{
            .parent = null,
            .variables = std.StringHashMap(VariableType).init(allocator), //
            .captures = std.StringHashMap(void).init(allocator),
            .type = .closed,
            .allocator = allocator,
        };
        return scope;
    }

    pub fn deinit(self: *Scope) void {
        self.variables.deinit();
        self.captures.deinit();
        if (self.register_map) |*map| {
            map.deinit();
        }

        if (self.capture_layout) |layout| {
            self.allocator.free(layout);
        }

        self.allocator.destroy(self);
    }

    pub fn initClosed(parent: *Scope) !*Scope {
        const scope = try Scope.init(parent.allocator);
        scope.*.parent = parent;
        return scope;
    }

    pub fn initOpen(parent: *Scope) !*Scope {
        const scope = try Scope.init(parent.allocator);
        scope.*.parent = parent;
        scope.*.type = .open;
        return scope;
    }

    fn capture(self: *Scope, name: []const u8) !void {
        if (self.variables.get(name)) |_| {
            return;
        }

        if (self.parent) |parent| {
            try parent.capture(name);

            try self.variables.put(name, VariableType.capture);
            try self.captures.put(name, {});
            return;
        }

        return error.UndefinedVariable;
    }

    fn defineVariable(self: *Scope, name: []const u8) !void {
        try self.variables.put(name, VariableType.local);
    }

    fn defineParam(self: *Scope, name: []const u8) !void {
        try self.variables.put(name, VariableType.param);
    }

    pub fn getRegister(self: *Scope, name: []const u8) !Register {
        if (self.register_map) |map| {
            return map.get(name) orelse error.UndefinedVariable;
        }
        return error.UndefinedVariable;
    }

    fn calculateRegisters(self: *Scope) !void {
        var registerMap = std.StringHashMap(Register).init(self.allocator);
        if (self.type == .closed) {
            if (self.parent) |parent| {
                var captureLayout = std.ArrayList(Register).empty;
                var captureIter = self.captures.iterator();
                // We map captures
                while (captureIter.next()) |cap| {
                    const parentRegister = try parent.getRegister(cap.key_ptr.*);
                    try captureLayout.append(self.allocator, parentRegister);
                    try registerMap.put(cap.key_ptr.*, self.next_register);
                    self.next_register += 1;
                }
                self.capture_layout = try captureLayout.toOwnedSlice(self.allocator);
            }

            var variables = self.variables.iterator();

            // We map params
            while (variables.next()) |variable| {
                if (variable.value_ptr.* == .param) {
                    try registerMap.put(variable.key_ptr.*, self.next_register);
                    self.next_register += 1;
                }
            }

            variables = self.variables.iterator();

            // map variables
            while (variables.next()) |variable| {
                if (variable.value_ptr.* == .local) {
                    try registerMap.put(variable.key_ptr.*, self.next_register);
                    self.next_register += 1;
                }
            }
        } else {
            if (self.parent) |parent| {
                var captureIter = self.captures.iterator();
                self.next_register = parent.next_register;
                while (captureIter.next()) |cap| {
                    const parentRegister = try parent.getRegister(cap.key_ptr.*);
                    try registerMap.put(cap.key_ptr.*, parentRegister);
                }
            }

            var variables = self.variables.iterator();
            while (variables.next()) |variable| {
                if (variable.value_ptr.* == .local) {
                    try registerMap.put(variable.key_ptr.*, self.next_register);
                    self.next_register += 1;
                }
            }
        }
        self.register_map = registerMap;
    }
};

pub fn buildCaptures(allocator: std.mem.Allocator, ast: *syntax.Ast) !void {
    return CaptureBuilder.build(allocator, ast);
}

const CaptureBuilder = struct {
    current_scope: *Scope,

    fn build(allocator: std.mem.Allocator, ast: *syntax.Ast) !void {
        const scope = try Scope.init(allocator);
        var analyzer = CaptureBuilder{ .current_scope = scope };
        ast.scope = scope;

        for (ast.statements) |statement| {
            try analyzer.analizeStatement(&statement);
        }
    }

    fn analizeStatement(self: *CaptureBuilder, statement: *const syntax.Statement) !void {
        switch (statement.*) {
            .definition => |definition| {
                try self.current_scope.defineVariable(definition.name);
                try self.analizeExpr(&definition.value);
            },
            .debug => |debug| try self.analizeExpr(&debug),
        }
    }

    fn analizeExpr(self: *CaptureBuilder, expr: *const syntax.Expr) anyerror!void {
        switch (expr.*) {
            .fn_expr => |fn_e| try self.analizeFn(fn_e),
            .binary => |binary_e| try self.analizeBinary(binary_e),
            .identifier => |ident| _ = try self.current_scope.capture(ident),
            .call => |call| try self.analizeCall(call),
            .if_expr => |if_e| try self.analizeIf(if_e),
            .def_expr => |def_ex| try self.analizeDefExpression(def_ex),
            else => {},
        }
    }

    fn analizeBinary(self: *CaptureBuilder, expr: *const syntax.BinaryExpr) !void {
        try self.analizeExpr(&expr.left);
        try self.analizeExpr(&expr.right);
    }

    fn analizeCall(self: *CaptureBuilder, expr: *const syntax.CallExpr) !void {
        try self.analizeExpr(&expr.function);
        for (expr.args) |*arg| {
            try self.analizeExpr(arg);
        }
    }

    fn analizeIf(self: *CaptureBuilder, expr: *const syntax.IfExpr) !void {
        try self.analizeExpr(&expr.condition);
        try self.analizeExpr(&expr.then_branch);
        try self.analizeExpr(&expr.else_branch);
    }

    fn analizeDefExpression(self: *CaptureBuilder, expr: *syntax.DefExpr) !void {
        const scope = try Scope.initOpen(self.current_scope);
        self.current_scope = scope;
        expr.scope = scope;
        try self.current_scope.defineVariable(expr.name);
        try self.analizeExpr(&expr.body);
        try self.analizeExpr(&expr.expr);
        if (scope.parent) |parent| {
            self.current_scope = parent;
        }
    }

    fn analizeFn(self: *CaptureBuilder, expr: *syntax.FnExpr) !void {
        const scope = try Scope.initClosed(self.current_scope);
        self.current_scope = scope;
        expr.scope = scope;
        for (expr.params) |param| {
            try self.current_scope.defineParam(param);
        }
        try self.analizeExpr(&expr.body);
        if (scope.parent) |parent| {
            self.current_scope = parent;
        }
    }
};

fn assignRegisters(ast: *syntax.Ast) !void {
    if (ast.scope) |scope| {
        try scope.calculateRegisters();
    }
    for (ast.statements) |statement| {
        try assignStatementRegisters(&statement);
    }
}

fn assignStatementRegisters(stmt: *const syntax.Statement) !void {
    switch (stmt.*) {
        .debug => |expr| try assignExpressionRegisters(&expr),
        .definition => |def| try assignExpressionRegisters(&def.value),
    }
}

fn assignExpressionRegisters(ast: *const syntax.Expr) !void {
    switch (ast.*) {
        .fn_expr => |fn_e| {
            if (fn_e.scope) |scope| {
                try scope.calculateRegisters();
                try assignExpressionRegisters(&fn_e.body);
            }
        },
        .def_expr => |def_e| {
            if (def_e.scope) |scope| {
                try scope.calculateRegisters();
                try assignExpressionRegisters(&def_e.body);
                try assignExpressionRegisters(&def_e.expr);
            }
        },
        .binary => |bin| {
            try assignExpressionRegisters(&bin.left);
            try assignExpressionRegisters(&bin.right);
        },
        .if_expr => |if_e| {
            try assignExpressionRegisters(&if_e.condition);
            try assignExpressionRegisters(&if_e.then_branch);
            try assignExpressionRegisters(&if_e.else_branch);
        },
        .call => |call| {
            try assignExpressionRegisters(&call.function);
            for (call.args) |*arg| {
                try assignExpressionRegisters(arg);
            }
        },
        .integer, .boolean, .unit, .identifier => {
            // No nested expressions to process
        },
    }
}

test "capture_builder: captures variables in closed" {
    const code =
        \\ let b = 2
        \\ let a = fn => b
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try std.testing.expectEqual({}, ast.statements[1].definition.value.fn_expr.scope.?.captures.get("b"));
}

test "capture_builder: captures in open scopes" {
    const code =
        \\ let b = 2
        \\ let a = let c = 2 in c
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);

    try std.testing.expectEqual(VariableType.local, ast.statements[1].definition.value.def_expr.scope.?.variables.get("c"));
}

test "register assigner works" {
    const code =
        \\ let b = 2
        \\ let a = fn z => b
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("b"));
    try std.testing.expectEqual(0, ast.statements[1].definition.value.fn_expr.scope.?.register_map.?.get("b"));
    try std.testing.expectEqual(1, ast.statements[1].definition.value.fn_expr.scope.?.register_map.?.get("z"));
}

test "register assigner handles let..in expression" {
    const code =
        \\ let b = let a = 5 in a
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("b"));
    try std.testing.expectEqual(1, ast.statements[0].definition.value.def_expr.scope.?.getRegister("a"));
}

test "register assigner: power function" {
    const code =
        \\let power = fn base exp =>
        \\    let multiply = fn times result =>
        \\        if times == 0 then
        \\            result
        \\        else
        \\            multiply (times - 1) (result * base)
        \\    in
        \\    multiply exp 1
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope: power is a local variable
    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("power"));

    // Power function scope (closed): base, exp are params (no captures)
    const power_scope = ast.statements[0].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(0, power_scope.captures.count());

    // Params should be r0 and r1 (in some order due to HashMap iteration)
    const base_reg = power_scope.register_map.?.get("base").?;
    const exp_reg = power_scope.register_map.?.get("exp").?;
    try std.testing.expect(base_reg <= 1);
    try std.testing.expect(exp_reg <= 1);
    try std.testing.expect(base_reg != exp_reg);

    // Multiply function scope (closed): has captures (multiply, base), and params (times, result)
    const multiply_scope = ast.statements[0].definition.value.fn_expr.body.def_expr.body.fn_expr.scope.?;

    // Verify multiply_scope has 2 captures and 2 params
    try std.testing.expectEqual(2, multiply_scope.captures.count());

    // Get capture registers - they should be r0 and r1 (in some order)
    const multiply_reg = multiply_scope.register_map.?.get("multiply").?;
    const base_cap_reg = multiply_scope.register_map.?.get("base").?;

    // Both captures should be in range [0, 1]
    try std.testing.expect(multiply_reg <= 1);
    try std.testing.expect(base_cap_reg <= 1);
    try std.testing.expect(multiply_reg != base_cap_reg);

    // Params should come after captures (registers 2 and 3, in some order)
    const times_reg = multiply_scope.register_map.?.get("times").?;
    const result_reg = multiply_scope.register_map.?.get("result").?;

    try std.testing.expect(times_reg >= 2 and times_reg <= 3);
    try std.testing.expect(result_reg >= 2 and result_reg <= 3);
    try std.testing.expect(times_reg != result_reg);
}

test "register assignment: closed scope with no captures, only params" {
    const code =
        \\ let add = fn x y => x + y
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("add"));

    // Add function scope: no captures, params start at r0
    const add_scope = ast.statements[0].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(0, add_scope.captures.count());
    try std.testing.expectEqual(0, add_scope.register_map.?.get("x"));
    try std.testing.expectEqual(1, add_scope.register_map.?.get("y"));
}

test "register assignment: closed scope with one capture and params" {
    const code =
        \\ let x = 10
        \\ let add_x = fn y => x + y
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("x"));
    try std.testing.expectEqual(1, ast.scope.?.register_map.?.get("add_x"));

    // add_x function scope: 1 capture (x), 1 param (y)
    const add_x_scope = ast.statements[1].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(1, add_x_scope.captures.count());

    // Capture gets r0
    try std.testing.expectEqual(0, add_x_scope.register_map.?.get("x"));

    // Param gets r1 (after capture)
    try std.testing.expectEqual(1, add_x_scope.register_map.?.get("y"));
}

test "register assignment: closed scope with captures, params, and locals" {
    const code =
        \\ let x = 10
        \\ let outer = fn y =>
        \\     let z = x + y
        \\     in z
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("x"));
    try std.testing.expectEqual(1, ast.scope.?.register_map.?.get("outer"));

    // Outer function scope: 1 capture (x), 1 param (y), 0 locals
    const outer_scope = ast.statements[1].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(1, outer_scope.captures.count());
    try std.testing.expectEqual(0, outer_scope.register_map.?.get("x"));
    try std.testing.expectEqual(1, outer_scope.register_map.?.get("y"));
}

test "register assignment: nested closed scopes with multi-level captures" {
    const code =
        \\ let a = 1
        \\ let outer = fn b =>
        \\     let middle = fn c =>
        \\         let inner = fn d => a + b + c + d
        \\         in inner 4
        \\     in middle 3
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    const a_root_reg = ast.scope.?.register_map.?.get("a").?;
    const outer_reg = ast.scope.?.register_map.?.get("outer").?;
    try std.testing.expect(a_root_reg <= 1);
    try std.testing.expect(outer_reg <= 1);
    try std.testing.expect(a_root_reg != outer_reg);

    // Outer function scope: 1 capture (a), 1 param (b)
    const outer_scope = ast.statements[1].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(1, outer_scope.captures.count());
    try std.testing.expectEqual(0, outer_scope.register_map.?.get("a")); // capture at r0
    try std.testing.expectEqual(1, outer_scope.register_map.?.get("b")); // param at r1

    // Middle function scope: 2 captures (a, b), 1 param (c)
    // The body is: let middle = fn c => let inner = fn d => ...
    const middle_scope = ast.statements[1].definition.value.fn_expr.body.def_expr.body.fn_expr.scope.?;
    try std.testing.expectEqual(2, middle_scope.captures.count());

    // Captures should be r0 and r1 (in some order)
    const a_mid_reg = middle_scope.register_map.?.get("a").?;
    const b_mid_reg = middle_scope.register_map.?.get("b").?;
    try std.testing.expect(a_mid_reg <= 1);
    try std.testing.expect(b_mid_reg <= 1);
    try std.testing.expect(a_mid_reg != b_mid_reg);

    // Param comes after captures at r2
    try std.testing.expectEqual(2, middle_scope.register_map.?.get("c"));

    // Inner function scope: 3 captures (a, b, c), 1 param (d)
    const inner_scope = ast.statements[1].definition.value.fn_expr.body.def_expr.body.fn_expr.body.def_expr.body.fn_expr.scope.?;
    try std.testing.expectEqual(3, inner_scope.captures.count());

    // Captures should be r0, r1, r2 (in some order)
    const inner_a_reg = inner_scope.register_map.?.get("a").?;
    const inner_b_reg = inner_scope.register_map.?.get("b").?;
    const inner_c_reg = inner_scope.register_map.?.get("c").?;
    try std.testing.expect(inner_a_reg <= 2);
    try std.testing.expect(inner_b_reg <= 2);
    try std.testing.expect(inner_c_reg <= 2);

    // All captures should have different registers
    try std.testing.expect(inner_a_reg != inner_b_reg);
    try std.testing.expect(inner_a_reg != inner_c_reg);
    try std.testing.expect(inner_b_reg != inner_c_reg);

    // Param comes after all captures at r3
    try std.testing.expectEqual(3, inner_scope.register_map.?.get("d"));
}

test "register assignment: open scope inherits parent's next_register" {
    const code =
        \\ let a = 1
        \\ let b = let c = 2 in c + a
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    const a_reg = ast.scope.?.register_map.?.get("a").?;
    const b_reg = ast.scope.?.register_map.?.get("b").?;
    try std.testing.expect(a_reg <= 1);
    try std.testing.expect(b_reg <= 1);
    try std.testing.expect(a_reg != b_reg);

    // Open scope (let..in): inherits parent's next_register
    const open_scope = ast.statements[1].definition.value.def_expr.scope.?;
    try std.testing.expectEqual(.open, open_scope.type);

    // Captured variable 'a' uses parent's register (same as in root)
    try std.testing.expectEqual(a_reg, open_scope.register_map.?.get("a"));

    // Local variable 'c' gets next available register (should be 2, after both root variables)
    try std.testing.expectEqual(2, open_scope.register_map.?.get("c"));
}

test "register assignment: open scope with multiple captures" {
    const code =
        \\ let x = 1
        \\ let y = 2
        \\ let z = let w = x + y in w
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope - get actual register assignments
    const x_reg = ast.scope.?.register_map.?.get("x").?;
    const y_reg = ast.scope.?.register_map.?.get("y").?;
    const z_reg = ast.scope.?.register_map.?.get("z").?;

    // All three should have different registers in range [0, 2]
    try std.testing.expect(x_reg <= 2);
    try std.testing.expect(y_reg <= 2);
    try std.testing.expect(z_reg <= 2);
    try std.testing.expect(x_reg != y_reg);
    try std.testing.expect(x_reg != z_reg);
    try std.testing.expect(y_reg != z_reg);

    // Open scope: captures x and y using parent registers
    const open_scope = ast.statements[2].definition.value.def_expr.scope.?;
    try std.testing.expectEqual(.open, open_scope.type);
    try std.testing.expectEqual(x_reg, open_scope.register_map.?.get("x"));
    try std.testing.expectEqual(y_reg, open_scope.register_map.?.get("y"));

    // Local w gets next register after parent's next_register (should be 3)
    try std.testing.expectEqual(3, open_scope.register_map.?.get("w"));
}

test "register assignment: function with no params, only locals" {
    const code =
        \\ let make_five = fn =>
        \\     let x = 5
        \\     in x
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("make_five"));

    // Function scope: no captures, no params
    const fn_scope = ast.statements[0].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(0, fn_scope.captures.count());

    // The function body is a def_expr (open scope)
    // Since there are no params or captures, registers start at 0
    try std.testing.expectEqual(0, fn_scope.next_register);
}

test "register assignment: function with only captures, no params" {
    const code =
        \\ let x = 10
        \\ let get_x = fn => x
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    // Root scope
    try std.testing.expectEqual(0, ast.scope.?.register_map.?.get("x"));
    try std.testing.expectEqual(1, ast.scope.?.register_map.?.get("get_x"));

    // Function scope: 1 capture (x), no params
    const fn_scope = ast.statements[1].definition.value.fn_expr.scope.?;
    try std.testing.expectEqual(1, fn_scope.captures.count());
    try std.testing.expectEqual(0, fn_scope.register_map.?.get("x"));

    // next_register should be 1 (after the capture)
    try std.testing.expectEqual(1, fn_scope.next_register);
}

test "debug: power function register assignments and capture layout" {
    const code =
        \\let power = fn base exp =>
        \\    let multiply = fn times result =>
        \\        if times == 0 then
        \\            result
        \\        else
        \\            multiply (times - 1) (result * base)
        \\    in
        \\    multiply exp 1
    ;

    var parser = Parser.init(std.testing.allocator, code);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);
    try buildCaptures(std.testing.allocator, &ast);
    try assignRegisters(&ast);

    const power_scope = ast.statements[0].definition.value.fn_expr.scope.?;
    std.debug.print("\nPower function registers:\n", .{});
    std.debug.print("  base: r{?}\n", .{power_scope.register_map.?.get("base")});
    std.debug.print("  exp: r{?}\n", .{power_scope.register_map.?.get("exp")});
    
    const def_scope = ast.statements[0].definition.value.fn_expr.body.def_expr.scope.?;
    std.debug.print("\nLet..in scope registers:\n", .{});
    std.debug.print("  multiply: r{?}\n", .{def_scope.register_map.?.get("multiply")});
    std.debug.print("  exp: r{?}\n", .{def_scope.register_map.?.get("exp")});
    std.debug.print("  base: r{?}\n", .{def_scope.register_map.?.get("base")});
    
    const multiply_scope = ast.statements[0].definition.value.fn_expr.body.def_expr.body.fn_expr.scope.?;
    std.debug.print("\nMultiply function registers:\n", .{});
    std.debug.print("  multiply: r{?}\n", .{multiply_scope.register_map.?.get("multiply")});
    std.debug.print("  base: r{?}\n", .{multiply_scope.register_map.?.get("base")});
    std.debug.print("  times: r{?}\n", .{multiply_scope.register_map.?.get("times")});
    std.debug.print("  result: r{?}\n", .{multiply_scope.register_map.?.get("result")});
    
    std.debug.print("\nCapture layout: {any}\n", .{multiply_scope.capture_layout});
}
