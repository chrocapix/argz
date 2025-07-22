const usage =
    \\
    \\Options:
    \\ -h, --help          print this help and exit.
    \\ -a
    \\ -b, --bob
    \\ --charlie
    \\ -d=<int>
    \\ -e, --edward=<uint>
    \\ --fabien=<str>       very long very long very long very long very long
    \\                      poeut poeut poeut poeut poeut poeut 
    \\Arguments:
    \\ <uint>              [count] number of items. 
    \\
;

pub fn main() !void {
    var debugA = std.heap.DebugAllocator(.{}).init;
    defer _ = debugA.deinit();
    const A = debugA.allocator();

    var argz = try @import("argz").init(A, .{}, usage);
    defer argz.deinit();
    const argv = try argz.parse();

    const out = std.io.getStdOut().writer();

    try print(out, argv);
}

fn print(w: anytype, x: anytype) !void {
    switch (@typeInfo(@TypeOf(x))) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                try w.print("{s}: {s} = ", .{ field.name, @typeName(field.type) });
                try print(w, @field(x, field.name));
                try w.writeAll("\n");
            }
        },
        .int, .float => {
            try w.print("{}", .{x});
        },
        .optional => {
            if (x) |y|
                try print(w, y)
            else
                try w.print("(null)", .{});
        },
        else => {
            if (@TypeOf(x) == []const u8)
                try w.print("'{s}'", .{x})
            else try w.print("_", .{});
        },
    }
}

const std = @import("std");
