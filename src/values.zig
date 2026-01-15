const opcodes = @import("opcodes.zig");

pub const Value = union(enum) {
    integer: i64,
    float: f64,
    bool: bool,
    closure: *Closure,
    tuple: *Tuple,
    nil,

    pub fn isInt(self: *const Value) bool {
        return self.* == .integer;
    }

    pub fn isFloat(self: *const Value) bool {
        return self.* == .float;
    }

    pub fn asFloat(self: *const Value) f64 {
        return switch (self.*) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => unreachable, // lub obsługa błędu
        };
    }

    pub fn isNumeric(self: *const Value) bool {
        return self.isInt() or self.isFloat();
    }

    pub fn isBool(self: *const Value) bool {
        return self.* == .bool;
    }

    pub fn isTuple(self: *const Value) bool {
        return self.* == .tuple;
    }

    pub fn isNil(self: *const Value) bool {
        return self.* == .nil;
    }
};

// GC Header
// @TODO
pub const Object = struct { next: ?*Object };

pub const ClosureUpvalueDescription = struct { parent_upvalue: bool, index: u8 };
pub const ClosureProto = struct {
    instructions: []opcodes.Instruction,
    constants: []Value,
    upvalue_info: []ClosureUpvalueDescription,
    registers: u8,
    arity: u8,
};
pub const Closure = struct {
    object: Object,
    proto: *const ClosureProto,
    upvalues: []Value,
};

pub const Tuple = struct {
    object: Object,
    tag: u8,
    values: []Value,
};
