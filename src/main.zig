const std = @import("std");
const builtin = @import("builtin");

const Style = @import("styles.zig").Style;
const Io = std.Io;

const cli = @import("cli.zig");
const Parser = cli.Parser;

fn message(err: anyerror) []const u8 {
    return switch (err) {
        error.NoOp => "no operation given",
        error.InvalidOptions => "unknown option",
        error.DuplicateOperation => "more than one operation given",
        error.DuplicateModifier => "modifier given twice",
        error.MissingArgument => "modifier needs an argument",
        error.UnsupportedModifier => "modifier not supported by this operation",
        error.MissingModifier => "choose an input format: json or bsii",
        error.ConflictingModifiers => "json and bsii cannot be combined",
        error.MissingFile => "no input file, use: file PATH",
        else => @errorName(err),
    };
}

fn print(io: std.Io, style: Style, err: anytype) !u8 {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;

    try style.paint(stdout, Style.red, "gearbox", .{});
    try stdout.print(": {s}\n", .{message(err)});

    try style.paint(stdout, Style.dim, "Try ", .{});
    try style.paint(stdout, Style.cyan, "'gearbox --help' or 'gearbox help' or 'gearbox h'", .{});
    try style.paint(stdout, Style.dim, " for more information\n", .{});

    try stdout.flush();
    return 1;
}

pub fn main(init: std.process.Init) !u8 {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = debug_alloc.deinit();
    };

    const allocator = if (builtin.mode == .Debug)
        debug_alloc.allocator()
    else
        std.heap.smp_allocator;

    const style: Style = .detect(
        Io.File.stderr().isTty(init.io) catch false,
        false,
    );

    var parser: Parser = try .init(init.minimal.args, allocator);
    const cmd = parser.parse() catch |err| {
        return switch (err) {
            error.NoOp => {
                _ = try cli.printHelp(init.io);
                return 1;
            },
            else => try print(init.io, style, err),
        };
    };

    return cmd.run(.{
        .io = init.io,
        .allocator = allocator,
        .style = style,
    }) catch |err| try print(init.io, style, err);
}
