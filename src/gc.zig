const std = @import("std");
const vm = @import("vm.zig");
const value = @import("values.zig");
const opcodes = @import("opcodes.zig");

const GC = struct {
    buffer: []u8,
    fbaA: std.heap.FixedBufferAllocator,
    fbaB: std.heap.FixedBufferAllocator,

    arenaA: std.heap.ArenaAllocator,
    arenaB: std.heap.ArenaAllocator,

    parentAlloc: std.mem.Allocator,

    from_space: *std.heap.ArenaAllocator,
    to_space: *std.heap.ArenaAllocator,

    allocated_bytes: usize = 0,
    threshold: usize = 1024 * 1024 * 512,

    pub fn init(self: *GC, allocator: std.mem.Allocator) !void {
        const total_size = 1024 * 1024 * 1024;
        const buffer = try allocator.alloc(u8, total_size);
        const half = total_size / 2;
        self.fbaA = std.heap.FixedBufferAllocator.init(buffer[0..half]);
        self.fbaB = std.heap.FixedBufferAllocator.init(buffer[half..]);
        self.arenaA = std.heap.ArenaAllocator.init(self.fbaA.allocator());
        self.arenaB = std.heap.ArenaAllocator.init(self.fbaB.allocator());
        self.parentAlloc = allocator;
        self.from_space = &self.arenaA;
        self.to_space = &self.arenaB;
        self.allocated_bytes = 0;
        self.threshold = 1024 * 512;
    }

    pub fn deinit(self: *GC) void {
        self.arenaA.deinit();
        self.arenaB.deinit();
        self.parentAlloc.free(self.buffer);
    }

    pub fn initDefault() GC {
        return init(std.heap.page_allocator);
    }

    pub fn allocate(self: *GC, frames: []const vm.CallFrame, comptime T: type) !*T {
        const size = @sizeOf(T);

        if (self.allocated_bytes + size > self.threshold) {
            try self.collect(frames);
        }

        const ptr = try self.from_space.allocator().create(T);

        const object_ptr = &ptr.object; // Get pointer to embedded Object
        object_ptr.*.forwarded = null;
        self.allocated_bytes += size;
        return ptr;
    }

    pub fn collect(self: *GC, frames: []const vm.CallFrame) !void {
        const start = std.time.microTimestamp();
        const old = self.allocated_bytes;
        self.allocated_bytes = 0;
        for (frames) |*frame| {
            for (frame.registers) |*reg| {
                const val = try self.evacuateVal(reg.*);
                reg.* = val;
            }
        }

        const temp = self.from_space;
        self.from_space = self.to_space;
        self.to_space = temp;

        _ = self.to_space.reset(.retain_capacity);
        self.threshold = self.threshold * 2;

        const end = std.time.microTimestamp();

        const time = @as(f64, @floatFromInt(end - start)) / 1000.0;
        const evac: f64 = @as(f64, @floatFromInt(self.allocated_bytes)) / (1024 * 1024);
        const deleted: f64 = @as(f64, @floatFromInt(old)) / (1024 * 1024);

        std.debug.print("Collection done, {d:.2} MiB evacuated, {d:.2} MiB removed in {d:.2} ms\n", .{ evac, deleted, time });
    }

    pub fn evacuateVal(self: *GC, val: value.Value) !value.Value {
        switch (val) {
            .closure => |closure| {
                if (closure.object.forwarded) |already_moved| {
                    const moved: *value.Closure = @fieldParentPtr("object", already_moved);
                    return value.Value{ .closure = moved };
                }
                for (closure.upvalues) |*upvalue| {
                    const newUpval = try self.evacuateVal(upvalue.*);
                    upvalue.* = newUpval;
                }
                const copied = try self.to_space.allocator().create(value.Closure);
                closure.*.object.forwarded = &copied.object;
                copied.* = closure.*;
                copied.*.object.forwarded = null;
                self.allocated_bytes += @sizeOf(value.Closure);
                return value.Value{ .closure = copied };
            },
            .tuple => |tuple| {
                if (tuple.object.forwarded) |already_moved| {
                    const moved: *value.Tuple = @fieldParentPtr("object", already_moved);
                    return value.Value{ .tuple = moved };
                }

                for (tuple.values) |*tvalue| {
                    const newval = try self.evacuateVal(tvalue.*);
                    tvalue.* = newval;
                }

                const copied = try self.to_space.allocator().create(value.Tuple);
                tuple.*.object.forwarded = &copied.object;
                copied.* = tuple.*;
                copied.*.object.forwarded = null;
                self.allocated_bytes += @sizeOf(value.Tuple);
                return value.Value{ .tuple = copied };
            },

            else => |other| return other,
        }
    }
};

test "GC Works" {
    var allocator = std.testing.allocator;
    const deadObjects = 255;
    const aliveObjects = 255;

    const proto = try allocator.create(value.ClosureProto);

    defer std.testing.allocator.destroy(proto);
    const upvalues = [_]value.ClosureUpvalueDescription{};
    const constants = [_]value.Value{};
    const instructions = [_]opcodes.Instruction{};
    proto.* = .{ .instructions = &instructions, .constants = &constants, .upvalue_info = &upvalues, .arity = 0, .registers = @max(deadObjects, aliveObjects) };
    const closure = try std.testing.allocator.create(value.Closure);
    defer std.testing.allocator.destroy(closure);
    closure.* = .{
        .object = .{ .forwarded = null },
        .proto = proto,
        .upvalues = &[_]value.Value{},
    };

    var frame = try vm.CallFrame.init(allocator, closure, 0);
    defer frame.deinit(allocator);
    const frames = [_]vm.CallFrame{frame};

    var gc: GC = undefined;
    try gc.init(std.testing.allocator);
    defer gc.deinit();

    for (0..100000) |_| {
        for (0..deadObjects) |idx| {
            const obj = try gc.allocate(&frames, value.Tuple);

            obj.tag = 0;

            var values = std.ArrayList(value.Value).empty;
            if (idx > 0) {
                try values.append(gc.from_space.allocator(), frame.getReg(idx - 1));
            } else {
                try values.append(gc.from_space.allocator(), value.Value{ .integer = 10123 });
            }

            obj.*.values = try values.toOwnedSlice(gc.from_space.allocator());

            frame.setReg(idx, value.Value{ .tuple = obj });
        }
    }

    for (0..aliveObjects) |idx| {
        const obj = try gc.allocate(&frames, value.Tuple);

        obj.tag = 0;

        var values = std.ArrayList(value.Value).empty;
        if (idx > 0) {
            try values.append(gc.from_space.allocator(), frame.getReg(idx - 1));
        } else {
            try values.append(gc.from_space.allocator(), value.Value{ .integer = 10123 });
        }

        obj.*.values = try values.toOwnedSlice(gc.from_space.allocator());

        frame.setReg(idx, value.Value{ .tuple = obj });
    }
}
