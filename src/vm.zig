const std = @import("std");
const opcodes = @import("opcodes.zig");
const values = @import("values.zig");

pub const CallFrame = struct {
    closure: *values.Closure,
    registers: []values.Value,
    pc: usize,
    return_dest: u8,

    pub fn init(allocator: std.mem.Allocator, closure: *values.Closure, dest: u8) !CallFrame {
        const regs = try allocator.alloc(values.Value, closure.proto.registers);
        @memset(regs, values.Value.nil);

        return .{ .registers = regs, .pc = 0, .return_dest = dest, .closure = closure };
    }

    pub fn deinit(self: *CallFrame, allocator: std.mem.Allocator) void {
        allocator.free(self.registers);
    }

    pub fn getReg(self: *CallFrame, index: usize) values.Value {
        return self.registers[index];
    }

    pub fn setReg(self: *CallFrame, index: usize, val: values.Value) void {
        self.registers[index] = val;
    }

    fn getConst(self: *CallFrame, index: usize) values.Value {
        // Here constants are empty
        return self.closure.proto.constants[index];
    }

    fn getRegOrConst(self: *CallFrame, v: u8, vk: bool) values.Value {
        if (vk) {
            return self.getConst(v);
        }
        return self.getReg(v);
    }

    fn next(self: *CallFrame) ?opcodes.Instruction {
        if (self.pc >= self.closure.proto.instructions.len) {
            return null;
        }
        const i = self.closure.proto.instructions[self.pc];
        self.pc += 1;
        return i;
    }
};

pub const VM = struct {
    callFrames: std.ArrayList(CallFrame),
    cf: usize,
    rootClosure: *values.Closure,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, moduleProto: *const values.ClosureProto) !VM {
        const closure = try std.testing.allocator.create(values.Closure);
        closure.* = .{
            .object = .{ .forwarded = null },
            .proto = moduleProto,
            .upvalues = &[_]values.Value{},
        };

        var frames = std.ArrayList(CallFrame).empty;
        try frames.append(allocator, try CallFrame.init(allocator, closure, 0));

        return .{
            .callFrames = frames,
            .cf = 0,
            .rootClosure = closure,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VM) void {
        self.allocator.destroy(self.rootClosure.proto);
        self.allocator.destroy(self.rootClosure);
        for (self.callFrames.items) |*item| {
            item.deinit(self.allocator);
        }
        self.callFrames.deinit(self.allocator);
    }

    fn run(self: *VM) !void {
        while (self.currentFrame().next()) |i| {
            try self.interpret(i);
        }
    }

    fn interpret(self: *VM, i: opcodes.Instruction) !void {
        // std.debug.print("{}\n", .{i.getTag()});
        return switch (i.getTag()) {
            .MOVE => self.move(i.abc),
            .LOADK => self.loadk(i.abx),
            .JMP => self.jmp(i.asbx),
            .ADD => self.add(i.abc),
            .SUB => self.sub(i.abc),
            .MUL => self.mul(i.abc),
            .DIV => self.div(i.abc),
            .UNM => self.unm(i.abc),
            .NOT => self.not(i.abc),
            .EQ => self.eq(i.abc),
            .LT => self.lt(i.abc),
            .LE => self.le(i.abc),
            .TEST => self.tst(i.abc),
            .ISNIL => self.isnil(i.abc),
            else => error.Unknown,
        };
    }

    fn move(self: *VM, i: opcodes.ABC) void {
        self.currentFrame().setReg(i.a, self.currentFrame().getReg(i.b));
    }

    fn loadk(self: *VM, i: opcodes.ABx) !void {
        self.currentFrame().setReg(i.a, self.currentFrame().getConst(i.bx));
    }

    fn jmp(self: *VM, i: opcodes.AsBx) !void {
        const frame = self.currentFrame();

        // 1. Cast current PC to isize so we can do signed arithmetic
        // 2. Add the signed offset (sbx will be widened automatically to isize)
        const newPc = @as(isize, @intCast(frame.pc)) + i.sbx - 1;

        // 3. Cast back to usize (and handle potential negative results if necessary)
        frame.pc = @intCast(newPc);
    }

    fn add(self: *VM, i: opcodes.ABC) !void {
        return self.binaryOp(i, struct {
            fn func(a: anytype, b: anytype) @TypeOf(a + b) {
                return a + b;
            }
        }.func);
    }

    fn sub(self: *VM, i: opcodes.ABC) !void {
        return self.binaryOp(i, struct {
            fn func(a: anytype, b: anytype) @TypeOf(a - b) {
                return a - b;
            }
        }.func);
    }

    fn mul(self: *VM, i: opcodes.ABC) !void {
        return self.binaryOp(i, struct {
            fn func(a: anytype, b: anytype) @TypeOf(a * b) {
                return a * b;
            }
        }.func);
    }

    fn div(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getRegOrConst(i.b, i.bk);
        const cval = frame.getRegOrConst(i.c, i.ck);

        if (!bval.isNumeric() or !cval.isNumeric()) return error.InvalidType;

        const left = bval.asFloat();
        const right = cval.asFloat();

        frame.setReg(i.a, values.Value{ .float = left / right });
    }

    fn unm(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getReg(i.b);
        if (!bval.isNumeric()) return error.InvalidType;

        if (bval.isInt()) {
            frame.setReg(i.a, .{ .integer = -bval.integer });
        } else {
            frame.setReg(i.a, .{ .float = -bval.float });
        }
    }

    fn not(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getReg(i.b);

        if (bval.isBool()) {
            frame.setReg(i.a, .{ .bool = !bval.bool });
        } else {
            return error.TypeError;
        }
    }

    fn eq(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getRegOrConst(i.b, i.bk);
        const cval = frame.getRegOrConst(i.c, i.ck);

        if (cval.isBool() and bval.isBool()) {
            frame.setReg(i.a, .{ .bool = bval.bool == cval.bool });
        } else if (cval.isInt() and bval.isInt()) {
            frame.setReg(i.a, .{ .bool = cval.integer == bval.integer });
        } else if (cval.isNumeric() and bval.isNumeric()) {
            frame.setReg(i.a, .{ .bool = cval.asFloat() == bval.asFloat() });
        } else if (bval.isTuple() and cval.isTuple()) {
            frame.setReg(i.a, .{ .bool = cval.tuple == bval.tuple });
        } else if (bval.isNil() and cval.isNil()) {
            frame.setReg(i.a, .{ .bool = true });
        } else {
            frame.setReg(i.a, .{ .bool = false });
        }
    }

    fn lt(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getRegOrConst(i.b, i.bk);
        const cval = frame.getRegOrConst(i.c, i.ck);
        if (bval.isNumeric() and cval.isNumeric()) {
            frame.setReg(i.a, .{ .bool = cval.asFloat() > bval.asFloat() });
        } else {
            return error.TypeError;
        }
    }

    fn le(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getRegOrConst(i.b, i.bk);
        const cval = frame.getRegOrConst(i.c, i.ck);
        if (bval.isNumeric() and cval.isNumeric()) {
            frame.setReg(i.a, .{ .bool = cval.asFloat() >= bval.asFloat() });
        } else {
            return error.TypeError;
        }
    }

    // test (zig doesn't allo "test" as function name)
    fn tst(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const aval = frame.getReg(i.a);
        if (aval.isBool() and aval.bool) {
            frame.pc += 1;
        }
    }

    fn isnil(self: *VM, i: opcodes.ABC) !void {
        const frame = self.currentFrame();
        const bval = frame.getReg(i.b);
        frame.setReg(i.a, .{ .bool = bval.isNil() });
    }

    fn currentFrame(self: *VM) *CallFrame {
        return &self.callFrames.items[self.cf];
    }

    inline fn binaryOp(self: *VM, i: opcodes.ABC, comptime op: anytype) !void {
        const frame = self.currentFrame();
        const bval = frame.getRegOrConst(i.b, i.bk);
        const cval = frame.getRegOrConst(i.c, i.ck);

        if (!(bval.isNumeric() and cval.isNumeric())) {
            return error.TypeError;
        }

        if (bval.isFloat() or cval.isFloat()) {
            const res = op(bval.asFloat(), cval.asFloat());
            frame.setReg(i.a, values.Value{ .float = res });
        } else {
            const res = op(bval.integer, cval.integer);
            frame.setReg(i.a, values.Value{ .integer = res });
        }
    }

    fn popFrame(self: *VM) *CallFrame {
        return self.callFrames.pop();
    }
};

test "LOADK loads a constant to register" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .bool = true })
        .addConst(.{ .integer = 2 })
        .loadk(0, 0)
        .loadk(1, 0)
        .loadk(2, 1)
        .build(3);
    defer vm.deinit();

    try vm.run();

    try std.testing.expectEqual(true, vm.callFrames.items[0].registers[0].bool);
    try std.testing.expectEqual(true, vm.callFrames.items[0].registers[1].bool);
    try std.testing.expectEqual(2, vm.callFrames.items[0].registers[2].integer);
}

test "MOVE moves values between registers" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .bool = true })
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .loadk(0, 0)
        .loadk(1, 1)
        .loadk(2, 2)
        .move(0, 2, 0, false, false) // r0 <- r2
        .move(2, 1, 0, false, false) // r2 <- r1
        .move(1, 0, 0, false, false) // r1 <- r0
        .build(3);

    defer vm.deinit();
    try vm.run();

    try std.testing.expectEqual(2, vm.callFrames.items[0].registers[0].integer);
    try std.testing.expectEqual(2, vm.callFrames.items[0].registers[1].integer);
    try std.testing.expectEqual(5, vm.callFrames.items[0].registers[2].integer);
}

test "JMP changes the PC" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .bool = true })
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .loadk(0, 0) // 0 - bytecode start
        .loadk(1, 1)
        .loadk(2, 2)
        .jmp(3) // jumps thrice
        .move(0, 2, 0, false, false) // r0 <- r2
        .move(2, 1, 0, false, false) // r2 <- r1
        .move(1, 0, 0, false, false) // r1 <- r0 // jump here
        .build(3);

    defer vm.deinit();
    try vm.run();

    try std.testing.expectEqual(true, vm.callFrames.items[0].registers[1].bool);
}

test "JMP handles jumpbacks" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .bool = true })
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .loadk(0, 0) // 0 - bytecode start
        .jmp(2) // skip next
        .jmp(6) // jump to the last
        .loadk(1, 1)
        .loadk(2, 2)
        .jmp(-3) // jump back to the .jmp(0, 6)
        .move(0, 2, 0, false, false) // r0 <- r2
        .move(2, 1, 0, false, false) // r2 <- r1
        .move(1, 0, 0, false, false) // r1 <- r0 // jump here
        .build(3);

    defer vm.deinit();
    try vm.run();

    try std.testing.expectEqual(true, vm.callFrames.items[0].registers[1].bool);
}

test "ADD adds 2 registers" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .loadk(0, 0) // 0 - bytecode start
        .loadk(1, 1)
        .add(2, 1, 0, false, false)
        .build(3);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(7, vm.callFrames.items[0].registers[2].integer);
}

test "ADD adds a register to a constant" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .loadk(0, 0)
        .add(1, 0, 1, false, true)
        .build(2);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(7, vm.callFrames.items[0].registers[1].integer);
}

test "ADD adds 2 constants" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .add(0, 0, 1, true, true)
        .build(2);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(7, vm.callFrames.items[0].registers[0].integer);
}

test "ADD returns float if one of numbers is float" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .float = 2.3 })
        .add(0, 0, 1, true, true)
        .build(2);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(7.3, vm.callFrames.items[0].registers[0].float);
}

test "ADD throws if value is not int" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .bool = true })
        .add(0, 0, 1, true, true)
        .build(2);

    defer vm.deinit();
    try std.testing.expectError(error.TypeError, vm.run());
}

test "SUB substracts 2 numbers" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .sub(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(3, vm.callFrames.items[0].registers[0].integer);
}

test "SUB substracts 2 numbers with negative numbers" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .sub(0, 1, 0, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(-3, vm.callFrames.items[0].registers[0].integer);
}

test "MUL multiplies 2 numbers" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 5 })
        .addConst(.{ .integer = 2 })
        .mul(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(10, vm.callFrames.items[0].registers[0].integer);
}

test "MUL multiplies 2 floats" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .float = 5.4 })
        .addConst(.{ .float = 2.213 })
        .mul(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(11.9502, vm.callFrames.items[0].registers[0].float);
}

test "DIV divides 2 ints and returns floats" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 6 })
        .addConst(.{ .integer = 3 })
        .div(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(2, vm.callFrames.items[0].registers[0].float);
}

test "DIV divides int with a float and returns floats" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 7 })
        .addConst(.{ .float = 3.5 })
        .div(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(2, vm.callFrames.items[0].registers[0].float);
}

test "DIV dividies something by 0 and returns inf/-inf" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 7 })
        .addConst(.{ .float = 0 })
        .div(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(std.math.inf(f64), vm.callFrames.items[0].registers[0].float);
}

test "DIV dividies 0 by 0 and returns NaN" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 0 })
        .addConst(.{ .float = 0 })
        .div(0, 0, 1, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    //     what to put here?
    try std.testing.expect(std.math.isNan(vm.callFrames.items[0].registers[0].float));
}

test "UNM negates int" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 1 })
        .loadk(0, 0)
        .unm(0, 0)
        .build(1);

    defer vm.deinit();

    try vm.run();
    //     what to put here?
    try std.testing.expectEqual(-1, vm.currentFrame().registers[0].integer);
}

test "UNM negates float" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .float = 1 })
        .loadk(0, 0)
        .unm(0, 0)
        .build(1);

    defer vm.deinit();

    try vm.run();
    //     what to put here?
    try std.testing.expectEqual(-1, vm.currentFrame().registers[0].float);
}

test "UNM negates negative float" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .float = -1 })
        .loadk(0, 0)
        .unm(0, 0)
        .build(1);

    defer vm.deinit();

    try vm.run();
    //     what to put here?
    try std.testing.expectEqual(1, vm.currentFrame().registers[0].float);
}

test "UNM negates negative int " {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = -1 })
        .loadk(0, 0)
        .unm(0, 0)
        .build(1);

    defer vm.deinit();

    try vm.run();
    //     what to put here?
    try std.testing.expectEqual(1, vm.currentFrame().registers[0].integer);
}

test "UNM negates zero" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 0 })
        .loadk(0, 0)
        .unm(0, 0)
        .build(1);

    defer vm.deinit();

    try vm.run();
    //     what to put here?
    try std.testing.expectEqual(0, vm.currentFrame().registers[0].integer);
}

test "NOT negates booleans" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .bool = true })
        .addConst(.{ .bool = false })
        .loadk(0, 0)
        .loadk(1, 1)
        .not(0, 0) // r0 = !r0
        .not(1, 1)
        .build(2); // r1 = !r1

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(false, vm.currentFrame().registers[0].bool);
    try std.testing.expectEqual(true, vm.currentFrame().registers[1].bool);
}

test "NOT results in type error if not logic value" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 0 })
        .loadk(0, 0)
        .not(0, 0) // r0 = !r0
        .build(1);
    defer vm.deinit();
    try std.testing.expectError(error.TypeError, vm.run());
}

test "EQ compares 2 bools" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .bool = true })
        .addConst(.{ .bool = false })
        .eq(0, 1, 0, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(false, vm.currentFrame().registers[0].bool);
}

test "EQ compares 2 integers" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .integer = 2 })
        .eq(0, 0, 0, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(true, vm.currentFrame().registers[0].bool);
}

test "EQ compares 2 floats" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .float = 2.23 })
        .addConst(.{ .float = 2.23 })
        .eq(0, 0, 0, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(true, vm.currentFrame().registers[0].bool);
}

test "EQ compares float with int" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();
    var vm = try bytecode
        .addConst(.{ .float = 115 })
        .addConst(.{ .integer = 115 })
        .eq(0, 0, 0, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(true, vm.currentFrame().registers[0].bool);
}

test "EQ compares 2 nils" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .nil = {} })
        .eq(0, 0, 0, true, true)
        .build(1);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(true, vm.currentFrame().registers[0].bool);
}

test "EQ compares 2 different types" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .nil = {} })
        .addConst(.{ .float = 2.32 })
        .addConst(.{ .integer = 3 })
        .addConst(.{ .bool = true })
        .eq(0, 0, 1, true, true)
        .eq(1, 0, 2, true, true)
        .eq(2, 0, 3, true, true)
        .eq(3, 1, 2, true, true)
        .eq(4, 1, 3, true, true)
        .eq(5, 2, 3, true, true)
        .build(6);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(false, vm.currentFrame().registers[0].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[1].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[2].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[3].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[4].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[5].bool);
}

test "LT checks if number is less then other number" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .integer = 2 })
        .addConst(.{ .float = 2.32 })
        .addConst(.{ .float = 3 })
        .addConst(.{ .integer = 3 })
        .lt(0, 0, 1, true, true)
        .lt(1, 0, 2, true, true)
        .lt(2, 2, 3, true, true)
        .lt(3, 2, 1, true, true)
        .build(4);

    defer vm.deinit();
    try vm.run();
    try std.testing.expectEqual(true, vm.currentFrame().registers[0].bool);
    try std.testing.expectEqual(true, vm.currentFrame().registers[1].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[2].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[3].bool);
}

test "LE checks if number is less or equal then other number" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    var vm = try bytecode
        .addConst(.{ .integer = 2 })
        .addConst(.{ .float = 2.32 })
        .addConst(.{ .float = 3 })
        .addConst(.{ .integer = 3 })
        .le(0, 0, 1, true, true)
        .le(1, 0, 2, true, true)
        .le(2, 2, 3, true, true)
        .le(3, 2, 1, true, true)
        .build(4);

    defer vm.deinit();
    try vm.run();
    try std.testing.expectEqual(true, vm.currentFrame().registers[0].bool);
    try std.testing.expectEqual(true, vm.currentFrame().registers[1].bool);
    try std.testing.expectEqual(true, vm.currentFrame().registers[2].bool);
    try std.testing.expectEqual(false, vm.currentFrame().registers[3].bool);
}

test "TEST checks if item is true and skips next instruction" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    // simple If else case. We put the lower number to the register
    var vm = try bytecode
        .addConst(.{ .integer = 2 })
        .addConst(.{ .float = 2.32 })
        .le(0, 0, 1, true, true)
        .testt(0) // if r0 == true then go to .loadk(0, 0)
        .jmp(3) // if false ski the .loadk(0, 0)
        .loadk(0, 0)
        .jmp(2)
        .loadk(0, 1)
        .build(4);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(2, vm.currentFrame().registers[0].integer);
}

test "ISNIL checks if item is nil" {
    var bytecode = TestBytecodeBuilder.init(std.testing.allocator);
    defer bytecode.deinit();

    // simple If else case. We put the lower number to the register
    var vm = try bytecode
        .addConst(.{ .integer = 2 })
        .addConst(.{ .nil = {} })
        .loadk(0, 0)
        .loadk(1, 1)
        .isnil(0, 0)
        .isnil(1, 1)
        .build(2);

    defer vm.deinit();

    try vm.run();
    try std.testing.expectEqual(false, vm.currentFrame().registers[0].bool);
    try std.testing.expectEqual(true, vm.currentFrame().registers[1].bool);
}

// @TODO more tests
// A little helper to build bytecode
// Look at the vm tests to see the usage
pub const TestBytecodeBuilder = struct {
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(opcodes.Instruction),
    constants: std.ArrayList(values.Value),
    proto: ?*values.ClosureProto,

    pub fn init(allocator: std.mem.Allocator) TestBytecodeBuilder {
        return .{
            .allocator = allocator,
            .instructions = std.ArrayList(opcodes.Instruction).empty,
            .constants = std.ArrayList(values.Value).empty,
            .proto = null,
        };
    }

    pub fn deinit(self: *TestBytecodeBuilder) void {
        // if (self.proto) |*proto| {
        //     self.allocator.destroy(proto);
        // }
        self.instructions.deinit(self.allocator);
        self.constants.deinit(self.allocator);
    }

    pub fn build(self: *TestBytecodeBuilder, regs: u8) !VM {
        const proto = try std.testing.allocator.create(values.ClosureProto);
        const upvalues = [_]values.ClosureUpvalueDescription{};
        proto.* = .{
            .instructions = self.instructions.items,
            .constants = self.constants.items,
            .upvalue_info = &upvalues,
            .registers = regs,
            .arity = 0,
        };
        self.proto = proto;

        return VM.init(self.allocator, proto);
    }

    pub fn addConst(self: *TestBytecodeBuilder, val: values.Value) *TestBytecodeBuilder {
        self.constants.append(self.allocator, val) catch {
            std.debug.panic("Can't grow constants", .{});
        };
        return self;
    }

    pub fn loadk(self: *TestBytecodeBuilder, reg: u8, const_idx: u16) *TestBytecodeBuilder {
        self.appendInstr(.{ .abx = .{ .tag = opcodes.OpCode.LOADK.toU6(), .a = reg, .bx = const_idx } });
        return self;
    }

    pub fn move(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.MOVE.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn jmp(self: *TestBytecodeBuilder, pc_delta: i16) *TestBytecodeBuilder {
        self.appendInstr(.{ .asbx = .{ .tag = opcodes.OpCode.JMP.toU6(), .a = 0, .sbx = pc_delta } });
        return self;
    }

    pub fn add(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.ADD.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn sub(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.SUB.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn mul(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.MUL.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn div(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.DIV.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn unm(self: *TestBytecodeBuilder, to: u8, from: u8) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.UNM.toU6(), .a = to, .b = from, .c = 0, .bk = false, .ck = false } });
        return self;
    }

    pub fn not(self: *TestBytecodeBuilder, to: u8, from: u8) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.NOT.toU6(), .a = to, .b = from, .c = 0, .bk = false, .ck = false } });
        return self;
    }

    pub fn eq(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.EQ.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn lt(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.LT.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn le(self: *TestBytecodeBuilder, a: u8, b: u8, c: u8, bk: bool, ck: bool) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.LE.toU6(), .a = a, .b = b, .c = c, .bk = bk, .ck = ck } });
        return self;
    }

    pub fn testt(self: *TestBytecodeBuilder, a: u8) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.TEST.toU6(), .a = a, .b = 0, .c = 0, .bk = false, .ck = false } });
        return self;
    }

    pub fn isnil(self: *TestBytecodeBuilder, a: u8, b: u8) *TestBytecodeBuilder {
        self.appendInstr(.{ .abc = .{ .tag = opcodes.OpCode.ISNIL.toU6(), .a = a, .b = b, .c = 0, .bk = false, .ck = false } });
        return self;
    }

    fn appendInstr(self: *TestBytecodeBuilder, i: opcodes.Instruction) void {
        self.instructions.append(self.allocator, i) catch {
            std.debug.panic("Can't grow instructions array anymore ", .{});
        };
    }
};
