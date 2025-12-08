const std = @import("std");
const parser = @import("src/parser.zig");
const semantic = @import("src/semantic_analysis.zig");

pub fn main() !void {
    const code = "let factorial = fn x => if x < 1 then 1 else x * (factorial (x - 1))";
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var parse = parser.Parser.init(allocator, code);
    var ast = try parse.parse();
    defer ast.deinit(allocator);
    
    try semantic.analyze(allocator, &ast);
    
    const root_scope = ast.scope.?;
    std.debug.print("Root scope:\n", .{});
    std.debug.print("  factorial register: {}\n", .{root_scope.variables.get("factorial").?.register_index});
    
    const fn_expr = ast.statements[0].definition.value.fn_expr;
    const fn_scope = fn_expr.scope.?;
    std.debug.print("\nFunction scope:\n", .{});
    std.debug.print("  x register: {}\n", .{fn_scope.variables.get("x").?.register_index});
    std.debug.print("  factorial register: {}\n", .{fn_scope.variables.get("factorial").?.register_index});
    std.debug.print("  captures count: {}\n", .{fn_scope.captures.items.len});
    for (fn_scope.captures.items, 0..) |cap, i| {
        std.debug.print("  capture[{}]: name={s}, source_reg={}\n", .{i, cap.name, cap.source_reg});
    }
}
