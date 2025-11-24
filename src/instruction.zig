const std = @import("std");

pub const Register = u8;
pub const InstructionTag = enum {
    LOADK,
    MOVE,

    // Arithmetic
    ADD,
    SUB,
    MUL,
    DIV,

    //Comparison
    EQ, // equals
    LT, // less then
    GT, // greater than
    //
    JMP,
    JMP_IF,

    CALL,

    DEBUG,

    RETURN,
    HALT,
};

pub const ArithmeticInstruction = struct { destination: Register, a: Register, b: Register }; // 4 byutes
pub const ComparisonInstruction = struct { destination: Register, a: Register, b: Register }; // 4 bytes
pub const LoadInstruction = struct { register: Register, const_idx: u64 }; // 12 bytes
pub const MoveInstruction = struct { destination: Register, source: Register }; // 4 bytes
pub const CallInstruction = struct { function_addr: Register, num_of_args: u8 }; // 12 bytes

pub const JumpIfInstruction = struct { offset: i64, condition: Register };

pub const Instruction = union(InstructionTag) {
    LOADK: LoadInstruction,
    MOVE: MoveInstruction,
    ADD: ArithmeticInstruction,
    SUB: ArithmeticInstruction,
    MUL: ArithmeticInstruction,
    DIV: ArithmeticInstruction,
    EQ: ComparisonInstruction,
    LT: ComparisonInstruction,
    GT: ComparisonInstruction,

    JMP: i64,
    JMP_IF: JumpIfInstruction,

    CALL: CallInstruction,

    DEBUG: Register, // just prints a value from register

    RETURN: Register,
    HALT: void, // HALT has no data

    pub fn format(self: Instruction, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .LOADK => |i| try writer.print("LOADK {d} {d}", .{ i.register, i.const_idx }),
            .MOVE => |i| try writer.print("MOVE {d} {d}", .{ i.destination, i.source }),

            .ADD => |i| try writer.print("ADD {d} {d} {d}", .{ i.destination, i.a, i.b }),
            .SUB => |i| try writer.print("SUB {d} {d} {d}", .{ i.destination, i.a, i.b }),
            .MUL => |i| try writer.print("MUL {d} {d} {d}", .{ i.destination, i.a, i.b }),
            .DIV => |i| try writer.print("DIV {d} {d} {d}", .{ i.destination, i.a, i.b }),

            .EQ => |i| try writer.print("EQ {d} {d} {d}", .{ i.destination, i.a, i.b }),
            .LT => |i| try writer.print("LT {d} {d} {d}", .{ i.destination, i.a, i.b }),
            .GT => |i| try writer.print("GT {d} {d} {d}", .{ i.destination, i.a, i.b }),

            .CALL => |i| try writer.print("CALL {d} {d}", .{ i.function_addr, i.num_of_args }),
            .DEBUG => |i| try writer.print("DEBUG {d}", .{i}),

            .JMP => |i| try writer.print("JMP {d}", .{i}),
            .JMP_IF => |i| try writer.print("JMP_IF {d} {d}", .{ i.condition, i.offset }),

            .RETURN => |i| try writer.print("RETURN {d}", .{i}),
            .HALT => try writer.print("HALT", .{}),
        }
    }
};
