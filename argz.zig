const Options = struct { auto_help: bool = true };

pub fn init(
    A: std.mem.Allocator,
    o: Options,
    comptime spec: []const u8,
) !Argz(spec) {
    return Argz(spec).init(A, o);
}

pub fn Argz(comptime spec: []const u8) type {
    return struct {
        const params = Param.parse(spec);
        const Args = ArgsType(&params);

        A: std.mem.Allocator,
        o: Options,
        argv: [][:0]u8,
        extra_tab: [][:0]const u8,
        extra_end: usize = 0,

        pub fn init(A: std.mem.Allocator, o: Options) !@This() {
            const argv = try std.process.argsAlloc(A);
            errdefer std.process.argsFree(A, argv);
            const extra_tab = try A.alloc([:0]const u8, argv.len);
            return .{ .A = A, .o = o, .argv = argv, .extra_tab = extra_tab };
        }

        pub fn deinit(this: @This()) void {
            this.A.free(this.extra_tab);
            std.process.argsFree(this.A, this.argv);
        }

        pub fn parse(this: *@This()) !Args {
            var result = std.mem.zeroes(Args);
            var ipos: usize = 0;

            var used_value = false;
            var iter = ArgvIterator.init(this.argv);
            loop: while (iter.next(used_value)) |opt| switch (opt) {
                .name => |name| {
                    inline for (params) |p| if (eql(p.name, name.name)) {
                        used_value = try handleValue(p, &result, name.value);
                        continue :loop;
                    };
                    return error.NameNotFound;
                },
                .code => |code| {
                    inline for (params) |p| if (p.code[0] == code.code) {
                        used_value = try handleValue(p, &result, code.value);
                        continue :loop;
                    };
                    return error.CodeNotFound;
                },
                .pos => |pos| {
                    used_value = false;
                    var i: usize = 0;
                    inline for (params) |p| if (p.is_pos) {
                        if (i == ipos) {
                            _ = try handle(p, &result, pos);
                            ipos += 1;
                            continue :loop;
                        }
                        i += 1;
                    };

                    this.extra_tab[this.extra_end] = pos;
                    this.extra_end += 1;
                    continue :loop;
                },
            };

            if (@hasField(Args, "help") and this.o.auto_help) {
                if (result.help > 0) {
                    try this.printHelp(std.io.getStdOut().writer());
                    std.process.exit(0);
                }
            }

            return result;
        }

        pub fn extra(this: @This()) [][:0]const u8 {
            return this.extra_tab[0..this.extra_end];
        }

        pub fn printHelp(this: @This(), writer: anytype) !void {
            const name = std.fs.path.basename(this.argv[0]);
            try writer.print(
                "Usage: {s} [options] [arguments]\n{s}",
                .{ name, spec },
            );
        }

        fn handleValue(comptime p: Param, result: *Args, value: ArgvIterator.Value) !bool {
            const used = try handle(p, result, value.value);
            if (!used and value.is_forced)
                return error.IgnoredArgument;
            return used;
        }

        fn handle(comptime p: Param, result: *Args, value: ?[]const u8) !bool {
            if (p.arity == 0) {
                @field(result.*, p.fullName()) += 1;
                return false;
            }
            if (value) |val| {
                @field(result.*, p.fullName()) = parseValue(p.Type(), val) catch
                    return error.ParseError;
                return true;
            }
            return error.MissingArgument;
        }
    };
}

fn parseValue(T: type, str: []const u8) !T {
    switch (@typeInfo(T)) {
        .int => return std.fmt.parseInt(T, str, 0),
        .float => return std.fmt.parseFloat(T, str),
        else => {},
    }
    if (T == []const u8) return str;
    return error.TypeNotSupported;
}

fn ArgsType(comptime params: []const Param) type {
    var fields: [params.len]std.builtin.Type.StructField = undefined;
    for (params, &fields) |p, *f| {
        const name = std.fmt.comptimePrint("{s}", .{p.fullName()});
        const Type = if (p.arity == 0) p.Type() else ?p.Type();
        f.* = .{
            .name = name,
            .type = Type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Type),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

const ArgvIterator = struct {
    const Value = struct {
        value: ?[]const u8,
        is_inline: bool,
        is_forced: bool,
        pub fn format(
            this: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            const i = if (this.is_inline) "I" else " ";
            const f = if (this.is_forced) "F" else " ";
            if (this.value) |v|
                try writer.print("value{{ {s}{s} '{s}' }}", .{ i, f, v })
            else
                try writer.print("value{{ {s}{s} (null) }}", .{ i, f });
        }
    };
    const Option = union(enum) {
        name: struct { name: []const u8, value: Value },
        code: struct { code: u8, value: Value },
        pos: [:0]const u8,

        pub fn format(
            this: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            switch (this) {
                .name => |name| try writer.print(
                    "Option{{ name '{s}' {} }}",
                    .{ name.name, name.value },
                ),
                .code => |code| try writer.print(
                    "Option{{ code '{c}' {} }}",
                    .{ code.code, code.value },
                ),
                .pos => |pos| try writer.print(
                    "Option{{ pos '{s}' }}",
                    .{pos},
                ),
            }
        }
    };

    argv: [][:0]u8,
    i: usize = 0,
    j: usize = 0,
    is_past_dash2: bool = false,
    opt: ?Option = null,

    pub fn init(argv: [][:0]u8) @This() {
        return .{ .argv = argv };
    }

    pub fn next(this: *@This(), used_value: bool) ?Option {
    //     const r = this.next_(used_value);
    //     std.debug.print(
    //         "iter on argv[{}][{}]: used {} {any}\n",
    //         .{ this.i, this.j, used_value, r },
    //     );
    //     this.opt = r;
    //     return r;
    // }
    // pub fn next_(this: *@This(), used_value: bool) ?Option {
        if (this.j > 0) {
            if (used_value) {
                this.i += @intFromBool(!this.isInline());
                return this.nextArg();
            }
            return this.nextCode();
        }

        this.i += @intFromBool(used_value and !this.isInline());
        return this.nextArg();
    }

    pub fn isInline(this: @This()) bool {
        return if (this.opt) |opt| switch (opt) {
            .name => |name| name.value.is_inline,
            .code => |code| code.value.is_inline,
            .pos => false,
        } else false;
    }

    fn nextCode(this: *@This()) ?Option {
        const curr = this.argv[this.i];
        const after = if (this.i + 1 < this.argv.len)
            this.argv[this.i + 1]
        else
            null;

        this.j += 1;
        if (this.j >= curr.len) return this.nextArg();

        return if (this.j + 1 >= curr.len)
            .{ .code = .{ .code = curr[this.j], .value = .{
                .value = after,
                .is_inline = false,
                .is_forced = false,
            } } }
        else if (curr[this.j + 1] == '=')
            .{ .code = .{ .code = curr[this.j], .value = .{
                .value = curr[this.j + 2 ..],
                .is_inline = true,
                .is_forced = true,
            } } }
        else
            .{ .code = .{ .code = curr[this.j], .value = .{
                .value = curr[this.j + 1 ..],
                .is_inline = true,
                .is_forced = false,
            } } };
    }

    fn nextArg(this: *@This()) ?Option {
        this.i += 1;
        this.j = 0;
        if (this.i >= this.argv.len) return null;

        const curr = this.argv[this.i];
        const after = if (this.i + 1 < this.argv.len)
            this.argv[this.i + 1]
        else
            null;

        if (this.is_past_dash2) return .{ .pos = curr };

        if (eql(curr, "--")) {
            this.is_past_dash2 = true;
            return this.nextArg();
        }

        if (startsWith(curr, "--"))
            return if (indexOfScalar(curr, '=')) |ieq|
                .{ .name = .{ .name = curr[2..ieq], .value = .{
                    .value = curr[ieq + 1 ..],
                    .is_inline = true,
                    .is_forced = true,
                } } }
            else
                .{ .name = .{ .name = curr[2..], .value = .{
                    .value = after,
                    .is_inline = false,
                    .is_forced = false,
                } } };

        if (curr.len == 0 or curr[0] != '-' or
            curr.len == 1 or !isCode(curr[1]))
            return .{ .pos = curr };

        return this.nextCode();
    }
};

const Param = struct {
    code: []const u8,
    name: []const u8,
    is_pos: bool,
    type_name: []const u8,
    arity: u1,

    // TODO: remove
    pub fn format(
        this: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        return writer.print(
            "Param{{ .code '{s}' .name '{s}', {s}, .type '{s}', .arity {}}}",
            .{
                this.code,
                this.name,
                if (this.is_pos) "pos" else "___",
                this.type_name,
                this.arity,
            },
        );
    }

    pub fn Type(comptime this: Param) type {
        return TypeFromName(this.type_name) catch {
            @compileError(std.fmt.comptimePrint(
                "error: type not found: {s}",
                .{this.type_name},
            ));
        };
    }

    pub fn TypeFromName(name: []const u8) !type {
        const Types = &.{
            .{ "int", isize },
            .{ "uint", usize },
            .{ "float", f64 },
            .{ "str", []const u8 },
        };
        inline for (Types) |t| if (eql(name, t[0])) return t[1];

        if (startsWith(name, "i")) {
            const bits = try std.fmt.parseInt(u16, name[1..], 10);
            return @Type(.{ .int = .{
                .bits = bits,
                .signedness = .signed,
            } });
        }

        if (startsWith(name, "u")) {
            const bits = try std.fmt.parseInt(u16, name[1..], 10);
            return @Type(.{ .int = .{
                .bits = bits,
                .signedness = .unsigned,
            } });
        }

        if (startsWith(name, "f")) {
            const bits = try std.fmt.parseInt(u16, name[1..], 10);
            return @Type(.{ .float = .{
                .bits = bits,
            } });
        }

        return error.NoSuchType;
    }

    pub fn fullName(comptime this: Param) []const u8 {
        return if (this.name.len == 0) this.code else this.name;
    }

    pub fn parse(spec: []const u8) [ParamParser.count(spec)]Param {
        return ParamParser.parseAll(spec);
    }
};

const ParamParser = struct {
    spec: []const u8,
    i: usize,
    param: Param = undefined,

    pub fn parseAll(spec: []const u8) [count(spec)]Param {
        @setEvalBranchQuota(1_000_000);
        var params: [count(spec)]Param = undefined;
        parseIntoSlice(spec, &params);
        return params;
    }

    pub fn parseIntoSlice(spec: []const u8, params: []Param) void {
        var k: usize = 0;
        for (0..spec.len) |i| if (isBegin(spec, i)) {
            var parser = ParamParser{ .spec = spec, .i = i };
            parser.parse() catch {
                const loc = std.zig.findLineColumn(spec, parser.i);
                if (@inComptime())
                    @compileError(std.fmt.comptimePrint(
                        "error:{}:{}: param parse error\n{s}\n",
                        .{ loc.line, loc.column, loc.source_line },
                    ))
                else {
                    std.log.err(
                        "at {}:{}: param parse error",
                        .{ loc.line, loc.column },
                    );
                    std.log.err("{s}", .{loc.source_line});
                    std.process.exit(1);
                }
            };

            params[k] = parser.param;
            k += 1;
        };
    }

    pub fn count(spec: []const u8) usize {
        @setEvalBranchQuota(1_000_000);
        var len: usize = 0;
        for (0..spec.len) |i| len += @intFromBool(isBegin(spec, i));
        return len;
    }

    fn isBegin(spec: []const u8, i: usize) bool {
        const is_line_begin = i == 0 or spec[i - 1] == '\n';

        const trimmed = std.mem.trimLeft(u8, spec[i..], spaces);
        const is_param_begin =
            startsWith(trimmed, "-") or
            startsWith(trimmed, "<");

        return is_line_begin and is_param_begin;
    }

    fn parse(this: *@This()) !void {
        this.param = .{
            .code = "\x00",
            .name = "",
            .is_pos = false,
            .type_name = "uint",
            .arity = 0,
        };

        this.skipSpaces();

        if (try this.parseType()) {
            this.param.is_pos = true;
            this.skipSpaces();
            try this.expectS("[");
            try this.expectName();
            try this.expectS("]");
            return;
        }

        if (this.parseS("--")) {
            try this.expectName();
        } else {
            try this.expectS("-");
            try this.expectCode();

            this.skipSpaces();
            if (this.parseS(",")) {
                this.skipSpaces();

                try this.expectS("--");
                try this.expectName();
            }
        }

        if (this.parseS("="))
            try this.expectType();
    }

    fn expectCode(this: *@This()) !void {
        if (this.i < this.spec.len and isCode(this.spec[this.i])) {
            this.param.code = this.spec[this.i .. this.i + 1];
            this.i += 1;
            return;
        }
        return error.ParseError;
    }

    fn expectName(this: *@This()) !void {
        this.param.name = try this.expectWord();
    }

    fn parseType(this: *@This()) !bool {
        if (!this.parseS("<")) return false;
        this.param.arity = 1;
        this.param.type_name = try this.expectWord();
        try this.expectS(">");
        return true;
    }

    fn expectType(this: *@This()) !void {
        if (!try this.parseType()) return error.ParseError;
    }

    fn expectWord(this: *@This()) ![]const u8 {
        const begin = this.i;
        if (begin < this.spec.len) {
            if (!isWordBegin(this.spec[begin])) return error.ParseError;
            this.i += 1;
        } else return error.ParseError;

        while (this.i < this.spec.len and isWord(this.spec[this.i]))
            this.i += 1;

        return this.spec[begin..this.i];
    }

    fn parseS(this: *@This(), str: []const u8) bool {
        if (startsWith(this.spec[this.i..], str)) {
            this.i += str.len;
            return true;
        }
        return false;
    }

    fn expectS(this: *@This(), str: []const u8) !void {
        if (!this.parseS(str)) return error.ParseError;
    }

    fn skipSpaces(this: *@This()) void {
        this.i = std.mem.indexOfNonePos(u8, this.spec, this.i, spaces) orelse
            this.spec.len;
    }

    const spaces = " \t";
};

fn isCode(char: u8) bool {
    return switch (char) {
        'A'...'Z', 'a'...'z', '_' => true,
        else => false,
    };
}

fn isWordBegin(char: u8) bool {
    return isCode(char) or char == '-';
}

fn isWord(char: u8) bool {
    return isWordBegin(char) or switch (char) {
        '0'...'9' => true,
        else => false,
    };
}

fn indexOfScalar(a: []const u8, b: u8) ?usize {
    return std.mem.indexOfScalar(u8, a, b);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b);
}

const std = @import("std");

// test "argz" {
//     const usage = "-h, --help\n" ++
//         "-a=<u42>";
// const len = ParamParser.count(usage);
// std.debug.print("{} params\n", .{len});
//
// const A = std.heap.smp_allocator;
// var a = try init(A, .{}, usage);
// defer a.deinit();
// const args = try a.parse();
// std.debug.print("{}\n", .{args});
// std.debug.print("typeof a {}\n", .{@TypeOf(args.a)});
// }

const usage =
    \\
    \\Options:
    \\  -h, --help          Print this help and exit.
    \\  -a, --alice=<str>   Alice's name
    \\
    \\Arguments:
    \\  <int>              [count] Number of items.
    \\
;

pub fn main() !void {
    const A = std.heap.smp_allocator;
    var argz = try init(A, .{}, usage);
    defer argz.deinit();
    const argv = try argz.parse();

    const out = std.io.getStdOut().writer();

    if (argv.alice) |alice| {
        try out.print("alice's name is {s}\n", .{alice});
    } else {
        try out.print("alice has no name\n", .{});
    }

    if (argv.count) |count| {
        try out.print("count is {}\n", .{count});
    } else {
        try out.print("no count\n", .{});
    }
}
