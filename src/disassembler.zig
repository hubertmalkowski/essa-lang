const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Value = @import("value.zig").Value;

pub const Disassembler = struct {
    const COMMENT_COLUMN = 30;

    pub fn disassemble(bytecode: []const Instruction, constants: []const Value) void {
        std.debug.print("=== Disassembly ===\n", .{});

        std.debug.print("\nConstants:\n", .{});
        for (constants, 0..) |constant, i| {
            std.debug.print("  [{d}] = {f}\n", .{ i, constant });
        }

        std.debug.print("\nBytecode:\n", .{});
        for (bytecode, 0..) |instr, addr| {
            std.debug.print("{d:0>4} ", .{addr});
            const instr_len = printInstruction(instr);

            // Pad to comment column
            const padding = if (instr_len < COMMENT_COLUMN) COMMENT_COLUMN - instr_len else 1;
            var i: usize = 0;
            while (i < padding) : (i += 1) {
                std.debug.print(" ", .{});
            }

            std.debug.print("; ", .{});
            printComment(instr, addr, constants);
            std.debug.print("\n", .{});
        }
        std.debug.print("===================\n", .{});
    }

    fn printInstruction(instr: Instruction) usize {
        return switch (instr) {
            .LOADK => |i| blk: {
                std.debug.print("LOADK {d} {d}", .{ i.register, i.const_idx });
                break :blk instructionLength("LOADK", .{ i.register, i.const_idx });
            },
            .MOVE => |i| blk: {
                std.debug.print("MOVE {d} {d}", .{ i.destination, i.source });
                break :blk instructionLength("MOVE", .{ i.destination, i.source });
            },
            .ADD => |i| blk: {
                std.debug.print("ADD {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("ADD", .{ i.destination, i.a, i.b });
            },
            .SUB => |i| blk: {
                std.debug.print("SUB {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("SUB", .{ i.destination, i.a, i.b });
            },
            .MUL => |i| blk: {
                std.debug.print("MUL {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("MUL", .{ i.destination, i.a, i.b });
            },
            .DIV => |i| blk: {
                std.debug.print("DIV {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("DIV", .{ i.destination, i.a, i.b });
            },
            .EQ => |i| blk: {
                std.debug.print("EQ {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("EQ", .{ i.destination, i.a, i.b });
            },
            .LT => |i| blk: {
                std.debug.print("LT {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("LT", .{ i.destination, i.a, i.b });
            },
            .GT => |i| blk: {
                std.debug.print("GT {d} {d} {d}", .{ i.destination, i.a, i.b });
                break :blk instructionLength("GT", .{ i.destination, i.a, i.b });
            },
            .JMP => |offset| blk: {
                std.debug.print("JMP {d}", .{offset});
                break :blk instructionLength("JMP", .{offset});
            },
            .JMP_IF => |i| blk: {
                std.debug.print("JMP_IF {d} {d}", .{ i.condition, i.offset });
                break :blk instructionLength("JMP_IF", .{ i.condition, i.offset });
            },
            .MAKE_CLOSURE => |i| blk: {
                std.debug.print("MAKE_CLOSURE r{d} {d} {d}", .{ i.destination, i.addr, i.arity });
                break :blk instructionLength("MAKE_CLOSURE r", .{ i.destination, i.addr, i.arity }); // Approximate length
            },
            .CAPTURE_CLOSURE => |i| blk: {
                std.debug.print("CAPTURE_CLOSURE r{d} {any}", .{ i.closure, i.captures });
                break :blk 20;
            },
            .CALL => |i| blk: {
                std.debug.print("CALL {d} {d}", .{ i.function_reg, i.param_reg });
                break :blk instructionLength("CALL", .{ i.function_reg, i.param_reg });
            },
            .DEBUG => |reg| blk: {
                std.debug.print("DEBUG {d}", .{reg});
                break :blk instructionLength("DEBUG", .{reg});
            },
            .RETURN => |reg| blk: {
                std.debug.print("RETURN {d}", .{reg});
                break :blk instructionLength("RETURN", .{reg});
            },
            .HALT => blk: {
                std.debug.print("HALT", .{});
                break :blk 4; // "HALT"
            },
        };
    }

    fn instructionLength(comptime name: []const u8, args: anytype) usize {
        var len: usize = name.len;
        inline for (args) |arg| {
            len += 1; // space
            len += numDigits(arg);
        }
        return len;
    }

    fn numDigits(n: anytype) usize {
        const T = @TypeOf(n);
        if (@typeInfo(T) == .int) {
            if (n == 0) return 1;
            var num = if (n < 0) -n else n;
            var count: usize = if (n < 0) 1 else 0; // for negative sign
            while (num > 0) : (num = @divTrunc(num, 10)) {
                count += 1;
            }
            return count;
        }
        return 1;
    }

    fn printComment(instr: Instruction, addr: usize, constants: []const Value) void {
        switch (instr) {
            .LOADK => |i| {
                std.debug.print("r{d} <- constants[{d}] (", .{ i.register, i.const_idx });
                if (i.const_idx < constants.len) {
                    std.debug.print("{f}", .{constants[i.const_idx]});
                } else {
                    std.debug.print("invalid", .{});
                }
                std.debug.print(")", .{});
            },
            .MOVE => |i| {
                std.debug.print("r{d} <- r{d}", .{ i.destination, i.source });
            },
            .ADD => |i| {
                std.debug.print("r{d} <- r{d} + r{d}", .{ i.destination, i.a, i.b });
            },
            .SUB => |i| {
                std.debug.print("r{d} <- r{d} - r{d}", .{ i.destination, i.a, i.b });
            },
            .MUL => |i| {
                std.debug.print("r{d} <- r{d} * r{d}", .{ i.destination, i.a, i.b });
            },
            .DIV => |i| {
                std.debug.print("r{d} <- r{d} / r{d}", .{ i.destination, i.a, i.b });
            },
            .EQ => |i| {
                std.debug.print("r{d} <- r{d} == r{d}", .{ i.destination, i.a, i.b });
            },
            .LT => |i| {
                std.debug.print("r{d} <- r{d} < r{d}", .{ i.destination, i.a, i.b });
            },
            .GT => |i| {
                std.debug.print("r{d} <- r{d} > r{d}", .{ i.destination, i.a, i.b });
            },
            .JMP => |offset| {
                const target = @as(i64, @intCast(addr)) + offset + 1;
                std.debug.print("jump to {d}", .{target});
            },
            .JMP_IF => |i| {
                const target = @as(i64, @intCast(addr)) + i.offset + 1;
                std.debug.print("if r{d} == true then jump to {d}", .{ i.condition, target });
            },
            .MAKE_CLOSURE => |i| {
                std.debug.print("r{d} <- closure @{d}", .{ i.destination, i.addr });
            },
            .CAPTURE_CLOSURE => {
                // std.debug.print("", .{ });
            },
            .CALL => |i| {
                std.debug.print("call r{d} with params starting at r{d}", .{ i.function_reg, i.param_reg });
            },
            .DEBUG => |reg| {
                std.debug.print("print r{d}", .{reg});
            },
            .RETURN => |reg| {
                std.debug.print("return r{d}", .{reg});
            },
            .HALT => {
                std.debug.print("halt execution", .{});
            },
        }
    }
};

test "disassemble simple program" {
    const LoadInstruction = @import("instruction.zig").LoadInstruction;
    const ArithmeticInstruction = @import("instruction.zig").ArithmeticInstruction;

    const constants = [_]Value{ Value{ .int = 1 }, Value{ .int = 2 } };
    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .ADD = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    // Just test that it doesn't crash
    Disassembler.disassemble(&bytecode, &constants);
}

test "disassemble with jumps" {
    const LoadInstruction = @import("instruction.zig").LoadInstruction;
    const JumpIfInstruction = @import("instruction.zig").JumpIfInstruction;

    const constants = [_]Value{Value{ .bool = true }};
    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // 0
        Instruction{ .JMP_IF = JumpIfInstruction{ .condition = 0, .offset = 2 } }, // 1: jumps to 4
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 0 } }, // 2
        Instruction{ .JMP = 1 }, // 3: jumps to 5
        Instruction{ .LOADK = LoadInstruction{ .register = 2, .const_idx = 0 } }, // 4
        Instruction{ .HALT = {} }, // 5
    };

    // Just test that it doesn't crash
    Disassembler.disassemble(&bytecode, &constants);
}
