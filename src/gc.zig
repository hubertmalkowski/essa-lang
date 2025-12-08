const std = @import("std");
const value = @import("value.zig");
const vm = @import("vm.zig");

pub const GCSweep = struct {
    head: ?*value.Object,
    current_memory: usize,
    limit: usize,

    pub fn init() GCSweep {
        return .{ .head = null, .current_memory = 0, .limit = 10 };
    }

    pub fn allocObject(self: *GCSweep, allocator: std.mem.Allocator, frames: []const vm.CallFrame, comptime T: type) !*T {
        const total_size = @sizeOf(T);

        if (self.current_memory + total_size > self.limit) {
            // std.debug.print("Memory reached: {d}; Current limit: {d} \n", .{ self.current_memory + total_size, self.limit });
            self.collect(allocator, frames);
        }
        const ptr = try allocator.create(T);
        const object_ptr = &ptr.object; // Get pointer to embedded Object
        object_ptr.*.next = self.head;
        self.head = object_ptr;
        self.current_memory += total_size;

        object_ptr.*.marked = false;

        return ptr;
    }

    pub fn collect(self: *GCSweep, allocator: std.mem.Allocator, frames: []const vm.CallFrame) void {
        for (frames) |frame| {
            for (frame.registers) |register| {
                mark(register);
            }
        }
        self.sweep(allocator);
    }

    pub fn sweep(self: *GCSweep, allocator: std.mem.Allocator) void {
        var next = self.head;
        var prev: ?*value.Object = null;
        self.limit = self.current_memory * 2;
        // var counter: u64 = 0;

        while (next) |obj| {
            if (obj.marked) {
                obj.marked = false;
                next = obj.next;
                prev = obj;
            } else {
                next = obj.next;

                if (prev) |p| {
                    p.next = next;
                } else {
                    self.head = next;
                }
                self.delete(allocator, obj);
                // counter += 1;
            }
        }

        // std.debug.print("Objects sweeped: {d}\n", .{counter});
    }

    fn delete(self: *GCSweep, allocator: std.mem.Allocator, obj: *value.Object) void {
        switch (obj.type) {
            .closure => {
                const closure: *value.Closure = @fieldParentPtr("object", obj);
                allocator.free(closure.captures);
                allocator.destroy(closure);
                self.current_memory -= @sizeOf(value.Closure);
            },
        }
    }

    fn mark(val: value.Value) void {
        switch (val) {
            .closure => |closure| {
                if (closure.object.marked) return;
                closure.object.marked = true;
                for (closure.captures) |capture| {
                    mark(capture);
                }
            },
            else => {},
        }
    }
};
