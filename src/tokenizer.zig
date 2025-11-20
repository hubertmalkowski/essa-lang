const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    pub const Tag = enum { LET, FN, IF, DEBUG, THEN, ELSE, TRUE, FALSE, PLUS, MINUS, ASTERISK, SLASH, EQUAL_EQUAL, EQUAL, LESS_THAN, GREATER_THAN, LPAREN, RPAREN, ARROW, INTEGER, IDENT, INVALID, EOF };
    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub fn lexeme(self: *const Token, source: []const u8) []const u8 {
        return source[self.loc.start..self.loc.end];
    }
};

pub const Tokenizer = struct {
    buffer: []const u8,
    current: usize,
    start: usize,

    pub fn init(buffer: []const u8) Tokenizer {
        return Tokenizer{ .buffer = buffer, .current = 0, .start = 0 };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();
        self.start = self.current;
        const char = self.advance() orelse return self.makeToken(.EOF);
        return switch (char) {
            '0'...'9' => self.number(),
            '-' => self.makeToken(.MINUS),
            '+' => self.makeToken(.PLUS),
            '*' => self.makeToken(.ASTERISK),
            '/' => self.makeToken(.SLASH),
            '=' => {
                if (self.match('=')) {
                    return self.makeToken(.EQUAL_EQUAL);
                } else if (self.match('>')) {
                    return self.makeToken(.ARROW);
                }
                return self.makeToken(.EQUAL);
            },
            'a'...'z', 'A'...'Z', '_' => self.identifier(),
            '>' => self.makeToken(.GREATER_THAN),
            '<' => self.makeToken(.LESS_THAN),
            '(' => self.makeToken(.LPAREN),
            ')' => self.makeToken(.RPAREN),
            else => self.makeToken(.INVALID),
        };
    }

    pub fn peekToken(self: *Tokenizer) Token {
        const token = self.next();
        self.current = self.start;
        return token;
    }

    fn advance(self: *Tokenizer) ?u8 {
        if (self.current >= self.buffer.len) {
            self.current += 1;
            return null;
        }
        const char = self.buffer[self.current];
        self.current += 1;
        return char;
    }

    fn peek(self: *Tokenizer) ?u8 {
        const char = self.advance();
        self.current -= 1;
        return char;
    }

    fn match(self: *Tokenizer, char: u8) bool {
        const peeked = self.peek() orelse return false;
        if (peeked == char) {
            self.current += 1;
            return true;
        }
        return false;
    }

    // like match but for slices
    fn matchSlice(self: *Tokenizer, slice: []const u8) bool {
        for (slice) |char| {
            if (!self.match(char)) return false;
        }
        return true;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn makeToken(self: *Tokenizer, tag: Token.Tag) Token {
        return Token{ .tag = tag, .loc = .{ .start = self.start, .end = self.current } };
    }

    fn isWhitespace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (true) {
            const c = self.peek() orelse return;
            if (isWhitespace(c)) {
                self.current += 1;
            } else {
                return;
            }
        }
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isAlphaNumeric(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }

    fn identifier(self: *Tokenizer) Token {
        var peeked = self.peek() orelse return self.checkKeyword();
        while (isAlphaNumeric(peeked)) {
            self.current += 1;
            peeked = self.peek() orelse return self.checkKeyword();
        }
        return self.checkKeyword();
    }

    fn checkKeyword(self: *Tokenizer) Token {
        const lexeme = self.buffer[self.start..self.current];
        const tag: Token.Tag = if (std.mem.eql(u8, lexeme, "let"))
            .LET
        else if (std.mem.eql(u8, lexeme, "fn"))
            .FN
        else if (std.mem.eql(u8, lexeme, "if"))
            .IF
        else if (std.mem.eql(u8, lexeme, "then"))
            .THEN
        else if (std.mem.eql(u8, lexeme, "else"))
            .ELSE
        else if (std.mem.eql(u8, lexeme, "true"))
            .TRUE
        else if (std.mem.eql(u8, lexeme, "false"))
            .FALSE
        else if (std.mem.eql(u8, lexeme, "debug"))
            .DEBUG
        else
            .IDENT;
        return self.makeToken(tag);
    }

    fn number(self: *Tokenizer) Token {
        var peeked = self.peek() orelse return self.makeToken(.INTEGER);
        while (isDigit(peeked)) {
            self.current += 1;
            peeked = self.peek() orelse return self.makeToken(.INTEGER);
        }
        // Check that number is not followed by alphabetic characters
        if (isAlpha(peeked)) {
            // Consume the invalid characters
            while (isAlphaNumeric(peeked)) {
                self.current += 1;
                peeked = self.peek() orelse return self.makeToken(.INVALID);
            }
            return self.makeToken(.INVALID);
        }
        return self.makeToken(.INTEGER);
    }
};

test "tokenize single character operators" {
    const test_cases = .{
        .{ "+", Token.Tag.PLUS },
        .{ "-", Token.Tag.MINUS },
        .{ "*", Token.Tag.ASTERISK },
        .{ "/", Token.Tag.SLASH },
        .{ "<", Token.Tag.LESS_THAN },
        .{ ">", Token.Tag.GREATER_THAN },
        .{ "(", Token.Tag.LPAREN },
        .{ ")", Token.Tag.RPAREN },
        .{ "=", Token.Tag.EQUAL },
    };

    inline for (test_cases) |case| {
        var tokenizer = Tokenizer{ .buffer = case[0], .current = 0, .start = 0 };
        const token = tokenizer.next();
        try std.testing.expectEqual(case[1], token.tag);
        try std.testing.expectEqual(@as(usize, 0), token.loc.start);
        try std.testing.expectEqual(@as(usize, 1), token.loc.end);
    }
}

test "tokenize double character operators" {
    const test_cases = .{
        .{ "==", Token.Tag.EQUAL_EQUAL },
        .{ "=>", Token.Tag.ARROW },
    };

    inline for (test_cases) |case| {
        var tokenizer = Tokenizer{ .buffer = case[0], .current = 0, .start = 0 };
        const token = tokenizer.next();
        try std.testing.expectEqual(case[1], token.tag);
        try std.testing.expectEqual(@as(usize, 0), token.loc.start);
        try std.testing.expectEqual(@as(usize, 2), token.loc.end);
    }
}

test "tokenize integers" {
    var tokenizer = Tokenizer{ .buffer = "123", .current = 0, .start = 0 };
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INTEGER, token.tag);
    try std.testing.expectEqual(@as(usize, 0), token.loc.start);
    try std.testing.expectEqual(@as(usize, 3), token.loc.end);
}

test "tokenize single digit" {
    var tokenizer = Tokenizer{ .buffer = "5", .current = 0, .start = 0 };
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INTEGER, token.tag);
    try std.testing.expectEqual(@as(usize, 0), token.loc.start);
    try std.testing.expectEqual(@as(usize, 1), token.loc.end);
}

test "token lexeme extraction" {
    const source = "12345";
    var tokenizer = Tokenizer{ .buffer = source, .current = 0, .start = 0 };
    var token = tokenizer.next();
    const lexeme = token.lexeme(source);
    try std.testing.expectEqualStrings("12345", lexeme);
}

test "tokenize keywords" {
    const test_cases = .{
        .{ "let", Token.Tag.LET },
        .{ "fn", Token.Tag.FN },
        .{ "if", Token.Tag.IF },
        .{ "then", Token.Tag.THEN },
        .{ "else", Token.Tag.ELSE },
        .{ "true", Token.Tag.TRUE },
        .{ "false", Token.Tag.FALSE },
        .{ "debug", Token.Tag.DEBUG },
    };

    inline for (test_cases) |case| {
        var tokenizer = Tokenizer.init(case[0]);
        const token = tokenizer.next();
        try std.testing.expectEqual(case[1], token.tag);
        try std.testing.expectEqual(@as(usize, 0), token.loc.start);
        try std.testing.expectEqual(case[0].len, token.loc.end);
    }
}

test "tokenize identifiers" {
    const test_cases = .{
        "x",
        "foo",
        "myVar",
        "snake_case",
        "_private",
        "camelCase123",
        "UPPERCASE",
    };

    inline for (test_cases) |source| {
        var tokenizer = Tokenizer.init(source);
        const token = tokenizer.next();
        try std.testing.expectEqual(Token.Tag.IDENT, token.tag);
        try std.testing.expectEqual(@as(usize, 0), token.loc.start);
        try std.testing.expectEqual(source.len, token.loc.end);
    }
}

test "identifier lexeme extraction" {
    const source = "myVariable";
    var tokenizer = Tokenizer.init(source);
    var token = tokenizer.next();
    const lexeme = token.lexeme(source);
    try std.testing.expectEqualStrings("myVariable", lexeme);
}

test "keywords are not identifiers" {
    // Test that keywords with suffixes become identifiers
    const test_cases = .{
        "letx",
        "fnction",
        "iffy",
        "thensome",
        "elsewhere",
        "truthy",
        "falsehood",
    };

    inline for (test_cases) |source| {
        var tokenizer = Tokenizer.init(source);
        const token = tokenizer.next();
        try std.testing.expectEqual(Token.Tag.IDENT, token.tag);
    }
}

test "EOF token" {
    var tokenizer = Tokenizer.init("");
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.EOF, token.tag);
}

test "invalid number with letters" {
    // 1xd should be INVALID, not a valid INTEGER
    var tokenizer = Tokenizer.init("1xd");
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INVALID, token.tag);
}

test "number followed by identifier should be two tokens" {
    // "123abc" should tokenize as INTEGER then IDENT (if we had whitespace skipping)
    // but without spaces, it should be INVALID
    var tokenizer = Tokenizer.init("123abc");
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INVALID, token.tag);
}

test "keyword lexeme extraction" {
    const test_cases = .{
        .{ "let", "let" },
        .{ "fn", "fn" },
        .{ "if", "if" },
        .{ "then", "then" },
        .{ "else", "else" },
        .{ "true", "true" },
        .{ "false", "false" },
    };

    inline for (test_cases) |case| {
        var tokenizer = Tokenizer.init(case[0]);
        var token = tokenizer.next();
        const lexeme = token.lexeme(case[0]);
        try std.testing.expectEqualStrings(case[1], lexeme);
    }
}

test "uppercase keywords are identifiers" {
    const test_cases = .{
        "LET",
        "FN",
        "IF",
        "THEN",
        "ELSE",
        "TRUE",
        "FALSE",
    };

    inline for (test_cases) |source| {
        var tokenizer = Tokenizer.init(source);
        const token = tokenizer.next();
        try std.testing.expectEqual(Token.Tag.IDENT, token.tag);
    }
}

test "mixed case keywords are identifiers" {
    const test_cases = .{
        "Let",
        "Fn",
        "If",
        "Then",
        "Else",
        "True",
        "False",
    };

    inline for (test_cases) |source| {
        var tokenizer = Tokenizer.init(source);
        const token = tokenizer.next();
        try std.testing.expectEqual(Token.Tag.IDENT, token.tag);
    }
}

test "skip leading whitespace" {
    var tokenizer = Tokenizer.init("   let");
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.LET, token.tag);
    try std.testing.expectEqual(@as(usize, 3), token.loc.start);
    try std.testing.expectEqual(@as(usize, 6), token.loc.end);
}

test "skip various whitespace characters" {
    var tokenizer = Tokenizer.init(" \t\n\r42");
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INTEGER, token.tag);
    try std.testing.expectEqual(@as(usize, 4), token.loc.start);
}

test "tokenize multiple tokens with whitespace" {
    var tokenizer = Tokenizer.init("let x = 42");

    const let_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.LET, let_token.tag);

    const x_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.IDENT, x_token.tag);

    const eq_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.EQUAL, eq_token.tag);

    const num_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INTEGER, num_token.tag);

    const eof_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.EOF, eof_token.tag);
}

test "whitespace only input returns EOF" {
    var tokenizer = Tokenizer.init("   \t\n  ");
    const token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.EOF, token.tag);
}

test "negative number is two tokens" {
    var tokenizer = Tokenizer.init("-12");

    const minus_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.MINUS, minus_token.tag);
    try std.testing.expectEqual(@as(usize, 0), minus_token.loc.start);
    try std.testing.expectEqual(@as(usize, 1), minus_token.loc.end);

    const int_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.INTEGER, int_token.tag);
    try std.testing.expectEqual(@as(usize, 1), int_token.loc.start);
    try std.testing.expectEqual(@as(usize, 3), int_token.loc.end);
}

test "unary operators are separate tokens" {
    var tokenizer = Tokenizer.init("-x");

    const minus_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.MINUS, minus_token.tag);

    const ident_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.IDENT, ident_token.tag);
}
