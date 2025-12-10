const std = @import("std");
const Register = @import("instruction.zig").Register;
const syntax = @import("ast.zig");
const parser = @import("parser.zig");

const VariableInfo = struct { register_index: Register, is_captured: bool, kind: union(enum) { Parameter, Local } };
const CaptureInfo = struct {
    name: []const u8,
    source_reg: Register,
};

pub const Scope = struct {
    parent: ?*Scope,
    variables: std.StringHashMap(VariableInfo),
    captures: std.ArrayList(CaptureInfo),
    next_register: u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Scope {
        const scope = try allocator.create(Scope);
        scope.* = Scope{ .parent = null, .variables = std.StringHashMap(VariableInfo).init(allocator), .captures = std.ArrayList(CaptureInfo).empty, .next_register = 0, .allocator = allocator };
        return scope;
    }

    pub fn initFromParent(parent: *Scope) !*Scope {
        const scope = try Scope.init(parent.allocator);
        scope.*.parent = parent;
        return scope;
    }

    pub fn deinit(self: *Scope) void {
        self.variables.deinit();
        self.captures.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn defineVariable(self: *Scope, name: []const u8) !void {
        const variable = self.variables.get(name);
        if (variable) |_| {
            return;
        }
        const reg = self.next_register;
        try self.variables.put(name, VariableInfo{ .register_index = reg, .is_captured = false, .kind = .Local });
        self.next_register += 1;
        return;
    }

    fn capture(self: *Scope, name: []const u8) !Register {
        if (self.variables.get(name)) |variable| {
            return variable.register_index;
        }

        if (self.parent) |parent| {
            const capturedReg = try parent.capture(name);
            try self.captures.append(self.allocator, CaptureInfo{ .name = name, .source_reg = capturedReg });

            var entries = std.ArrayList(struct { name: []const u8, info: VariableInfo }).empty;
            defer entries.deinit(self.allocator);

            var iter = self.variables.iterator();
            while (iter.next()) |entry| {
                try entries.append(self.allocator, .{ .name = entry.key_ptr.*, .info = entry.value_ptr.* });
            }

            const SortContext = struct {
                fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
                    return a.info.register_index < b.info.register_index;
                }
            };
            std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, SortContext.lessThan);

            var insertion_reg: Register = 0;

            for (entries.items) |*entry| {
                if (!entry.info.is_captured) {
                    if (insertion_reg == 0) {
                        insertion_reg = entry.info.register_index;
                    }
                    entry.info.register_index += 1;
                    try self.variables.put(entry.name, entry.info);
                }
            }
            const reg = insertion_reg;
            try self.variables.put(name, VariableInfo{ .is_captured = true, .kind = .Local, .register_index = reg });
            self.next_register += 1;

            return reg;
        }

        return error.UndefinedVariable;
    }

    fn defineParam(self: *Scope, name: []const u8) !void {
        var entries = std.ArrayList(struct { name: []const u8, info: VariableInfo }).empty;
        defer entries.deinit(self.allocator);

        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            try entries.append(self.allocator, .{ .name = entry.key_ptr.*, .info = entry.value_ptr.* });
        }

        const SortContext = struct {
            fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
                return a.info.register_index < b.info.register_index;
            }
        };
        std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, SortContext.lessThan);
        var insertion_reg: ?Register = null;
        for (entries.items) |*entry| {
            if (entry.info.kind == .Local and !entry.info.is_captured) {
                if (insertion_reg == null) {
                    insertion_reg = entry.info.register_index;
                }
                entry.info.register_index += 1;
                try self.variables.put(entry.name, entry.info);
            }
        }

        if (insertion_reg) |reg| {
            try self.variables.put(name, VariableInfo{ .is_captured = false, .kind = .Parameter, .register_index = reg });
        } else {
            try self.variables.put(name, VariableInfo{ .is_captured = false, .kind = .Parameter, .register_index = self.next_register });
            self.next_register += 1;
        }
    }
};

pub fn analyze(allocator: std.mem.Allocator, ast: *syntax.Ast) !void {
    try Binder.buildScope(allocator, ast);
}

// Bind variable names to registers
const Binder = struct {
    current_scope: *Scope,

    pub fn buildScope(allocator: std.mem.Allocator, ast: *syntax.Ast) !void {
        const scope = try Scope.init(allocator);
        var analyzer = Binder{ .current_scope = scope };

        ast.scope = scope;

        for (ast.statements) |statement| {
            try analyzer.analizeStatement(&statement);
        }
    }

    fn analizeStatement(self: *Binder, statement: *const syntax.Statement) !void {
        switch (statement.*) {
            .definition => |definition| {
                try self.current_scope.defineVariable(definition.name);
                try self.analizeExpr(&definition.value);
            },
            .debug => |debug| try self.analizeExpr(&debug),
        }
    }

    fn analizeExpr(self: *Binder, expr: *const syntax.Expr) anyerror!void {
        switch (expr.*) {
            .fn_expr => |fn_e| try self.analizeFn(fn_e),
            .binary => |binary_e| try self.analizeBinary(binary_e),
            .identifier => |ident| _ = try self.current_scope.capture(ident),
            .call => |call| try self.analizeCall(call),
            .if_expr => |if_e| try self.anailizeIf(if_e),
            .def_expr => |def_ex| try self.analizeDefExpr(def_ex),
            else => {},
        }
    }

    fn analizeCall(self: *Binder, expr: *syntax.CallExpr) !void {
        try self.analizeExpr(&expr.function);
        for (expr.args) |*arg| {
            try self.analizeExpr(arg);
        }
    }

    fn analizeFn(self: *Binder, expr: *syntax.FnExpr) !void {
        const scope = try Scope.initFromParent(self.current_scope);
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

    fn analizeDefExpr(self: *Binder, expr: *syntax.DefExpr) !void {
        try self.current_scope.defineVariable(expr.name);
        try self.analizeExpr(&expr.body);
        try self.analizeExpr(&expr.expr);
    }

    fn anailizeIf(self: *Binder, expr: *syntax.IfExpr) !void {
        try self.analizeExpr(&expr.condition);
        try self.analizeExpr(&expr.else_branch);
        try self.analizeExpr(&expr.then_branch);
    }

    fn analizeBinary(self: *Binder, expr: *syntax.BinaryExpr) !void {
        try self.analizeExpr(&expr.left);
        try self.analizeExpr(&expr.right);
    }
};

test "scope: defines params correctly" {
    var scope = try Scope.init(std.testing.allocator);
    defer scope.deinit();
    try scope.defineVariable("init");
    try scope.defineVariable("bruh");
    try std.testing.expectEqual(0, scope.variables.get("init").?.register_index);
    try std.testing.expectEqual(1, scope.variables.get("bruh").?.register_index);

    // inserting param
    try scope.defineParam("a");
    try std.testing.expectEqual(0, scope.variables.get("a").?.register_index);
    try std.testing.expectEqual(1, scope.variables.get("init").?.register_index);
    try std.testing.expectEqual(2, scope.variables.get("bruh").?.register_index);

    // capture from parent
    var scope2 = try Scope.initFromParent(scope);
    defer scope2.deinit();
    try scope2.defineVariable("scope2");
    _ = try scope2.capture("a");
    _ = try scope2.capture("scope2");
    _ = try scope2.capture("bruh");
    try std.testing.expectEqual(2, scope2.captures.items.len);
    try std.testing.expectEqual(0, scope2.variables.get("a").?.register_index);
    try std.testing.expectEqual(1, scope2.variables.get("bruh").?.register_index);
    try std.testing.expectEqual(2, scope2.variables.get("scope2").?.register_index);

    var scope3 = try Scope.initFromParent(scope2);
    defer scope3.deinit();
    try scope3.defineVariable("wow");
    _ = try scope3.capture("init");
    _ = try scope3.capture("scope2");
    try std.testing.expectEqual(3, scope2.captures.items.len);
    try std.testing.expectEqual(2, scope2.variables.get("init").?.register_index);
    try std.testing.expectEqual(3, scope2.variables.get("scope2").?.register_index);

    try std.testing.expectEqual(2, scope3.captures.items.len);
    try std.testing.expectEqual(0, scope3.variables.get("init").?.register_index);
    try std.testing.expectEqual(1, scope3.variables.get("scope2").?.register_index);
}

test "binder: defines registers for global variables" {
    const code = "let a = 2";

    var parse = parser.Parser.init(std.testing.allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(std.testing.allocator);
    try Binder.buildScope(std.testing.allocator, &ast);
    try std.testing.expectEqual(0, ast.scope.?.variables.get("a").?.register_index);
}

test "binder: captures registers from parents" {
    const code =
        \\let x = 5
        \\let y = fn a => x + a
    ;
    var parse = parser.Parser.init(std.testing.allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(std.testing.allocator);
    try Binder.buildScope(std.testing.allocator, &ast);
    try std.testing.expectEqual(0, ast.scope.?.variables.get("x").?.register_index);

    try std.testing.expectEqual(0, ast.statements[1].definition.value.fn_expr.scope.?.variables.get("x").?.register_index);
    try std.testing.expectEqual(1, ast.statements[1].definition.value.fn_expr.scope.?.variables.get("a").?.register_index);
    try std.testing.expectEqual(1, ast.statements[1].definition.value.fn_expr.scope.?.captures.items.len);
}

test "binder: handles reccursion" {
    const code =
        \\let y = fn a => y 1
    ;
    var parse = parser.Parser.init(std.testing.allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(std.testing.allocator);
    try Binder.buildScope(std.testing.allocator, &ast);
    try std.testing.expectEqual(0, ast.scope.?.variables.get("y").?.register_index);

    try std.testing.expectEqual(0, ast.statements[0].definition.value.fn_expr.scope.?.variables.get("y").?.register_index);
    try std.testing.expectEqual(1, ast.statements[0].definition.value.fn_expr.scope.?.captures.items.len);
}

test "binder: captures variables in ifs" {
    const code = "let factorial = fn x => if x < 1 then 1 else x * (factorial (x - 1))";
    var parse = parser.Parser.init(std.testing.allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(std.testing.allocator);
    try Binder.buildScope(std.testing.allocator, &ast);
    try std.testing.expectEqual(0, ast.scope.?.variables.get("factorial").?.register_index);

    try std.testing.expectEqual(0, ast.statements[0].definition.value.fn_expr.scope.?.variables.get("factorial").?.register_index);
    try std.testing.expectEqual(1, ast.statements[0].definition.value.fn_expr.scope.?.captures.items.len);
}

test "binder: captures in debug" {
    const code =
        \\ let aa = 5
        \\ debug aa
    ;

    var parse = parser.Parser.init(std.testing.allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(std.testing.allocator);
    try Binder.buildScope(std.testing.allocator, &ast);
}

test "binder: captures error in debug" {
    const code =
        \\ debug aa
    ;

    var parse = parser.Parser.init(std.testing.allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(std.testing.allocator);
    try std.testing.expectError(error.UndefinedVariable, Binder.buildScope(std.testing.allocator, &ast));
}
