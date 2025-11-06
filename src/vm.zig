const std = @import("std");
const Value = @import("value.zig").Value;
const ValueTag = @import("value.zig").ValueTag;
const ComparisonInstruction = @import("instruction.zig").ComparisonInstruction;
const Instruction = @import("instruction.zig").Instruction;
const MoveInstruction = @import("instruction.zig").MoveInstruction;
const ArithmeticInstruction = @import("instruction.zig").ArithmeticInstruction;
const LoadInstruction = @import("instruction.zig").LoadInstruction;
const Register = @import("instruction.zig").Register;

const VMError = error{ TypeError, HaltExpected, DivisionError };

const VM = struct {
    registers: [256]Value,
    ip: usize,
    bytecode: []const Instruction,
    constants: []const Value,

    pub fn init(bytecode: []const Instruction, constants: []const Value) VM {
        return VM{ .registers = [_]Value{Value{ .nil = {} }} ** 256, .ip = 0, .bytecode = bytecode, .constants = constants };
    }

    pub fn run(self: *VM) VMError!void {
        var instruction = try self.fetch();

        while (instruction != .HALT and instruction != .RETURN) {
            std.debug.print("{f} \n", .{instruction});
            try self.interpret(instruction);
            instruction = try self.fetch();
        }
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

            else => {},
        };
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
        self.registers[instruction.register] = self.constants[instruction.const_idx];
    }

    fn move(self: *VM, instruction: MoveInstruction) void {
        self.registers[instruction.destination] = self.registers[instruction.source];
    }

    fn add(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.registers[instruction.destination] = Value{ .int = a.int + b.int };
    }

    fn sub(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.registers[instruction.destination] = Value{ .int = a.int - b.int };
    }

    fn mul(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.registers[instruction.destination] = Value{ .int = a.int * b.int };
    }

    fn div(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        if (b.int == 0) {
            return VMError.DivisionError;
        }

        self.registers[instruction.destination] = Value{ .int = @divFloor(a.int, b.int) };
    }

    fn eq(self: *VM, instruction: ComparisonInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.registers[instruction.destination] = Value{ .bool = a.int == b.int };
    }

    fn lt(self: *VM, instruction: ComparisonInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.registers[instruction.destination] = Value{ .bool = a.int < b.int };
    }

    fn gt(self: *VM, instruction: ComparisonInstruction) VMError!void {
        const a = self.registers[instruction.a];
        const b = self.registers[instruction.b];

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        self.registers[instruction.destination] = Value{ .bool = a.int > b.int };
    }
};

test "addition works for integers" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .int = 2 } };

    const bytecode = [_]Instruction{ Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, Instruction{ .LOADK = LoadInstruction{
        .register = 1,
        .const_idx = 1,
    } }, Instruction{ .ADD = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } }, Instruction{ .HALT = {} } };

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isInt());
    try std.testing.expect(vm.registers[2].int == 3);
}

test "additions returns TypeError if addants are not integers" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .bool = false } };

    const bytecode = [_]Instruction{ Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, Instruction{ .LOADK = LoadInstruction{
        .register = 1,
        .const_idx = 1,
    } }, Instruction{ .ADD = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } }, Instruction{ .HALT = {} } };

    var vm = VM.init(&bytecode, &constants);
    try std.testing.expectError(VMError.TypeError, vm.run());
}

test "dividing by zero returns division error" {
    const constants = [_]Value{ Value{ .int = 1 }, Value{ .int = 0 } };

    const bytecode = [_]Instruction{ Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, Instruction{ .LOADK = LoadInstruction{
        .register = 1,
        .const_idx = 1,
    } }, Instruction{ .DIV = ArithmeticInstruction{ .destination = 2, .a = 0, .b = 1 } }, Instruction{ .HALT = {} } };

    var vm = VM.init(&bytecode, &constants);
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

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isBool());
    try std.testing.expect(vm.registers[2].bool == true);
}

test "EQ returns false when integers are not equal" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 3 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .EQ = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isBool());
    try std.testing.expect(vm.registers[2].bool == false);
}

test "LT returns true when first integer is less than second" {
    const constants = [_]Value{ Value{ .int = 3 }, Value{ .int = 5 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .LT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isBool());
    try std.testing.expect(vm.registers[2].bool == true);
}

test "LT returns false when first integer is greater than second" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 3 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .LT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isBool());
    try std.testing.expect(vm.registers[2].bool == false);
}

test "GT returns true when first integer is greater than second" {
    const constants = [_]Value{ Value{ .int = 5 }, Value{ .int = 3 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .GT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isBool());
    try std.testing.expect(vm.registers[2].bool == true);
}

test "GT returns false when first integer is less than second" {
    const constants = [_]Value{ Value{ .int = 3 }, Value{ .int = 5 } };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } },
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .GT = ComparisonInstruction{ .destination = 2, .a = 0, .b = 1 } },
        Instruction{ .HALT = {} },
    };

    var vm = VM.init(&bytecode, &constants);
    try vm.run();

    try std.testing.expect(vm.registers[2].isBool());
    try std.testing.expect(vm.registers[2].bool == false);
}
