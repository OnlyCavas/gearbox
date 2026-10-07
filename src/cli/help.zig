const std = @import("std");
const parser = @import("parser.zig");

const Env = parser.Env;
const Operation = parser.Operation;
const Modifier = parser.Modifier;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ctx = @import("parser.zig").Ctx;

pub fn printHelp(io: Io) !u8 {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &buffer);
    const writer = &stdout_writer.interface;

    try writer.writeAll(
        \\Usage: gearbox <operation> [modifiers]
        \\
        \\operations:
        \\
    );

    inline for (@typeInfo(Operation).@"enum".fields) |f| {
        const op = @field(Operation, f.name);
        try writer.print("  -{c}, --{s:<8} {s}\n", .{ f.name[0], f.name, op.summary() });
    }

    try writer.writeAll("\nmodifiers:\n");
    inline for (@typeInfo(Modifier).@"enum".fields) |f| {
        const m = @field(Modifier, f.name);
        try writer.print("  -{c}, --{s:<8} {s:<5} {s}\n", .{ f.name[0], f.name, m.argName(), m.summary() });
    }

    try writer.writeAll(
        \\
        \\Short flags can be clustered and take their arguments in letter order:
        \\
        \\  gearbox convert bsii file save.sii
        \\  gearbox -c -b -f save.sii
        \\  gearbox cbf save.sii
        \\  gearbox --convert --bsii --file save.sii
        \\
        \\The result is written to out.json or out.bsii in the current directory.
        \\
    );

    try writer.flush();
    return 0;
}

pub fn run(ctx: Ctx, env: Env) !u8 {
    _ = ctx;
    return printHelp(env.io);
}
