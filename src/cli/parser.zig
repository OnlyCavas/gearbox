const std = @import("std");
const convert = @import("convert.zig");
const help = @import("help.zig");

const Style = @import("../styles.zig").Style;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Arg = std.process.Args;

pub const Ctx = struct {
    mods: std.EnumSet(Modifier) = .initEmpty(),
    args: std.EnumArray(Modifier, ?[]const u8) = .initFill(null),

    pub fn has(self: Ctx, m: Modifier) bool {
        return self.mods.contains(m);
    }

    pub fn arg(self: Ctx, m: Modifier) ?[]const u8 {
        return self.args.get(m);
    }

    pub fn require(self: Ctx, m: Modifier, comptime err: anyerror) ![]const u8 {
        return self.arg(m) orelse err;
    }

    pub fn argOr(self: Ctx, m: Modifier, default: []const u8) []const u8 {
        return self.arg(m) orelse default;
    }

    pub fn hasAny(self: Ctx, ms: []const Modifier) bool {
        for (ms) |m| if (self.has(m)) return true;
        return false;
    }

    pub fn countOf(self: Ctx, ms: []const Modifier) usize {
        var n: usize = 0;
        for (ms) |m| {
            if (self.has(m)) n += 1;
        }
        return n;
    }

    pub fn exactlyOne(self: Ctx, ms: []const Modifier) !Modifier {
        var found: ?Modifier = null;

        for (ms) |m| {
            if (!self.has(m)) continue;
            if (found != null) return error.ConflictingModifiers;
            found = m;
        }

        return found orelse error.MissingModifier;
    }
};

pub const Env = struct {
    io: Io,
    allocator: Allocator,
    style: Style,
};

pub const Command = struct {
    op: Operation,
    ctx: Ctx,

    pub const CommandError = error{
        UnsupportedModifier,
    };

    pub fn run(self: Command, env: Env) !u8 {
        const unsupported = self.ctx.mods.differenceWith(self.op.allowed());
        if (unsupported.count() != 0) return CommandError.UnsupportedModifier;
        return self.op.run(self.ctx, env);
    }
};

pub const Modifier = enum {
    json,
    bsii,
    file,

    pub fn summary(self: Modifier) []const u8 {
        return switch (self) {
            .json => "output is JSON",
            .bsii => "output is BSII",
            .file => "input file",
        };
    }

    pub fn argName(self: Modifier) []const u8 {
        return switch (self) {
            .file => "PATH",
            .json, .bsii => "",
        };
    }
    pub fn takesArg(self: Modifier) bool {
        return switch (self) {
            .file => true,
            .json, .bsii => false,
        };
    }
};

pub const OperationError = error{
    MissingArgument,
};

pub const Operation = enum {
    convert,
    help,

    pub fn summary(self: Operation) []const u8 {
        return switch (self) {
            .convert => "convert a file between BSII and JSON",
            .help => "show this help",
        };
    }

    fn allowed(self: Operation) std.EnumSet(Modifier) {
        return switch (self) {
            .convert => .initMany(&.{ .json, .bsii, .file }),
            .help => .initEmpty(),
        };
    }

    fn run(self: Operation, ctx: Ctx, env: Env) !u8 {
        return switch (self) {
            .convert => convert.run(ctx, env),
            .help => help.run(ctx, env),
        };
    }
};

const Item = union(enum) {
    op: Operation,
    mod: Modifier,
};

pub const Parser = struct {
    argInterator: Arg.Iterator,
    operation: ?Operation = null,
    mods: std.EnumSet(Modifier) = .initEmpty(),
    args: std.EnumArray(Modifier, ?[]const u8) = .initFill(null),

    pub const ParserError = error{
        InvalidOptions,
        NoOp,
        DuplicateOperation,
        DuplicateModifier,
        MissingArgument,
    };

    pub fn init(args: Arg, allocator: Allocator) !Parser {
        var iter = try std.process.Args.iterateAllocator(args, allocator);
        _ = iter.next();

        return .{ .argInterator = iter };
    }

    fn parseLong(entry: []const u8) ?Item {
        if (std.meta.stringToEnum(Operation, entry)) |op| return .{ .op = op };
        if (std.meta.stringToEnum(Modifier, entry)) |mod| return .{ .mod = mod };
        return null;
    }

    fn parseShort(comptime T: type, opt: u8) ?T {
        const info = @typeInfo(T);

        if (info != .@"enum") @compileError("expected an enum, but got " ++ @typeName(T));

        inline for (info.@"enum".fields) |field| {
            if (field.name[0] == opt) return @field(T, field.name);
        }

        return null;
    }

    fn parseShortItem(c: u8) ?Item {
        if (parseShort(Operation, c)) |op| return .{ .op = op };
        if (parseShort(Modifier, c)) |mod| return .{ .mod = mod };
        return null;
    }

    fn registerItem(self: *Parser, item: Item) !void {
        return switch (item) {
            .op => |op| {
                if (self.operation != null) return ParserError.DuplicateOperation;
                self.operation = op;
            },
            .mod => |mod| {
                if (self.mods.contains(mod)) return ParserError.DuplicateModifier;
                self.mods.insert(mod);

                if (mod.takesArg()) {
                    const value = self.argInterator.next() orelse return ParserError.MissingArgument;
                    self.args.set(mod, value);
                }
            },
        };
    }

    pub fn parse(self: *Parser) !Command {
        while (self.argInterator.next()) |arg| {
            if (self.operation == .help) break;

            const item = blk: {
                if (std.mem.startsWith(u8, arg, "--"))
                    break :blk parseLong(arg[2..]) orelse return ParserError.InvalidOptions;

                if (!std.mem.startsWith(u8, arg, "-"))
                    if (parseLong(arg)) |long| break :blk long;

                const token = token: {
                    if (std.mem.startsWith(u8, arg, "-")) {
                        break :token arg[1..];
                    }
                    break :token arg;
                };

                for (token) |t| {
                    const item = parseShortItem(t) orelse return ParserError.InvalidOptions;
                    try self.registerItem(item);
                }

                break :blk null; // cluster: items already registered above
            } orelse continue;

            try self.registerItem(item);
        }

        return .{
            .op = self.operation orelse return ParserError.NoOp,
            .ctx = .{
                .mods = self.mods,
                .args = self.args,
            },
        };
    }
};
