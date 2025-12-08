const tokenizer = @import("tokenizer.zig");
const std = @import("std");
const ast = @import("ast.zig");

pub const ParserError = error{UnexpectedToken};

pub const Parser = struct {
    tokenizer: tokenizer.Tokenizer,
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{ .tokenizer = tokenizer.Tokenizer.init(source), .source = source, .allocator = allocator };
    }

    pub fn parse(self: *Parser) !ast.Ast {
        return self.program();
    }

    // <program> ::= <statement>*
    fn program(self: *Parser) !ast.Ast {
        var statements = std.ArrayList(ast.Statement).empty;
        while (self.tokenizer.peekToken().tag != .EOF) {
            const stmt = try self.statement();
            try statements.append(self.allocator, stmt);
        }

        return .{ .statements = try statements.toOwnedSlice(self.allocator), .scope = null };
    }

    // <statement> ::= <definition> | <debug>
    fn statement(self: *Parser) !ast.Statement {
        const next_tok = self.tokenizer.peekToken();
        return switch (next_tok.tag) {
            .DEBUG => try self.debugStmt(),
            .LET => ast.Statement{ .definition = try self.definition() },
            else => ParserError.UnexpectedToken,
        };
    }

    // <debug> ::= "debug" <expression>
    fn debugStmt(self: *Parser) !ast.Statement {
        _ = try self.expect(.DEBUG);
        const value = try self.expression();
        return ast.Statement{ .debug = value };
    }

    // <definition> ::= "let" <identifier> "=" <expression>
    fn definition(self: *Parser) !ast.Definition {
        _ = try self.expect(.LET);
        const name_tok = try self.expect(.IDENT);
        const name = name_tok.lexeme(self.source);
        _ = try self.expect(.EQUAL);
        const value = try self.expression();

        return .{ .name = name, .value = value };
    }

    // <expression> ::= <if-expr>
    //                | <fn-expr>
    //                | <binary-expr>
    fn expression(self: *Parser) anyerror!ast.Expr {
        const next_tok = self.tokenizer.peekToken();
        return switch (next_tok.tag) {
            .IF => try self.ifExpr(),
            .FN => try self.fnExpr(),
            else => try self.binaryExpr(),
        };
    }

    fn ifExpr(self: *Parser) !ast.Expr {
        _ = try self.expect(.IF);
        const condition = try self.expression();
        _ = try self.expect(.THEN);
        const then_branch = try self.expression();
        _ = try self.expect(.ELSE);
        const else_branch = try self.expression();
        const if_expr = try self.allocator.create(ast.IfExpr);
        if_expr.* = ast.IfExpr{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        };

        return ast.Expr{ .if_expr = if_expr };
    }

    pub fn fnExpr(self: *Parser) !ast.Expr {
        _ = try self.expect(.FN);
        var params = std.ArrayList([]const u8).empty;

        // Check for unit parameter: fn () => expr
        if (self.tokenizer.peekToken().tag == .LPAREN) {
            _ = self.tokenizer.next();
            _ = try self.expect(.RPAREN);
            // Unit parameter - represented as a single parameter named "()"
            // This is a special marker that we'll use for zero-arg functions
            try params.append(self.allocator, "()");
        } else {
            // Regular parameters: fn x => expr or fn a b => expr
            while (self.tokenizer.peekToken().tag != .ARROW) {
                const param = try self.expect(.IDENT);
                try params.append(self.allocator, param.lexeme(self.source));
            }
        }

        _ = try self.expect(.ARROW);
        const expr = try self.expression();

        const fn_expr = try self.allocator.create(ast.FnExpr);
        fn_expr.* = ast.FnExpr{ .params = try params.toOwnedSlice(self.allocator), .body = expr, .scope = null };

        return ast.Expr{ .fn_expr = fn_expr };
    }

    fn binaryExpr(self: *Parser) !ast.Expr {
        return try self.comparisonExpr();
    }

    fn comparisonExpr(self: *Parser) !ast.Expr {
        // <comparison-expr> ::= <additive-expr> (("<" | ">" | "==") <additive-expr>)?

        const left = try self.additiveExpr();

        const op_tag = self.tokenizer.peekToken().tag;
        if (op_tag == .LESS_THAN or op_tag == .GREATER_THAN or op_tag == .EQUAL_EQUAL) {
            _ = self.tokenizer.next();

            const op: ast.BinaryOp = switch (op_tag) {
                .LESS_THAN => .Lt,
                .GREATER_THAN => .Gt,
                .EQUAL_EQUAL => .Eq,
                else => unreachable,
            };

            const right = try self.additiveExpr();

            const binary = try self.allocator.create(ast.BinaryExpr);
            binary.* = ast.BinaryExpr{
                .left = left,
                .op = op,
                .right = right,
            };

            return ast.Expr{ .binary = binary };
        }

        return left;
    }

    fn additiveExpr(self: *Parser) !ast.Expr {
        // <additive-expr> ::= <multiplicative-expr> (("+" | "-") <multiplicative-expr>)*

        var left = try self.multiplicativeExpr();

        while (true) {
            const op_tag = self.tokenizer.peekToken().tag;
            if (op_tag != .PLUS and op_tag != .MINUS) break;

            const op_token = self.tokenizer.next();
            const op: ast.BinaryOp = if (op_token.tag == .PLUS) .Add else .Sub;

            const right = try self.multiplicativeExpr();

            const binary = try self.allocator.create(ast.BinaryExpr);
            binary.* = ast.BinaryExpr{
                .left = left,
                .op = op,
                .right = right,
            };

            left = ast.Expr{ .binary = binary };
        }

        return left;
    }

    fn multiplicativeExpr(self: *Parser) !ast.Expr {
        // <multiplicative-expr> ::= <call-expr> (("*" | "/") <call-expr>)*

        var left = try self.callExpr();

        while (true) {
            const op_tag = self.tokenizer.peekToken().tag;
            if (op_tag != .ASTERISK and op_tag != .SLASH) break;

            const op_token = self.tokenizer.next();
            const op: ast.BinaryOp = if (op_token.tag == .ASTERISK) .Mul else .Div;

            const right = try self.callExpr();

            const binary = try self.allocator.create(ast.BinaryExpr);
            binary.* = ast.BinaryExpr{
                .left = left,
                .op = op,
                .right = right,
            };

            left = ast.Expr{ .binary = binary };
        }

        return left;
    }

    fn callExpr(self: *Parser) !ast.Expr {
        // <call-expr> ::= <primary-expr> <primary-expr>*

        const func = try self.primaryExpr();

        var args = std.ArrayList(ast.Expr).empty;

        while (isPrimaryStart(self.tokenizer.peekToken().tag)) {
            const arg = try self.primaryExpr();
            try args.append(self.allocator, arg);
        }

        if (args.items.len == 0) {
            return func;
        }

        // We have a call
        const call = try self.allocator.create(ast.CallExpr);
        call.* = ast.CallExpr{
            .function = func,
            .args = try args.toOwnedSlice(self.allocator),
        };

        return ast.Expr{ .call = call };
    }

    fn isPrimaryStart(tag: tokenizer.Token.Tag) bool {
        return tag == .INTEGER or
            tag == .TRUE or
            tag == .FALSE or
            tag == .IDENT or
            tag == .LPAREN;
    }

    fn primaryExpr(self: *Parser) !ast.Expr {
        // <primary-expr> ::= <integer> | <boolean> | <identifier> | "(" <expression> ")"

        const token = self.tokenizer.peekToken();

        switch (token.tag) {
            .INTEGER => {
                _ = self.tokenizer.next();
                const lexeme = token.lexeme(self.source);
                const value = try std.fmt.parseInt(i64, lexeme, 10);
                return ast.Expr{ .integer = value };
            },
            .TRUE => {
                _ = self.tokenizer.next();
                return ast.Expr{ .boolean = true };
            },
            .FALSE => {
                _ = self.tokenizer.next();
                return ast.Expr{ .boolean = false };
            },
            .IDENT => {
                _ = self.tokenizer.next();
                const name = token.lexeme(self.source);
                return ast.Expr{ .identifier = name };
            },
            .LPAREN => {
                _ = self.tokenizer.next();
                // Check if this is unit () or a parenthesized expression
                if (self.tokenizer.peekToken().tag == .RPAREN) {
                    _ = self.tokenizer.next();
                    return ast.Expr{ .unit = {} };
                }
                const expr = try self.expression();
                _ = try self.expect(.RPAREN);
                return expr;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn expect(self: *Parser, token: tokenizer.Token.Tag) !tokenizer.Token {
        if (self.tokenizer.peekToken().tag != token) {
            return ParserError.UnexpectedToken;
        }
        return self.tokenizer.next();
    }
};

test "parse integer literal" {
    const source = "let x = 42";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expectEqualStrings("x", program.statements[0].definition.name);
    try std.testing.expect(program.statements[0].definition.value == .integer);
    try std.testing.expectEqual(@as(i64, 42), program.statements[0].definition.value.integer);
}

test "parse boolean literals" {
    const source = "let t = true\nlet f = false";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), program.statements.len);
    try std.testing.expect(program.statements[0].definition.value.boolean == true);
    try std.testing.expect(program.statements[1].definition.value.boolean == false);
}

test "parse identifier" {
    const source = "let y = x";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0].definition.value == .identifier);
    try std.testing.expectEqualStrings("x", program.statements[0].definition.value.identifier);
}

test "parse simple addition" {
    const source = "let result = 1 + 2";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr == .binary);

    const binary = expr.binary;
    try std.testing.expect(binary.op == .Add);
    try std.testing.expect(binary.left == .integer);
    try std.testing.expectEqual(@as(i64, 1), binary.left.integer);
    try std.testing.expect(binary.right == .integer);
    try std.testing.expectEqual(@as(i64, 2), binary.right.integer);
}

test "parse subtraction" {
    const source = "let result = 10 - 5";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Sub);
    try std.testing.expectEqual(@as(i64, 10), expr.binary.left.integer);
    try std.testing.expectEqual(@as(i64, 5), expr.binary.right.integer);
}

test "parse multiplication" {
    const source = "let result = 3 * 4";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Mul);
}

test "parse division" {
    const source = "let result = 20 / 4";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Div);
}

test "parse operator precedence: multiplication before addition" {
    const source = "let result = 1 + 2 * 3";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    // Should parse as: 1 + (2 * 3)
    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Add);
    try std.testing.expectEqual(@as(i64, 1), expr.binary.left.integer);

    const right = expr.binary.right;
    try std.testing.expect(right == .binary);
    try std.testing.expect(right.binary.op == .Mul);
    try std.testing.expectEqual(@as(i64, 2), right.binary.left.integer);
    try std.testing.expectEqual(@as(i64, 3), right.binary.right.integer);
}

test "parse left associativity" {
    const source = "let result = 10 - 3 - 2";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    // Should parse as: (10 - 3) - 2
    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Sub);
    try std.testing.expectEqual(@as(i64, 2), expr.binary.right.integer);

    const left = expr.binary.left;
    try std.testing.expect(left == .binary);
    try std.testing.expect(left.binary.op == .Sub);
    try std.testing.expectEqual(@as(i64, 10), left.binary.left.integer);
    try std.testing.expectEqual(@as(i64, 3), left.binary.right.integer);
}

test "parse parentheses" {
    const source = "let result = (1 + 2) * 3";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    // Should parse as: (1 + 2) * 3
    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Mul);

    const left = expr.binary.left;
    try std.testing.expect(left.binary.op == .Add);
    try std.testing.expectEqual(@as(i64, 3), expr.binary.right.integer);
}

test "parse comparison equal" {
    const source = "let result = 5 == 5";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Eq);
}

test "parse comparison less than" {
    const source = "let result = 3 < 5";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Lt);
}

test "parse comparison greater than" {
    const source = "let result = 10 > 5";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr.binary.op == .Gt);
}

test "parse if expression" {
    const source = "let result = if true then 1 else 0";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr == .if_expr);

    const if_expr = expr.if_expr;
    try std.testing.expect(if_expr.condition.boolean == true);
    try std.testing.expectEqual(@as(i64, 1), if_expr.then_branch.integer);
    try std.testing.expectEqual(@as(i64, 0), if_expr.else_branch.integer);
}

test "parse if with comparison" {
    const source = "let result = if x < 5 then 1 else 0";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    const if_expr = expr.if_expr;
    try std.testing.expect(if_expr.condition == .binary);
    try std.testing.expect(if_expr.condition.binary.op == .Lt);
}

test "parse function with no parameters" {
    const source = "let f = fn => 42";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr == .fn_expr);

    const fn_expr = expr.fn_expr;
    try std.testing.expectEqual(@as(usize, 0), fn_expr.params.len);
    try std.testing.expectEqual(@as(i64, 42), fn_expr.body.integer);
}

test "parse function with one parameter" {
    const source = "let f = fn x => x";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    const fn_expr = expr.fn_expr;
    try std.testing.expectEqual(@as(usize, 1), fn_expr.params.len);
    try std.testing.expectEqualStrings("x", fn_expr.params[0]);
    try std.testing.expectEqualStrings("x", fn_expr.body.identifier);
}

test "parse function with multiple parameters" {
    const source = "let add = fn a b => a + b";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    const fn_expr = expr.fn_expr;
    try std.testing.expectEqual(@as(usize, 2), fn_expr.params.len);
    try std.testing.expectEqualStrings("a", fn_expr.params[0]);
    try std.testing.expectEqualStrings("b", fn_expr.params[1]);
}

test "parse function call with one argument" {
    const source = "let result = f 5";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr == .call);

    const call = expr.call;
    try std.testing.expectEqualStrings("f", call.function.identifier);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqual(@as(i64, 5), call.args[0].integer);
}

test "parse function call with multiple arguments" {
    const source = "let result = add 3 4";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    const call = expr.call;
    try std.testing.expectEqual(@as(usize, 2), call.args.len);
    try std.testing.expectEqual(@as(i64, 3), call.args[0].integer);
    try std.testing.expectEqual(@as(i64, 4), call.args[1].integer);
}

test "parse nested function call" {
    const source = "let result = f (g 5)";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    const outer_call = expr.call;
    try std.testing.expectEqualStrings("f", outer_call.function.identifier);
    try std.testing.expectEqual(@as(usize, 1), outer_call.args.len);

    const arg = outer_call.args[0];
    try std.testing.expect(arg == .call);
    try std.testing.expectEqualStrings("g", arg.call.function.identifier);
}

test "parse multiple definitions" {
    const source =
        \\let x = 5
        \\let y = 10
        \\let z = x + y
    ;
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.statements.len);
    try std.testing.expectEqualStrings("x", program.statements[0].definition.name);
    try std.testing.expectEqualStrings("y", program.statements[1].definition.name);
    try std.testing.expectEqualStrings("z", program.statements[2].definition.name);
}

test "parse debug statement" {
    const source = "debug 42";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0] == .debug);
    try std.testing.expectEqual(@as(i64, 42), program.statements[0].debug.integer);
}

test "parse debug with expression" {
    const source = "debug 2 + 3";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0] == .debug);
    try std.testing.expect(program.statements[0].debug == .binary);
    try std.testing.expect(program.statements[0].debug.binary.op == .Add);
}

test "parse mixed statements" {
    const source =
        \\let x = 5
        \\debug x
        \\let y = 10
    ;
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), program.statements.len);
    try std.testing.expect(program.statements[0] == .definition);
    try std.testing.expect(program.statements[1] == .debug);
    try std.testing.expect(program.statements[2] == .definition);
}

test "parse unit literal" {
    const source = "let x = ()";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), program.statements.len);
    try std.testing.expect(program.statements[0].definition.value == .unit);
}

test "parse function with unit parameter" {
    const source = "let f = fn () => 42";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr == .fn_expr);

    const fn_expr = expr.fn_expr;
    try std.testing.expectEqual(@as(usize, 1), fn_expr.params.len);
    try std.testing.expectEqualStrings("()", fn_expr.params[0]);
    try std.testing.expectEqual(@as(i64, 42), fn_expr.body.integer);
}

test "parse function call with unit argument" {
    const source = "let result = f ()";
    var parser = Parser.init(std.testing.allocator, source);
    const program = try parser.parse();
    defer program.deinit(std.testing.allocator);

    const expr = program.statements[0].definition.value;
    try std.testing.expect(expr == .call);

    const call = expr.call;
    try std.testing.expectEqualStrings("f", call.function.identifier);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expect(call.args[0] == .unit);
}
