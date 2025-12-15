const std = @import("std");
const instruction = @import("instruction.zig");
const semantic_analysis = @import("semantic_analysis.zig");
const syntax = @import("ast.zig");

const Parser = @import("parser.zig").Parser;
const Value = @import("value.zig").Value;
const Closure = @import("value.zig").Closure;
const ValueTag = @import("value.zig").ValueTag;
const Register = @import("instruction.zig").Register;

const CompiledProgram = struct {
    bytecode: []instruction.Instruction,
    constants: []Value,

    pub fn deinit(self: CompiledProgram, allocator: std.mem.Allocator) void {
        for (self.bytecode) |code| {
            if (code == instruction.InstructionTag.CAPTURE_CLOSURE) {
                allocator.free(code.CAPTURE_CLOSURE.captures);
            }
        }
        allocator.free(self.bytecode);
        allocator.free(self.constants);
    }
};

const CompilerError = error{UndefinedVariable};

pub const Emitter = struct {
    bytecode: std.ArrayList(instruction.Instruction),
    constants: std.ArrayList(Value),
    allocator: std.mem.Allocator,

    current_scope: *semantic_analysis.Scope,

    pub fn init(allocator: std.mem.Allocator) Emitter {
        return .{
            .bytecode = std.ArrayList(instruction.Instruction).empty,
            .constants = std.ArrayList(Value).empty,
            .allocator = allocator,
            .current_scope = undefined, // Will be set in emit()
        };
    }

    pub fn deinit(self: *Emitter) void {
        for (self.bytecode.items) |code| {
            if (code == instruction.InstructionTag.CAPTURE_CLOSURE) {
                self.allocator.free(code.CAPTURE_CLOSURE.captures);
            }
        }
        self.bytecode.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    pub fn emit(self: *Emitter, ast: *syntax.Ast) !CompiledProgram {
        try semantic_analysis.analize(self.allocator, ast);

        self.current_scope = ast.scope orelse return error.MissingScope;

        for (ast.statements) |stmt| {
            try self.emitStatement(stmt);
        }

        try self.emitChunk(.{ .HALT = {} });

        return CompiledProgram{
            .bytecode = try self.bytecode.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
        };
    }

    fn emitStatement(self: *Emitter, stmt: syntax.Statement) !void {
        switch (stmt) {
            .definition => |def| try self.emitDefinition(def),
            .debug => |expr| try self.emitDebug(expr),
        }
    }

    fn emitDefinition(self: *Emitter, def: syntax.Definition) !void {
        const dest_reg = try self.current_scope.getRegister(def.name);

        const value_reg = try self.emitExpr(def.value);

        if (value_reg != dest_reg) {
            var last_emit = self.bytecode.items[self.bytecode.items.len - 1];
            if (last_emit == instruction.InstructionTag.CAPTURE_CLOSURE) {
                self.bytecode.items[self.bytecode.items.len - 1] = instruction.Instruction{ .MOVE = .{ .destination = dest_reg, .source = value_reg } };
                last_emit.CAPTURE_CLOSURE.closure = dest_reg;
                try self.emitChunk(last_emit);
            } else {
                try self.emitChunk(instruction.Instruction{ .MOVE = .{ .destination = dest_reg, .source = value_reg } });
            }
        }
    }

    fn emitDebug(self: *Emitter, expr: syntax.Expr) !void {
        const reg = try self.emitExpr(expr);
        try self.emitChunk(instruction.Instruction{ .DEBUG = reg });
    }

    fn emitExpr(self: *Emitter, expr: syntax.Expr) anyerror!Register {
        return switch (expr) {
            .integer => try self.emitInteger(expr.integer),
            .boolean => try self.emitBool(expr.boolean),
            .identifier => try self.emitIdentifier(expr.identifier),
            .binary => try self.emitBinaryExpr(expr.binary),
            .if_expr => try self.emitIf(expr.if_expr),
            .fn_expr => try self.emitFn(expr.fn_expr),
            .def_expr => try self.emitDefExpr(expr.def_expr),
            .call => try self.emitCall(expr.call),
            else => 0,
        };
    }

    fn emitDefExpr(self: *Emitter, expr: *syntax.DefExpr) !Register {
        const parent_scope = self.current_scope;
        const scope = expr.scope orelse return error.MissingScope;
        self.current_scope = scope;

        const destReg = try self.current_scope.getRegister(expr.name);
        const valueReg = try self.emitExpr(expr.body);
        if (destReg != valueReg) {
            var last_emit = self.bytecode.items[self.bytecode.items.len - 1];
            if (last_emit == instruction.InstructionTag.CAPTURE_CLOSURE) {
                self.bytecode.items[self.bytecode.items.len - 1] = instruction.Instruction{ .MOVE = .{ .destination = destReg, .source = valueReg } };
                last_emit.CAPTURE_CLOSURE.closure = valueReg;
                try self.emitChunk(last_emit);
            } else {
                try self.emitChunk(instruction.Instruction{ .MOVE = .{ .destination = destReg, .source = valueReg } });
            }
        }

        const tailReg = try self.emitExpr(expr.expr);
        self.current_scope = parent_scope;
        return tailReg;
    }

    fn emitFn(self: *Emitter, expr: *syntax.FnExpr) anyerror!Register {
        const fnReg = self.allocReg();

        const parent_scope = self.current_scope;

        const fn_scope = expr.scope orelse return error.MissingScope;
        self.current_scope = fn_scope;

        try self.emitChunk(.{ .JMP = 0 });
        const fn_addr = self.bytecode.items.len;

        const ret_reg = try self.emitExpr(expr.body);
        try self.emitChunk(.{ .RETURN = ret_reg });

        self.bytecode.items[fn_addr - 1].JMP = calcOffset(fn_addr, self.bytecode.items.len + 1);

        try self.emitChunk(instruction.Instruction{ .MAKE_CLOSURE = .{
            .destination = fnReg,
            .addr = fn_addr,
            .arity = @intCast(expr.params.len),
        } });

        const captures_copy = try self.allocator.dupe(Register, self.current_scope.capture_layout orelse return error.MissingCaptures);
        try self.emitChunk(instruction.Instruction{ .CAPTURE_CLOSURE = .{ .closure = fnReg, .captures = captures_copy } });

        // Restore the parent scope
        self.current_scope = parent_scope;

        return fnReg;
    }

    fn emitCall(self: *Emitter, expr: *syntax.CallExpr) anyerror!Register {
        const function = try self.emitIdentifier(expr.function.identifier);

        var param_reg: Register = 0;
        if (expr.args.len > 0) {
            param_reg = self.allocReg();

            for (expr.args, 0..) |arg, i| {
                const arg_reg = try self.emitExpr(arg);
                const target_reg = param_reg + @as(Register, @intCast(i));

                if (arg_reg != target_reg) {
                    try self.emitChunk(instruction.Instruction{ .MOVE = .{
                        .destination = target_reg,
                        .source = arg_reg,
                    } });
                }

                while (self.current_scope.next_register <= target_reg) {
                    _ = self.allocReg();
                }
            }
        }

        try self.emitChunk(instruction.Instruction{ .CALL = .{
            .function_reg = function,
            .param_reg = param_reg,
        } });
        return 0;
    }

    fn emitIf(self: *Emitter, expr: *syntax.IfExpr) !Register {
        const conditionReg = try self.emitExpr(expr.condition);
        const resultReg = self.allocReg();

        const jump_if_index = self.bytecode.items.len;
        try self.emitChunk(instruction.Instruction{ .JMP_IF = .{ .offset = 0, .condition = conditionReg } });

        const elseReg = try self.emitExpr(expr.else_branch);
        try self.emitChunk(instruction.Instruction{ .MOVE = .{ .destination = resultReg, .source = elseReg } });

        const jmp_index = self.bytecode.items.len;
        try self.emitChunk(instruction.Instruction{ .JMP = 0 });

        const then_start = self.bytecode.items.len;

        const thenReg = try self.emitExpr(expr.then_branch);
        try self.emitChunk(instruction.Instruction{ .MOVE = .{ .destination = resultReg, .source = thenReg } });

        const jump_if_offset = @as(i64, @intCast(then_start)) -
            @as(i64, @intCast(jump_if_index + 1));
        self.bytecode.items[jump_if_index].JMP_IF.offset = jump_if_offset;

        const jmp_offset = @as(i64, @intCast(self.bytecode.items.len)) -
            @as(i64, @intCast(jmp_index + 1));
        self.bytecode.items[jmp_index].JMP = jmp_offset;

        return resultReg;
    }

    fn calcOffset(to: usize, from: usize) i64 {
        return @as(i64, @intCast(from)) -
            @as(i64, @intCast(to + 1));
    }

    fn emitInteger(self: *Emitter, number: i64) !Register {
        const const_idx = try self.addConstant(Value{ .int = number });
        const reg = self.allocReg();
        try self.emitChunk(instruction.Instruction{ .LOADK = .{ .const_idx = const_idx, .register = reg } });
        return reg;
    }

    fn emitBool(self: *Emitter, val: bool) !Register {
        const const_idx = try self.addConstant(Value{ .bool = val });
        const reg = self.allocReg();
        try self.emitChunk(instruction.Instruction{ .LOADK = .{ .const_idx = const_idx, .register = reg } });
        return reg;
    }

    fn emitIdentifier(self: *Emitter, ident: []const u8) !Register {
        // Look up the variable in the current scope
        return self.current_scope.getRegister(ident);
    }

    fn emitBinaryExpr(self: *Emitter, expr: *syntax.BinaryExpr) !Register {
        const left = try self.emitExpr(expr.left);
        const right = try self.emitExpr(expr.right);
        const reg = self.allocReg();

        const arith_op = instruction.ArithmeticInstruction{ .destination = reg, .a = left, .b = right };
        const comp_op = instruction.ComparisonInstruction{ .destination = reg, .a = left, .b = right };

        switch (expr.op) {
            .Add => try self.emitChunk(instruction.Instruction{ .ADD = arith_op }),
            .Sub => try self.emitChunk(instruction.Instruction{ .SUB = arith_op }),
            .Mul => try self.emitChunk(instruction.Instruction{ .MUL = arith_op }),
            .Div => try self.emitChunk(instruction.Instruction{ .DIV = arith_op }),
            .Mod => try self.emitChunk(instruction.Instruction{ .MOD = arith_op }),
            .Eq => try self.emitChunk(instruction.Instruction{ .EQ = comp_op }),
            .Lt => try self.emitChunk(instruction.Instruction{ .LT = comp_op }),
            .Gt => try self.emitChunk(instruction.Instruction{ .GT = comp_op }),
        }

        return reg;
    }

    fn addConstant(self: *Emitter, value: Value) !u64 {
        // Check if constant already exists
        for (self.constants.items, 0..) |existing, idx| {
            if (valuesEqual(existing, value)) {
                return idx;
            }
        }

        // Not found, add new
        const idx = self.constants.items.len;
        try self.constants.append(self.allocator, value);
        return @as(u64, idx);
    }

    fn emitChunk(self: *Emitter, chunk: instruction.Instruction) !void {
        try self.bytecode.append(self.allocator, chunk);
    }

    fn valuesEqual(a: Value, b: Value) bool {
        if (@as(ValueTag, a) != @as(ValueTag, b)) return false;

        return switch (a) {
            .int => |a_val| a_val == b.int,
            .bool => |a_val| a_val == b.bool,
            .closure => |a_val| a_val.addr == b.closure.addr,
            .nil => true,
        };
    }

    fn allocReg(self: *Emitter) Register {
        // Allocate from the current scope's register pool
        const reg = self.current_scope.next_register;
        self.current_scope.next_register += 1;
        return reg;
    }
};

test "emit simple addition" {
    const source = "let result = 1 + 2";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Expected bytecode:
    // LOADK r0, 0    (load constant 1)
    // LOADK r1, 1    (load constant 2)
    // ADD r2, r0, r1 (add them)
    // HALT

    try std.testing.expectEqual(@as(usize, 4), program.bytecode.len);

    try std.testing.expect(program.bytecode[0] == .LOADK);
    try std.testing.expectEqual(@as(u8, 0), program.bytecode[0].LOADK.register);
    try std.testing.expectEqual(@as(usize, 0), program.bytecode[0].LOADK.const_idx);

    try std.testing.expect(program.bytecode[1] == .LOADK);
    try std.testing.expectEqual(@as(u8, 1), program.bytecode[1].LOADK.register);
    try std.testing.expectEqual(@as(usize, 1), program.bytecode[1].LOADK.const_idx);

    try std.testing.expect(program.bytecode[2] == .ADD);
    try std.testing.expectEqual(@as(u8, 2), program.bytecode[2].ADD.destination);
    try std.testing.expectEqual(@as(u8, 0), program.bytecode[2].ADD.a);
    try std.testing.expectEqual(@as(u8, 1), program.bytecode[2].ADD.b);

    try std.testing.expect(program.bytecode[3] == .HALT);

    // Check constants
    try std.testing.expectEqual(@as(usize, 2), program.constants.len);
    try std.testing.expectEqual(@as(i64, 1), program.constants[0].int);
    try std.testing.expectEqual(@as(i64, 2), program.constants[1].int);
}

test "emit subtraction" {
    const source = "let result = 10 - 3";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    try std.testing.expectEqual(@as(usize, 4), program.bytecode.len);
    try std.testing.expect(program.bytecode[2] == .SUB);
    try std.testing.expectEqual(@as(i64, 10), program.constants[0].int);
    try std.testing.expectEqual(@as(i64, 3), program.constants[1].int);
}

test "emit multiplication" {
    const source = "let result = 4 * 5";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    try std.testing.expect(program.bytecode[2] == .MUL);
}

test "emit division" {
    const source = "let result = 20 / 4";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    try std.testing.expect(program.bytecode[2] == .DIV);
}

test "emit operator precedence" {
    const source = "let result = 2 + 3 * 4";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Expected: 3 * 4 happens first, then 2 + result
    // LOADK r0, 0    (2)
    // LOADK r1, 1    (3)
    // LOADK r2, 2    (4)
    // MUL r3, r1, r2 (3 * 4)
    // ADD r4, r0, r3 (2 + result)
    // HALT

    try std.testing.expectEqual(@as(usize, 6), program.bytecode.len);
    try std.testing.expect(program.bytecode[3] == .MUL);
    try std.testing.expect(program.bytecode[4] == .ADD);
}

test "emit comparison equal" {
    const source = "let result = 5 == 5";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    try std.testing.expect(program.bytecode[2] == .EQ);
}

test "emit comparison less than" {
    const source = "let result = 3 < 5";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    try std.testing.expect(program.bytecode[2] == .LT);
}

test "emit comparison greater than" {
    const source = "let result = 10 > 5";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    try std.testing.expect(program.bytecode[2] == .GT);
}

test "emit constant deduplication" {
    const source = "let result = 5 + 5";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Should only have one constant (5), not two
    try std.testing.expectEqual(@as(usize, 1), program.constants.len);
    try std.testing.expectEqual(@as(i64, 5), program.constants[0].int);

    // Both LOADK should reference same constant
    try std.testing.expectEqual(program.bytecode[0].LOADK.const_idx, program.bytecode[1].LOADK.const_idx);
}

test "emit variable reference" {
    const source =
        \\let x = 5
        \\let y = x
    ;

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // First definition loads 5 into r0
    // Second definition should reference r0 (no new bytecode needed)
    try std.testing.expectEqual(@as(usize, 2), program.bytecode.len); // LOADK + HALT
}

test "emit debug statement" {
    const source = "debug 42";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Expected bytecode:
    // LOADK r0, 0    (load constant 42)
    // DEBUG r0       (debug print r0)
    // HALT

    try std.testing.expectEqual(@as(usize, 3), program.bytecode.len);

    try std.testing.expect(program.bytecode[0] == .LOADK);
    try std.testing.expectEqual(@as(u8, 0), program.bytecode[0].LOADK.register);

    try std.testing.expect(program.bytecode[1] == .DEBUG);
    try std.testing.expectEqual(@as(u8, 0), program.bytecode[1].DEBUG);

    try std.testing.expect(program.bytecode[2] == .HALT);

    // Check constants
    try std.testing.expectEqual(@as(usize, 1), program.constants.len);
    try std.testing.expectEqual(@as(i64, 42), program.constants[0].int);
}

test "emit debug with expression" {
    const source = "debug 2 + 3";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Expected bytecode:
    // LOADK r0, 0    (load constant 2)
    // LOADK r1, 1    (load constant 3)
    // ADD r2, r0, r1 (add them)
    // DEBUG r2       (debug print r2)
    // HALT

    try std.testing.expectEqual(@as(usize, 5), program.bytecode.len);

    try std.testing.expect(program.bytecode[2] == .ADD);
    try std.testing.expect(program.bytecode[3] == .DEBUG);
    try std.testing.expectEqual(@as(u8, 2), program.bytecode[3].DEBUG);
    try std.testing.expect(program.bytecode[4] == .HALT);
}

test "emit debug with variable" {
    const source =
        \\let x = 10
        \\debug x
    ;

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Expected bytecode:
    // LOADK r0, 0    (load constant 10)
    // DEBUG r0       (debug print r0, which is x)
    // HALT

    try std.testing.expectEqual(@as(usize, 3), program.bytecode.len);

    try std.testing.expect(program.bytecode[0] == .LOADK);
    try std.testing.expect(program.bytecode[1] == .DEBUG);
    try std.testing.expectEqual(@as(u8, 0), program.bytecode[1].DEBUG);
    try std.testing.expect(program.bytecode[2] == .HALT);
}

test "emit if expression with true condition" {
    const source = "let result = if true then 1 else 0";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Expected structure:
    // LOADK r0, 0       (true)
    // JMP_IF r0, +X     (if true, jump to then)
    // LOADK r1, 1       (else: 0)
    // MOVE r3, r1
    // JMP +Y            (skip then)
    // LOADK r2, 2       (then: 1)
    // MOVE r3, r2
    // HALT

    // Verify we have the key instructions
    var has_jmp_if = false;
    var has_jmp = false;
    var loadk_count: usize = 0;

    for (program.bytecode) |instr| {
        switch (instr) {
            .JMP_IF => has_jmp_if = true,
            .JMP => has_jmp = true,
            .LOADK => loadk_count += 1,
            else => {},
        }
    }

    try std.testing.expect(has_jmp_if);
    try std.testing.expect(has_jmp);
    try std.testing.expectEqual(@as(usize, 3), loadk_count); // true, 0, 1
}

test "emit if expression with comparison" {
    const source = "let result = if 5 > 3 then 10 else 20";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    const program = try emitter.emit(&ast);
    defer emitter.deinit();
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Should have GT instruction for comparison
    var has_gt = false;
    var has_jmp_if = false;

    for (program.bytecode) |instr| {
        switch (instr) {
            .GT => has_gt = true,
            .JMP_IF => has_jmp_if = true,
            else => {},
        }
    }

    try std.testing.expect(has_gt);
    try std.testing.expect(has_jmp_if);
}

test "emit nested if expression" {
    const source = "let result = if true then (if false then 1 else 2) else 3";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Should have two JMP_IF (one for outer, one for inner)
    var jmp_if_count: usize = 0;

    for (program.bytecode) |instr| {
        if (instr == .JMP_IF) {
            jmp_if_count += 1;
        }
    }

    try std.testing.expectEqual(@as(usize, 2), jmp_if_count);
}

test "emit if with arithmetic in branches" {
    const source = "let result = if true then 1 + 2 else 3 * 4";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    var has_add = false;
    var has_mul = false;
    var has_jmp_if = false;

    for (program.bytecode) |instr| {
        switch (instr) {
            .ADD => has_add = true,
            .MUL => has_mul = true,
            .JMP_IF => has_jmp_if = true,
            else => {},
        }
    }

    try std.testing.expect(has_add);
    try std.testing.expect(has_mul);
    try std.testing.expect(has_jmp_if);
}

test "emit if jump offsets are valid" {
    const source = "let result = if true then 1 else 0";

    var parser = Parser.init(std.testing.allocator, source);
    var ast = try parser.parse();
    defer ast.deinit(std.testing.allocator);

    var emitter = Emitter.init(std.testing.allocator);
    defer emitter.deinit();
    const program = try emitter.emit(&ast);
    defer {
        std.testing.allocator.free(program.bytecode);
        std.testing.allocator.free(program.constants);
    }

    // Find JMP_IF and verify its offset is positive (jumps forward)
    for (program.bytecode) |instr| {
        if (instr == .JMP_IF) {
            // Offset should be positive (jumping forward to then branch)
            try std.testing.expect(instr.JMP_IF.offset > 0);
        }
        if (instr == .JMP) {
            // JMP after else should also be positive (jumping over then)
            try std.testing.expect(instr.JMP > 0);
        }
    }
}
