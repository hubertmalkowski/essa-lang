const std = @import("std");
const Value = @import("value.zig").Value;
const CaptureClosureInstruction = @import("instruction.zig").CaptureClosureInstruction;
const ObjectType = @import("value.zig").ObjectType;
const Closure = @import("value.zig").Closure;
const ValueTag = @import("value.zig").ValueTag;
const ComparisonInstruction = @import("instruction.zig").ComparisonInstruction;
const CallInstruction = @import("instruction.zig").CallInstruction;
const JumpIfInstruction = @import("instruction.zig").JumpIfInstruction;
const Instruction = @import("instruction.zig").Instruction;
const MoveInstruction = @import("instruction.zig").MoveInstruction;
const ArithmeticInstruction = @import("instruction.zig").ArithmeticInstruction;
const LoadInstruction = @import("instruction.zig").LoadInstruction;
const Register = @import("instruction.zig").Register;
const MakeClosureInstruction = @import("instruction.zig").MakeClosureInstruction;
const gc = @import("gc.zig");

const VMError = error{ TypeError, HaltExpected, DivisionError, OutOfMemory, OutOfBounds, ArityMismatch, NotAFun };

pub const CallFrame = struct {
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

    pub fn format(
        self: CallFrame,
        writer: *std.io.Writer,
    ) std.io.Writer.Error!void {
        try writer.print("CallFrame{{ result_reg=r{d}, return_addr={d}, registers=[", .{ self.result_register, self.return_address });
        for (self.registers, 0..) |reg, i| {
            if (reg != .nil) {
                try writer.print("r{d}={f} ", .{ i, reg });
            }
        }
        try writer.writeAll("] }");
    }
};

pub const Function = struct { start: usize, arity: u8 };

pub const VM = struct {
    ip: usize,
    bytecode: []const Instruction,
    constants: []const Value,
    frames: std.ArrayList(CallFrame),
    allocator: std.mem.Allocator,
    gc: gc.GCSweep,
    errorMessage: ?[]const u8 = null,
    error_ip: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, bytecode: []const Instruction, constants: []const Value) !VM {
        var frames = std.ArrayList(CallFrame).empty;
        try frames.append(allocator, CallFrame.init(0, 0));
        return VM{
            .frames = frames,
            .ip = 0,
            .bytecode = bytecode,
            .constants = constants,
            .allocator = allocator,
            .gc = gc.GCSweep.init(),
        };
    }

    pub fn deinit(self: *VM) void {
        self.gc.sweep(self.allocator);
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

        // std.debug.print("{any} \n", .{instruction});
    }

    fn interpret(self: *VM, instruction: Instruction) VMError!void {
        return switch (instruction) {
            .LOADK => |value| self.load(value),
            .MOVE => |value| self.move(value),
            .ADD => |value| self.add(value),
            .SUB => |value| self.sub(value),
            .MUL => |value| self.mul(value),
            .DIV => |value| self.div(value),
            .MOD => |value| self.mod(value),

            .GT => |value| self.gt(value),
            .EQ => |value| self.eq(value),
            .LT => |value| self.lt(value),

            .MAKE_CLOSURE => |value| self.make_closure(value),
            .CAPTURE_CLOSURE => |value| self.capture_closure(value),
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
            return self.typeError("ADD expects integers, got {f} and {f}", .{ a, b });
        }

        self.set_register(instruction.destination, Value{ .int = a.int + b.int });
    }

    fn sub(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return self.typeError("SUB expects integers, got {f} and {f}", .{ a, b });
        }

        self.set_register(instruction.destination, Value{ .int = a.int - b.int });
    }

    fn mul(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return self.typeError("MUL expects integers, got {f} and {f}", .{ a, b });
        }

        self.set_register(instruction.destination, Value{ .int = a.int * b.int });
    }

    fn div(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return self.typeError("MUL expects integers, got {f} and {f}", .{ a, b });
        }

        if (b.int == 0) {
            return VMError.DivisionError;
        }

        self.set_register(instruction.destination, Value{ .int = @divFloor(a.int, b.int) });
    }

    fn mod(self: *VM, instruction: ArithmeticInstruction) VMError!void {
        const a = self.get_register(instruction.a);
        const b = self.get_register(instruction.b);

        if (!a.isDigit() or !b.isDigit()) {
            return VMError.TypeError;
        }

        if (b.int == 0) {
            return VMError.DivisionError;
        }

        self.set_register(instruction.destination, Value{ .int = @mod(a.int, b.int) });
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

    // When function is called - we take function value and:
    // Insert new call frame
    // Copy all n captures to r0..n registers
    // Copy all m parameters to n..m registers
    // Jump to the function bytecode
    // Return the result of function call to r0
    fn call(self: *VM, instruction: CallInstruction) VMError!void {
        const closure = self.get_register(instruction.function_reg);
        if (!closure.isClosure()) return VMError.NotAFun;
        try self.insert_frame(0, self.ip);
        var current_frame = self.get_current_frame();
        var parent_frame = self.get_parent_frame();
        const num_of_args = closure.closure.arity;
        for (closure.closure.captures, 0..) |capture, i| {
            current_frame.set(@intCast(i), capture);
        }
        const num_of_captures = closure.closure.captures.len;
        for (0..num_of_args) |i| {
            current_frame.set(@intCast(i + num_of_captures), parent_frame.get(@as(u8, @intCast(i)) + instruction.param_reg));
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

    fn make_closure(self: *VM, instruction: MakeClosureInstruction) VMError!void {
        const closure = try self.gc.allocObject(self.allocator, self.frames.items, Closure);
        closure.*.object.type = ObjectType.closure;
        closure.*.addr = instruction.addr;
        closure.*.arity = instruction.arity;
        closure.*.captures = &[_]Value{};
        self.set_register(instruction.destination, Value{ .closure = closure });
    }

    fn capture_closure(self: *VM, instruction: CaptureClosureInstruction) VMError!void {
        const reg = self.get_register(instruction.closure);
        if (!reg.isClosure()) {
            return VMError.TypeError;
        }

        var captures = std.ArrayList(Value).empty;
        for (instruction.captures) |captureReg| {
            const value = self.get_register(captureReg);
            try captures.append(self.allocator, value);
        }
        reg.closure.*.captures = try captures.toOwnedSlice(self.allocator);
    }

    fn typeError(self: *VM, comptime message: []const u8, args: anytype) VMError {
        self.setError(message, args);
        return VMError.TypeError;
    }

    fn setError(self: *VM, comptime fmt: []const u8, args: anytype) void {
        // Free previous error message if it exists
        if (self.errorMessage) |msg| {
            self.allocator.free(msg);
        }

        // Allocate and format the new error message
        self.errorMessage = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            // Fallback if allocation fails
            self.errorMessage = null;
            return;
        };

        self.error_ip = self.ip;
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
    const constants = [_]Value{Value{ .int = 5 }};

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 5
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 0 } }, // r1 = 5
        Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .arity = 2, .addr = 5 } }, // r0 = Function(arity:2) addr = 5
        Instruction{ .CALL = CallInstruction{ .function_reg = 2, .param_reg = 0 } }, // add(5, 5)
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
    const constants = [_]Value{
        Value{ .int = 5 },
        Value{ .int = 1 },
    };

    const bytecode = [_]Instruction{
        Instruction{ .LOADK = LoadInstruction{ .register = 0, .const_idx = 0 } }, // r0 = 5
        Instruction{ .LOADK = LoadInstruction{ .register = 1, .const_idx = 1 } },
        Instruction{ .MAKE_CLOSURE = .{
            .destination = 2,
            .addr = 6,
            .arity = 1,
        } },
        Instruction{ .CAPTURE_CLOSURE = .{ .closure = 2, .captures = &[_]Register{2} } },
        Instruction{ .CALL = CallInstruction{ .function_reg = 2, .param_reg = 0 } }, // call factorial
        Instruction{ .HALT = {} },
        Instruction{ .LOADK = LoadInstruction{ .register = 2, .const_idx = 1 } }, // r2 = 1
        Instruction{ .GT = ComparisonInstruction{ .a = 1, .b = 2, .destination = 3 } }, // r3 = (n > 1)
        Instruction{ .JMP_IF = JumpIfInstruction{ .condition = 3, .offset = 1 } }, // if (n > 1) skip next instruction
        Instruction{ .RETURN = 2 }, // return 1 from r2
        Instruction{ .SUB = ArithmeticInstruction{ .destination = 3, .a = 1, .b = 2 } }, // r3 = n - 1
        Instruction{ .MOVE = MoveInstruction{ .destination = 4, .source = 1 } }, // save n to r4
        Instruction{ .MOVE = MoveInstruction{ .destination = 1, .source = 3 } }, // set (n - 1) as argument in r1
        Instruction{ .CALL = CallInstruction{ .function_reg = 0, .param_reg = 1 } },
        Instruction{ .MUL = ArithmeticInstruction{ .destination = 1, .a = 0, .b = 4 } }, // r1 = factorial(n - 1) * n
        Instruction{ .RETURN = 1 },
    };

    var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
    defer vm.deinit();
    try vm.run();

    try std.testing.expectEqual(120, vm.get_register(0).int);
}

// test "many closures with captures and register overrides - no memory leaks" {
//     // This test creates lots of closures in different registers,
//     // each capturing some of the closures created above.
//     // It also overrides registers to test GC properly collects unreachable closures.
//
//     const constants = [_]Value{
//         Value{ .int = 42 },
//         Value{ .int = 10 },
//         Value{ .int = 20 },
//     };
//
//     const bytecode = [_]Instruction{
//         // Create closure 1 in r0 (no captures)
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 100, .arity = 0, .captures = &[_]Register{} } },
//
//         // Create closure 2 in r1 (no captures)
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 101, .arity = 0, .captures = &[_]Register{} } },
//
//         // Create closure 3 in r2 capturing r0
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 102, .arity = 0, .captures = &[_]Register{0} } },
//
//         // Create closure 4 in r3 capturing r0 and r1
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 3, .addr = 103, .arity = 0, .captures = &[_]Register{ 0, 1 } } },
//
//         // Create closure 5 in r4 capturing r2 (which captures r0)
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 4, .addr = 104, .arity = 0, .captures = &[_]Register{2} } },
//
//         // Create closure 6 in r5 capturing r2, r3, r4
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 5, .addr = 105, .arity = 0, .captures = &[_]Register{ 2, 3, 4 } } },
//
//         // Override r0 with a new closure (old closure in r0 should be GC'd if not captured)
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 106, .arity = 0, .captures = &[_]Register{} } },
//
//         // Override r1 with another closure
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 107, .arity = 0, .captures = &[_]Register{5} } },
//
//         // Create more closures in higher registers
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 10, .addr = 108, .arity = 0, .captures = &[_]Register{ 1, 5 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 11, .addr = 109, .arity = 0, .captures = &[_]Register{10} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 12, .addr = 110, .arity = 0, .captures = &[_]Register{ 10, 11 } } },
//
//         // Override some registers again
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 3, .addr = 111, .arity = 0, .captures = &[_]Register{12} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 4, .addr = 112, .arity = 0, .captures = &[_]Register{ 3, 12 } } },
//
//         // Create even more closures to stress test
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 20, .addr = 113, .arity = 0, .captures = &[_]Register{4} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 21, .addr = 114, .arity = 0, .captures = &[_]Register{ 20, 12 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 22, .addr = 115, .arity = 0, .captures = &[_]Register{ 21, 20, 11 } } },
//
//         // Override earlier registers with new closures
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 116, .arity = 0, .captures = &[_]Register{22} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 117, .arity = 0, .captures = &[_]Register{ 22, 21 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 118, .arity = 0, .captures = &[_]Register{ 1, 0 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 116, .arity = 0, .captures = &[_]Register{22} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 117, .arity = 0, .captures = &[_]Register{ 22, 21 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 118, .arity = 0, .captures = &[_]Register{ 1, 0 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 116, .arity = 0, .captures = &[_]Register{22} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 117, .arity = 0, .captures = &[_]Register{ 22, 21 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 118, .arity = 0, .captures = &[_]Register{ 1, 0 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 116, .arity = 0, .captures = &[_]Register{22} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 117, .arity = 0, .captures = &[_]Register{ 22, 21 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 118, .arity = 0, .captures = &[_]Register{ 1, 0 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 116, .arity = 0, .captures = &[_]Register{22} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 117, .arity = 0, .captures = &[_]Register{ 22, 21 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 118, .arity = 0, .captures = &[_]Register{ 1, 0 } } },
//
//         // Load some constants and create closures (mix of operations)
//         Instruction{ .LOADK = LoadInstruction{ .register = 50, .const_idx = 0 } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 51, .addr = 119, .arity = 0, .captures = &[_]Register{2} } },
//
//         // More register overrides
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 10, .addr = 120, .arity = 0, .captures = &[_]Register{51} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 11, .addr = 121, .arity = 0, .captures = &[_]Register{ 10, 51 } } },
//
//         // Create final batch of closures
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 30, .addr = 122, .arity = 0, .captures = &[_]Register{ 11, 2, 1 } } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 31, .addr = 123, .arity = 0, .captures = &[_]Register{30} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 32, .addr = 124, .arity = 0, .captures = &[_]Register{ 30, 31 } } },
//
//         // Override many registers at once
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 0, .addr = 125, .arity = 0, .captures = &[_]Register{} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 1, .addr = 126, .arity = 0, .captures = &[_]Register{} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 2, .addr = 127, .arity = 0, .captures = &[_]Register{} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 3, .addr = 128, .arity = 0, .captures = &[_]Register{} } },
//         Instruction{ .MAKE_CLOSURE = .{ .destination = 4, .addr = 129, .arity = 0, .captures = &[_]Register{} } },
//
//         Instruction{ .HALT = {} },
//     };
//
//     var vm = try VM.init(std.testing.allocator, &bytecode, &constants);
//     defer vm.deinit();
//     try vm.run();
//
//     // If we get here without leaks, the test passes
//     // The defer vm.deinit() will call gc.sweep() which should clean up all closures
// }
