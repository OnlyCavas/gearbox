const std = @import("std");
const bsii = @import("../bsii.zig");
const json = @import("../json.zig");
const crypto = @import("../crypto.zig");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const JDecoder = json.JsonDecoder;
const JEncoder = json.JsonEncoder;

const BDecoder = bsii.BSIIDecoder;
const BEncoder = bsii.BSIIEncoder;

const Document = @import("../ir.zig").Document;

const Env = parser.Env;
const Ctx = parser.Ctx;
const OperationError = parser.OperationError;
const Modifier = parser.Modifier;
const Style = @import("../styles.zig").Style;

const MAX_INPUT = 256 * 1024 * 1024;

const Kind = enum {
    json,
    bsii,
    sii,

    fn fromModifier(m: Modifier) ?Kind {
        return switch (m) {
            .json => .json,
            .bsii => .bsii,
            else => null,
        };
    }

    fn detect(content: []const u8, path: []const u8) ?Kind {
        if (std.mem.startsWith(u8, content, "ScsC")) return .sii;
        if (std.mem.startsWith(u8, content, "BSII")) return .bsii;

        const ext = std.fs.path.extension(path);

        if (std.ascii.eqlIgnoreCase(ext, ".json")) return .json;
        if (std.ascii.eqlIgnoreCase(ext, ".sii")) return .sii;
        if (std.ascii.eqlIgnoreCase(ext, ".bsii")) return .bsii;

        return null;
    }
};

const Loaded = struct {
    document: Document,
    iv: ?[16]u8 = null,
    hmac: ?[32]u8 = null,

    fn deinit(self: *Loaded) void {
        self.document.deinit();
    }

    fn getIv(self: Loaded, io: Io) [16]u8 {
        _ = self;
        var iv: [16]u8 = undefined;
        io.random(&iv);
        return iv;
    }

    fn getHmac(self: Loaded) [32]u8 {
        return self.hmac orelse @splat(0);
    }
};

fn decodeBSII(allocator: Allocator, bytes: []const u8) !Document {
    var decoder: BDecoder = .init(allocator, bytes);
    return decoder.parse();
}

fn load(allocator: Allocator, kind: Kind, content: []const u8) !Loaded {
    switch (kind) {
        .sii => {
            const text = try crypto.decrypt(allocator, content);
            defer text.deinit(allocator);

            return .{
                .document = try decodeBSII(allocator, text.bytes),
                .iv = text.iv,
                .hmac = text.hmac,
            };
        },
        .bsii => return .{ .document = try decodeBSII(allocator, content) },
        .json => {
            var decoder: JDecoder = try .init(allocator, content);
            defer decoder.deinit();

            return .{ .document = try decoder.parse() };
        },
    }
}

fn dump(allocator: Allocator, kind: Kind, loaded: *const Loaded) ![]u8 {
    var writer_alloc: Io.Writer.Allocating = .init(allocator);
    defer writer_alloc.deinit();
    const writer = &writer_alloc.writer;

    switch (kind) {
        .json => {
            var encoder: JEncoder = .init(writer, &loaded.document);
            try encoder.encode(allocator);
        },
        .bsii => {
            var encoder: BEncoder = .init(writer, &loaded.document);
            try encoder.encode();
        },
        else => unreachable,
    }

    return writer_alloc.toOwnedSlice();
}

pub fn run(ctx: Ctx, env: Env) !u8 {
    const io = env.io;
    const allocator = env.allocator;
    const style = env.style;

    const out_kind = Kind.fromModifier(try ctx.exactlyOne(&.{ .json, .bsii })).?;
    const path = try ctx.require(.file, OperationError.MissingArgument);

    const cwd: Io.Dir = .cwd();
    const content = try cwd.readFileAlloc(io, path, allocator, .limited(MAX_INPUT));
    defer allocator.free(content);

    const in_kind = Kind.detect(content, path) orelse return error.UnsupportedFileFormat;

    var loaded = try load(allocator, in_kind, content);
    defer loaded.deinit();

    const out = try dump(allocator, out_kind, &loaded);
    defer allocator.free(out);

    const out_path = try std.fmt.allocPrint(allocator, "out.{s}", .{@tagName(out_kind)});
    defer allocator.free(out_path);

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = out });

    var buf: [512]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &buf);
    const stdout = &stderr_writer.interface;

    try style.paint(stdout, Style.green, "✔ ", .{});
    try style.paint(stdout, Style.bold, "converted ", .{});
    try stdout.print("{s} ({t}) → {s} ", .{ path, in_kind, out_path });
    try style.paint(stdout, Style.dim, "{d} → {d} bytes\n", .{ content.len, out.len });
    try stdout.flush();

    return 0;
}
