const opcodes = @import("opcodes.zig");

pub const Value = union(enum) {
    integer: i64,
    float: f64,
    closure: *Closure,
    tuple: *Tuple,
};

// GC Header
// @TODO
pub const Object = struct { next: ?*Object };

pub const ClosureUpvalueDescription = struct { parent_upvalue: bool, index: u8 };
pub const ClosureProto = struct {
    instructions: []opcodes.Instruction,
    constants: []Value,
    upvalue_info: []ClosureUpvalueDescription,
    registers: u8, //
    arity: u8,
};
pub const Closure = struct {
    object: Object,
    proto: *ClosureProto,
    upvalues: []Value,
};

pub const Tuple = struct {
    object: Object,
    tag: u8,
    values: []Value,
};
