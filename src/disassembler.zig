const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const Value = @import("value.zig").Value;

pub const Disassembler = struct {
    pub fn disassemble(bytecode: []const Instruction, constants: []const Value) void {
        std.debug.print("=== Disassembly ===\n", .{});

        std.debug.print("\nConstants:\n", .{});
        for (constants, 0..) |constant, i| {
            std.debug.print("  [{d}] = {f}\n", .{ i, constant });
        }

        std.debug.print("\nBytecode:\n", .{});
        for (bytecode, 0..) |instr, addr| {
            std.debug.print("{d:0>4} ", .{addr});
            printInstruction(instr);
            std.debug.print(" ; ", .{});
            printComment(instr, addr, constants);
            std.debug.print("\n", .{});
        }
        std.debug.print("===================\n", .{});
    }

    fn printInstruction(instr: Instruction) void {
        switch (instr) {
            .LOADK => |i| std.debug.print("LOADK {d} {d}         ", .{ i.register, i.const_idx }),
            .MOVE => |i| std.debug.print("MOVE {d} {d}          ", .{ i.destination, i.source }),
            .ADD => |i| std.debug.print("ADD {d} {d} {d}        ", .{ i.destination, i.a, i.b }),
            .SUB => |i| std.debug.print("SUB {d} {d} {d}        ", .{ i.destination, i.a, i.b }),
            .MUL => |i| std.debug.print("MUL {d} {d} {d}        ", .{ i.destination, i.a, i.b }),
            .DIV => |i| std.debug.print("DIV {d} {d} {d}        ", .{ i.destination, i.a, i.b }),
            .EQ => |i| std.debug.print("EQ {d} {d} {d}          ", .{ i.destination, i.a, i.b }),
            .LT => |i| std.debug.print("LT {d} {d} {d}          ", .{ i.destination, i.a, i.b }),
            .GT => |i| std.debug.print("GT {d} {d} {d}          ", .{ i.destination, i.a, i.b }),
            .JMP => |offset| std.debug.print("JMP {d}             ", .{offset}),
            .JMP_IF => |i| std.debug.print("JMP_IF {d} {d}        ", .{ i.condition, i.offset }),
            .CALL => |i| std.debug.print("CALL {d} {d}         ", .{ i.function_addr, i.num_of_args }),
            .DEBUG => |reg| std.debug.print("DEBUG {d}           ", .{reg}),
            .RETURN => |reg| std.debug.print("RETURN {d}         ", .{reg}),
            .HALT => std.debug.print("HALT              ", .{}),
        }
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
            .CALL => |i| {
                std.debug.print("call function at {d} with {d} args", .{ i.function_addr, i.num_of_args });
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
