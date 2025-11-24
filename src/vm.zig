const std = @import("std");
const Value = @import("value.zig").Value;
const ValueTag = @import("value.zig").ValueTag;
const ComparisonInstruction = @import("instruction.zig").ComparisonInstruction;
const CallInstruction = @import("instruction.zig").CallInstruction;
const JumpIfInstruction = @import("instruction.zig").JumpIfInstruction;
const Instruction = @import("instruction.zig").Instruction;
const MoveInstruction = @import("instruction.zig").MoveInstruction;
const ArithmeticInstruction = @import("instruction.zig").ArithmeticInstruction;
const LoadInstruction = @import("instruction.zig").LoadInstruction;
const Register = @import("instruction.zig").Register;

const VMError = error{ TypeError, HaltExpected, DivisionError, OutOfMemory, OutOfBounds, ArityMismatch, NotAFun };

const CallFrame = struct {
    registers: [256]Value,
    result_register: Register,
    return_address: usize,

    fn init(result_register: u8, return_address: usize) CallFrame {
        return CallFrame{ .registers = [_]Value{Value{ .nil = {} }} ** 256, .result_register = result_register, .return_address = return_address };
    }

    fn set(cf: *CallFrame, register: Register, value: Value) void {
        cf.registers[register] = value;
    }

    fn get(cf: *CallFrame, register: Register) Value {
        return cf.registers[register];
    }
};

pub const Function = struct { start: usize, arity: u8 };

pub const VM = struct {
    ip: usize,
    bytecode: []const Instruction,
    constants: []const Value,
    frames: std.ArrayList(CallFrame),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, bytecode: []const Instruction, constants: []const Value) !VM {
        var frames = std.ArrayList(CallFrame).empty;
        try frames.append(allocator, CallFrame.init(0, 0));
        return VM{ .frames = frames, .ip = 0, .bytecode = bytecode, .constants = constants, .allocator = allocator };
    }

    pub fn deinit(self: *VM) void {
        self.frames.deinit(self.allocator);
    }

    pub fn run(self: *VM) VMError!void {
        var instruction = try self.fetch();

        while (instruction != .HALT) {
            // std.debug.print("{f} \n", .{instruction});
            if (instruction == .RETURN) {
                // When main function returns we need to stop the program. Returning value from the main function will be handled in the future
                if (try self.ret(instruction.RETURN)) {
                    break;
                }
            } else {
                try self.interpret(instruction);
            }

            instruction = try self.fetch();
        }

        // std.debug.print("{f} \n", .{instruction});
    }

    fn interpret(self: *VM, instruction: Instruction) VMError!void {
        return switch (instruction) {
            .LOADK => |value| self.load(value),
            .MOVE => |value| self.move(value),
            .ADD => |value| self.add(value),
            .SUB => |value| self.sub(value),
            .MUL => |value| self.mul(value),
            .DIV => |value| self.div(value),

            .GT => |value| self.gt(value),
            .EQ => |value| self.eq(value),
            .LT => |value| self.lt(value),

            .CALL => |value| self.call(value),
            .DEBUG => |value| std.debug.print("{f}\n", .{self.get_register(value)}),

            .JMP => |value| self.jump(value),
            .JMP_IF => |value| self.jump_if(value),

            else => {
                std.debug.print("NOT HANDLED INSTRUCTION {f} \n", .{instruction});
            },
        };
    }

    fn get_current_frame(self: *VM) *CallFrame {
        return &self.frames.items[self.frames.items.len - 1];
    }

    fn get_parent_frame(self: *VM) *CallFrame {
        return &self.frames.items[self.frames.items.len - 2];
    }

    fn insert_frame(self: *VM, result_register: Register, return_address: usize) VMError!void {
        const frame = CallFrame.init(result_register, return_address);
        self.frames.append(self.allocator, frame) catch return VMError.OutOfMemory;
    }

    // returns if should stop when there are no frames left
    fn pop_frame(self: *VM) bool {
        _ = self.frames.pop() orelse return true;
        return false;
    }

    fn get_register(self: *VM, register: Register) Value {
        var frame = self.get_current_frame();
        return frame.get(register);
    }

    fn set_register(self: *VM, reg: Register, val: Value) void {
        var frame = self.get_current_frame();
        return frame.set(reg, val);
    }

    fn fetch(self: *VM) VMError!Instruction {
        if (self.ip + 1 > self.bytecode.len) {
            return VMError.HaltExpected;
        }
        const bytecode = self.bytecode[self.ip];
        self.ip += 1;
        return bytecode;
    }

    fn load(self: *VM, instruction: LoadInstruction) void {
        self.set_register(instruction.register, self.constants[instruction.const_idx]);
    }

    fn move(self: *VM, instruction: MoveInstruction) void {
        self.set_register(instruction.destination, self.get_register(instruction.source));
    }

    fn add(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        // std.debug.print("{f} + {f} \n", .{ a, b });

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.set_register(instruction.destination, Value{ .int = a.int + b.int });
    }

    fn sub(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.set_register(instruction.destination, Value{ .int = a.int - b.int });
    }

    fn mul(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.set_register(instruction.destination, Value{ .int = a.int * b.int });
    }

    fn div(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        if (b.int == 0) {
            return VMError.DivisionError;
        }

        self.set_register(instruction.destination, Value{ .int = @divFloor(a.int, b.int) });
    }

    fn eq(self: *VM, instruction: ComparisonInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.set_register(instruction.destination, Value{ .bool = a.int == b.int });
    }

    fn lt(self: *VM, instruction: ComparisonInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.set_register(instruction.destination, Value{ .bool = a.int < b.int });
    }

    fn gt(self: *VM, instruction: ComparisonInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.set_register(instruction.destination, Value{ .bool = a.int > b.int });
    }

    fn jump(self: *VM, offset: i64) VMError!void {
        const ip_int: i64 = @intCast(self.ip);
        const new_ip: i64 = ip_int + offset;
        if (new_ip < 0 or new_ip > self.bytecode.len) {
            return VMError.OutOfBounds;
        }
        self.ip = @intCast(new_ip);
    }

    fn jump_if(self: *VM, instruction: JumpIfInstruction) VMError!void {
        const condition = self.get_register(instruction.condition);
        if (!condition.isBool()) {
            return VMError.TypeError;
        }
        if (condition.bool) return self.jump(instruction.offset);
    }

    fn call(self: *VM, instruction: CallInstruction) VMError!void {
        const closure = self.get_register(instruction.function_reg);
        if (!closure.isClosure()) return VMError.NotAFun;
        try self.insert_frame(0, self.ip);
        var current_frame = self.get_current_frame();
        var parent_frame = self.get_parent_frame();
        const num_of_args = closure.closure.arity;
        for (0..num_of_args) |i| {
            current_frame.set(@intCast(i), parent_frame.get(@intCast(i)));
        }
        self.ip = closure.closure.addr;
    }

    fn ret(self: *VM, register: Register) VMError!bool {
        const old_frame = self.get_current_frame();

        self.ip = old_frame.return_address;
        const return_value = old_frame.get(register);
        const shouldStop = self.pop_frame();
        if (shouldStop) return true;
        self.set_register(0, return_value);
        return false;
    }
};

test "addition works for integers" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .int = 2 } };

    const bytecode = [_]Instruction{ Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, Instruction{ .LOADK = LoadInstruction{
        .register = 1,
        .const_idx = 1,
    } }, Instruction{ .ADD = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } }, Instruction{ .HALT = {} } };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isInt());
    try std.testing.expect(vm.get_register(2).int == 3);
}

test "additions returns TypeError if addants are not integers" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .bool = false } };

    const bytecode = [_]Instruction{ Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, Instruction{ .LOADK = LoadInstruction{
        .register = 1,
        .const_idx = 1,
    } }, Instruction{ .ADD = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } }, Instruction{ .HALT = {} } };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try std.testing.expectError(VMError.TypeError, vm.run());
}

test "dividing by zero returns division error" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .int = 0 } };

    const bytecode = [_]Instruction{ Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, Instruction{ .LOADK = LoadInstruction{
        .register = 1,
        .const_idx = 1,
    } }, Instruction{ .DIV = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } }, Instruction{ .HALT = {} } };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try std.testing.expectError(VMError.DivisionError, vm.run());
}
test "EQ returns true when integers are equal" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 5 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .EQ = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isBool());
    try std.testing.expect(vm.get_register(2).bool == true);
}

test "EQ returns false when integers are not equal" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 3 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .EQ = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isBool());
    try std.testing.expectEqual(vm.get_register(2).bool, false);
}

test "LT returns true when first integer is less than second" {
    const constants = [_]Value{ Value{ .int = 3 }, Value{ .int = 5 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .LT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isBool());
    try std.testing.expect(vm.get_register(2).bool == true);
}

test "LT returns false when first integer is greater than second" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 3 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .LT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isBool());
    try std.testing.expect(vm.get_register(2).bool == false);
}

test "GT returns true when first integer is greater than second" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 3 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .GT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isBool());
    try std.testing.expect(vm.get_register(2).bool == true);
}

test "GT returns false when first integer is less than second" {
    const constants = [_]Value{ Value{ .int = 3 }, Value{ .int = 5 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .GT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(2).isBool());
    try std.testing.expect(vm.get_register(2).bool == false);
}

test "JMP jumps forward by offset" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .int = 99 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .JMP = 2 }, // skip next 2 instructions
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 1 } }, // skipped
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 1 } }, // skipped
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    // try std.testing.expect(vm.registers[0].isInt());
    // try std.testing.expect(vm.registers[0].int == 1); // should still be 1, not 99
    //

    try std.testing.expect(vm.get_register(0).isInt());
    try std.testing.expect(vm.get_register(0).int == 1);
}

test "JMP jumps backward by negative offset" {
    const constants = [_]Value{Value{ .int = 5 }};

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // 0: r0 = 5
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 0 } }, // 1: r1 = 5
        Instruction{ .SUB = ArithmeticInstruction{ .destination = 0, .a = 0, .b = 1 } }, // 2: r0 = r0 - r1 (now 0)
        Instruction{ .GT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } }, // 3: r2 = r0 > r1 (false, exit loop)
        Instruction{ .JMP_IF = JumpIfInstruction{ .offset = -3, .condition = 2 } }, // 4: if r2 jump back to instruction 2
        Instruction{ .HALT = {} }, // 5
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(0).isInt());
    try std.testing.expectEqual(vm.get_register(0).int, 0);
}

test "JMP_IF jumps when condition is true" {
    const constants = [_]Value{ Value{ .int = 10 }, Value{ .int = 99 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 10
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } }, // r1 = 99
        Instruction{ .LOADK = LoadInstruction{ .register = 2, .const_idx = 0 } }, // r2 = 10
        Instruction{ .EQ = ComparisonInstruction{ .destination = 3, .a = 0, .b = 2 } }, // r3 = (r0 == r2) = true
        Instruction{ .JMP_IF = JumpIfInstruction{ .offset = 1, .condition = 3 } }, // if true, skip next
        Instruction{ .MOVE = MoveInstruction{ .destination = 0, .source = 1 } }, // r0 = r1 (should be skipped)
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(0).isInt());
    try std.testing.expect(vm.get_register(0).int == 10);
}

test "JMP_IF does not jump when condition is false" {
    const constants = [_]Value{ Value{ .int = 10 }, Value{ .int = 99 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 10
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } }, // r1 = 99
        Instruction{ .LOADK = LoadInstruction{ .register = 2, .const_idx = 1 } }, // r2 = 99
        Instruction{ .EQ = ComparisonInstruction{ .destination = 3, .a = 0, .b = 2 } }, // r3 = (r0 == r2) = false
        Instruction{ .JMP_IF = JumpIfInstruction{ .offset = 1, .condition = 3 } }, // if true, skip next (but it's false)
        Instruction{ .MOVE = MoveInstruction{ .destination = 0, .source = 1 } }, // r0 = r1 (should execute)
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expect(vm.get_register(0).isInt());
    try std.testing.expect(vm.get_register(0).int == 99);
}

test "JMP_IF returns TypeError when condition is not boolean" {
    const constants = [_]Value{Value{ .int = 5 }};

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 5 (int, not bool)
        Instruction{ .JMP_IF = JumpIfInstruction{ .offset = 1, .condition = 0 } }, // condition is int, not bool
        Instruction{ .HALT = {} },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try std.testing.expectError(VMError.TypeError, vm.run());
}

test "call scenario: ADD function" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .closure = .{ .addr = 5, .arity = 2 } } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 5
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 0 } }, // r1 = 5
        Instruction{ .LOADK = LoadInstruction{ .register = 2, .const_idx = 1 } },
        Instruction{ .CALL = CallInstruction{ .function_reg = 2 } }, // add(5, 5)
        Instruction{ .HALT = {} },
        Instruction{ .ADD = ArithmeticInstruction{ .a = 0, .b = 1, .destination = 2 } }, // arg0 + arg1
        Instruction{ .RETURN = 2 },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();
    try std.testing.expectEqual(10, vm.get_register(0).int);
}

test "call scenario: factorial" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 1 }, Value{ .closure = .{ .addr = 5, .arity = 1 } } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 5
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 2 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 2, .const_idx = 2 } },
        Instruction{ .CALL = CallInstruction{ .function_reg = 2 } }, // call factorial
        Instruction{ .HALT = {} },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } }, // r1 = 1
        Instruction{ .GT = ComparisonInstruction{ .a = 0, .b = 1, .destination = 2 } }, // r2 = (n > 1)
        Instruction{ .JMP_IF = JumpIfInstruction{ .condition = 2, .offset = 1 } }, // if (n > 1) skip next instruction
        Instruction{ .RETURN = 1 }, // We already have 1 in register 1
        Instruction{ .SUB = ArithmeticInstruction{ .destination = 1, .a = 0, .b = 1 } }, // r1 = r0 - 1
        Instruction{ .MOVE = MoveInstruction{ .destination = 3, .source = 0 } }, // move r0 to r3,
        Instruction{ .MOVE = MoveInstruction{ .destination = 0, .source = 1 } }, // set (n - 1) as an argument
        Instruction{ .LOADK = LoadInstruction{ .register = 4, .const_idx = 2 } },
        Instruction{ .CALL = CallInstruction{ .function_reg = 4 } },
        Instruction{ .MUL = ArithmeticInstruction{ .destination = 0, .a = 0, .b = 3 } }, // r0 = factorial(n - 1) * n
        Instruction{ .RETURN = 0 },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expectEqual(120, vm.get_register(0).int);
}
