const std = @import("std");
const Parser = @import("parser.zig").Parser;
const Emitter = @import("emitter.zig").Emitter;
const VM = @import("vm.zig").VM;
const Disassembler = @import("disassembler.zig").Disassembler;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <file.vm> [--disassemble] [--ast]\n", .{args[0]});
        std.process.exit(1);
    }

    const file_path = args[1];
    var show_disassembly = false;
    var show_ast = false;

    // Check for --disassemble flag
    if (args.len > 2) {
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--disassemble") or std.mem.eql(u8, arg, "-d")) {
                show_disassembly = true;
            }
        }
    }

    if (args.len > 2) {
        for (args[2..]) |arg| {
            if (std.mem.eql(u8, arg, "--ast") or std.mem.eql(u8, arg, "-a")) {
                show_ast = true;
            }
        }
    }

    const source = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch |err| {
        std.debug.print("Error reading file '{s}': {}\n", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var parser = Parser.init(allocator, source);
    const ast = parser.parse() catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.process.exit(1);
    };
    defer ast.deinit(allocator);
    if (show_ast) {
        std.debug.print("AST\n\n{f}\n===\n", .{ast});
    }

    var emitter = Emitter.init(allocator);
    defer emitter.deinit();
    const program = emitter.emit(ast) catch |err| {
        std.debug.print("Compile error: {}\n", .{err});
        std.process.exit(1);
    };
    defer {
        allocator.free(program.bytecode);
        allocator.free(program.constants);
    }

    // Show disassembly if requested
    if (show_disassembly) {
        Disassembler.disassemble(program.bytecode, program.constants);
    }

    var vm = VM.init(allocator, program.bytecode, program.constants) catch |err| {
        std.debug.print("VM initialization error: {}\n", .{err});
        std.process.exit(1);
    };
    defer vm.deinit();

    vm.run() catch |err| {
        std.debug.print("Runtime error: {}\n", .{err});
        std.process.exit(1);
    };
}
