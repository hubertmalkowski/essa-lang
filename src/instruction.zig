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

    RETURN,
    HALT,
};

pub const ArithmeticInstruction = struct { destination: Register, a: Register, b: Register };
pub const ComparisonInstruction = struct { destination: Register, a: Register, b: Register };
pub const LoadInstruction = struct { register: Register, const_idx: u64 };
pub const MoveInstruction = struct { destination: Register, source: Register };

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
    RETURN: Register,
    HALT: void, // HALT has no data
    //
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

            .RETURN => |i| try writer.print("RETURN {d}", .{i}),
            .HALT => try writer.print("HALT", .{}),
        }
    }
};
