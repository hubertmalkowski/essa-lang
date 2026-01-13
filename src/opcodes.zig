const std = @import("std");

pub const ABC = packed struct(u32) {
    tag: u6, //
    a: u8, // register
    b: u8, // register or constant index
    c: u8, // register or constant index
    bk: bool, // True if b is constant
    ck: bool, // True if c is constant
};

pub const ABx = packed struct(u32) {
    tag: u6,
    a: u8, // register
    bx: u18, // unsigned index
};

pub const AsBx = packed struct(u32) {
    tag: u6,
    a: u8,
    sbx: i18, // signed index
};

// If you want to see better documentation of opcodes, go to notes/bytecode.md
// Here you can see which memory layout does each instruction use
// Look at tests to see how instructions are parsed
pub const OpCode = enum(u6) {
    MOVE, //  ABC
    LOADK, // ABx
    JMP, // AsBx

    // Math
    ADD, // ABC
    SUB, // ABC
    MUL, // ABC
    DIV, // ABC
    POW, // ABC
    UNM, // ABC

    // Logic
    NOT, // ABC
    EQ, // ABC
    LT, // ABC
    LE, // ABC
    TEST, // ABC
    ISNIL, // ABC

    // Functions
    CLOSURE, // ABx
    UPVALUE, // ABx
    RETURN, // ABC
    CALL, //  ABC
    TAILCALL, // ABC

    // Objects
    TUPLE, // ABC
    SETTUPLE, // ABC
    GETTUPLE, // ABC
    GETTAG, // ABC

    LIST, // ABC
    HEAD, // ABC
    TAIL, // ABC
    //
    pub inline fn toU6(self: OpCode) u6 {
        return @intFromEnum(self);
    }
};

pub const Instruction = extern union {
    raw: u32,
    abc: ABC,
    abx: ABx,
    asbx: AsBx,

    pub inline fn getTag(self: Instruction) OpCode {
        return @enumFromInt(self.abc.tag);
    }

    pub inline fn fromU32(code: u32) Instruction {
        return @bitCast(code);
    }
};

test "makes abc instruction from u32" {
    // First 2 bits is `ck` and `bk`
    //                      C        B        A        TAG
    const code: u32 = 0b1_0_00000001_00000011_00000100_000000;
    const op = Instruction.fromU32(code);
    try std.testing.expectEqual(OpCode.MOVE, op.getTag());
    try std.testing.expectEqual(4, op.abc.a);
    try std.testing.expectEqual(3, op.abc.b);
    try std.testing.expectEqual(1, op.abc.c);
    try std.testing.expectEqual(false, op.abc.bk);
    try std.testing.expectEqual(true, op.abc.ck);
}

test "makes ABx from u32" {
    //                  Bx                 A        TAG
    const code: u32 = 0b000000000000000011_00000110_000001;
    const op = Instruction.fromU32(code);
    try std.testing.expectEqual(OpCode.LOADK, op.getTag());
    try std.testing.expectEqual(6, op.abx.a);
    try std.testing.expectEqual(3, op.abx.bx);
}

test "makes AsBx from u32" {
    //                  sBx                A        TAG
    const code: u32 = 0b111111111111111101_00000110_000010;
    const op = Instruction.fromU32(code);
    try std.testing.expectEqual(OpCode.JMP, op.getTag());
    try std.testing.expectEqual(6, op.asbx.a);
    try std.testing.expectEqual(-3, op.asbx.sbx);
}

test "Additional test in dec (just for fun)" {
    const code: u32 = 4294918530;
    const op = Instruction.fromU32(code);
    try std.testing.expectEqual(OpCode.JMP, op.getTag());
    try std.testing.expectEqual(6, op.asbx.a);
    try std.testing.expectEqual(-3, op.asbx.sbx);
}
