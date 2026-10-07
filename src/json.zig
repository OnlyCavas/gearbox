const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;

const Document = ir.Document;
const StructDef = ir.StructDef;
const Field = ir.Field;
const Instance = ir.Instance;
const Value = ir.Value;
const Id = ir.Id;
const EnumEntry = ir.EnumEntry;

pub const JsonDecoder = struct {
    document: Document,
    parsed: std.json.Parsed(std.json.Value),

    pub const JsonDecoderError = error{ MissingField, TypeMismatch };

    pub fn init(allocator: Allocator, data: []const u8) !JsonDecoder {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{
            .allocate = .alloc_if_needed,
        });

        return .{
            .document = .init(allocator),
            .parsed = parsed,
        };
    }

    pub fn deinit(self: *JsonDecoder) void {
        self.parsed.deinit();
    }

    pub fn parse(self: *JsonDecoder) !Document {
        const object = self.parsed.value.object;
        const allocator = self.document.alloc();

        self.document.version = try parseField(u8, allocator, object, "version");

        const blocks_val = object.get("blocks") orelse return JsonDecoderError.MissingField;
        const blocks = switch (blocks_val) {
            .array => |b| b.items,
            else => return JsonDecoderError.TypeMismatch,
        };

        for (blocks) |block_val| {
            const block = switch (block_val) {
                .object => |o| o,
                else => return JsonDecoderError.TypeMismatch,
            };

            if (block.get("kind")) |kind_val| {
                const kind = switch (kind_val) {
                    .string => |s| s,
                    else => return JsonDecoderError.TypeMismatch,
                };

                if (!std.mem.eql(u8, "def", kind)) return JsonDecoderError.MissingField;

                const def = try self.parseDefinition(block);
                try self.document.addDef(def);
            } else {
                const instance = try self.parseInstance(block);
                try self.document.addInstance(instance);
            }
        }

        return self.document;
    }

    fn parseDefinition(self: *JsonDecoder, object: std.json.ObjectMap) !StructDef {
        const allocator = self.document.alloc();

        return .{
            .id = try parseField(u32, allocator, object, "id"),
            .name = try parseField([]const u8, allocator, object, "name"),
            .fields = try parseField([]const Field, allocator, object, "fields"),
        };
    }

    fn parseInstance(self: *JsonDecoder, object: std.json.ObjectMap) !Instance {
        const allocator = self.document.alloc();

        const type_id = try parseField(u32, allocator, object, "type_id");
        const def = self.document.defs.get(type_id) orelse return JsonDecoderError.MissingField;

        const values_val = object.get("values") orelse return JsonDecoderError.MissingField;
        const value_object = switch (values_val) {
            .object => |o| o,
            else => return JsonDecoderError.TypeMismatch,
        };

        const values = try allocator.alloc(Value, def.fields.len);
        for (def.fields, values) |field, *pos| {
            const v = value_object.get(field.name) orelse return JsonDecoderError.MissingField;
            pos.* = try parseTyped(allocator, field.ty, field.enums, v);
        }

        return .{
            .type_id = type_id,
            .id = try parseField(Id, allocator, object, "id"),
            .values = values,
        };
    }

    fn parseTyped(a: Allocator, ty: u32, enums: []const EnumEntry, v: std.json.Value) anyerror!Value {
        if (ty & 1 != 0) return parseScalar(a, ty, enums, v);

        const items = switch (v) {
            .array => |arr| arr.items,
            else => return JsonDecoderError.TypeMismatch,
        };

        const out = try a.alloc(Value, items.len);
        for (items, out) |item, *o| o.* = try parseScalar(a, ty - 1, enums, item);
        return .{ .array = out };
    }

    fn parseScalar(a: Allocator, ty: u32, enums: []const EnumEntry, v: std.json.Value) !Value {
        return switch (ty) {
            0x01 => .{ .string = try parseValue([]const u8, a, v) },
            0x03 => .{ .token = try tokenValue(try parseValue([]const u8, a, v)) },
            0x05 => .{ .f32 = try parseValue(f32, a, v) },
            0x07 => .{ .vec2 = try parseValue([2]f32, a, v) },
            0x09 => .{ .vec3 = try parseValue([3]f32, a, v) },
            0x11 => .{ .ivec3 = try parseValue([3]i32, a, v) },
            0x17 => .{ .vec4 = try parseValue([4]f32, a, v) },
            0x19 => .{ .placement = try parseValue([8]f32, a, v) },
            0x25, 0x2f => .{ .i32 = try parseValue(i32, a, v) },
            0x27 => .{ .u32 = try parseValue(u32, a, v) },
            0x29 => .{ .i16 = try parseValue(i16, a, v) },
            0x2b => .{ .u16 = try parseValue(u16, a, v) },
            0x31 => .{ .i64 = try parseValue(i64, a, v) },
            0x33 => .{ .u64 = try parseValue(u64, a, v) },
            0x35 => .{ .bool = try parseValue(bool, a, v) },
            0x37 => blk: {
                if (v == .string) {
                    for (enums) |e| if (std.mem.eql(u8, e.name, v.string))
                        break :blk .{ .enumeration = e.value };
                    return JsonDecoderError.TypeMismatch;
                }
                break :blk .{ .enumeration = try parseValue(u32, a, v) };
            },
            0x39, 0x3b, 0x3d => .{ .id = try parseId(a, v) },
            else => error.UnknownData,
        };
    }

    fn parseId(a: Allocator, value: std.json.Value) anyerror!Id {
        switch (value) {
            .string => |s| return parseIdString(a, s),
            .object => |o| {
                if (o.get("nameless")) |n| return .{ .nameless = try parseValue(u64, a, n) };
                if (o.get("parts")) |p| return .{ .parts = try parseValue([]const u64, a, p) };
                return JsonDecoderError.MissingField;
            },
            else => return JsonDecoderError.TypeMismatch,
        }
    }

    fn parseIdString(a: Allocator, s: []const u8) !Id {
        const prefix = "_nameless.";
        if (std.mem.startsWith(u8, s, prefix))
            return .{ .nameless = try std.fmt.parseInt(u64, s[prefix.len..], 16) };

        if (s.len == 0) return .{ .parts = &.{} };

        var parts: std.ArrayListUnmanaged(u64) = .empty;
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |p| try parts.append(a, try tokenValue(p));
        return .{ .parts = try parts.toOwnedSlice(a) };
    }

    fn tokenValue(text: []const u8) !u64 {
        const table = "0123456789abcdefghijklmnopqrstuvwxyz_";
        var v: u64 = 0;
        var i = text.len;
        while (i > 0) {
            i -= 1;
            const idx = std.mem.indexOfScalar(u8, table, text[i]) orelse return error.InvalidToken;
            v = v * 38 + (idx + 1);
        }
        return v;
    }

    fn parseField(comptime T: type, allocator: Allocator, object: std.json.ObjectMap, key: []const u8) !T {
        const value = object.get(key) orelse return JsonDecoderError.MissingField;
        return try parseValue(T, allocator, value);
    }

    fn parseValue(comptime T: type, allocator: Allocator, value: std.json.Value) !T {
        if (T == Id) return parseId(allocator, value);

        return switch (@typeInfo(T)) {
            .int => switch (value) {
                .integer => |i| std.math.cast(T, i) orelse JsonDecoderError.TypeMismatch,
                .string, .number_string => |s| return std.fmt.parseInt(T, s, 10),
                else => return JsonDecoderError.TypeMismatch,
            },
            .float => switch (value) {
                .float => |f| return @floatCast(f),
                .integer => |n| return @floatFromInt(n),
                .number_string, .string => |s| return std.fmt.parseFloat(T, s),
                else => return JsonDecoderError.TypeMismatch,
            },
            .bool => switch (value) {
                .bool => |b| b,
                else => return JsonDecoderError.TypeMismatch,
            },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) {
                    return switch (value) {
                        .string => |s| try allocator.dupe(u8, s),
                        else => return JsonDecoderError.TypeMismatch,
                    };
                }

                const items = switch (value) {
                    .array => |arr| arr.items,
                    else => return JsonDecoderError.TypeMismatch,
                };

                const out = try allocator.alloc(p.child, items.len);
                for (items, out) |item, *o| o.* = try parseValue(p.child, allocator, item);
                return out;
            },
            .array => |a| {
                const items = switch (value) {
                    .array => |arr| arr.items,
                    else => return JsonDecoderError.TypeMismatch,
                };

                if (a.len != items.len) return JsonDecoderError.TypeMismatch;

                var out: T = undefined;
                for (items, &out) |item, *o| o.* = try parseValue(a.child, allocator, item);
                return out;
            },
            .@"struct" => |s| {
                const obj = switch (value) {
                    .object => |o| o,
                    else => return JsonDecoderError.TypeMismatch,
                };

                var out: T = undefined;

                inline for (s.fields) |field| {
                    if (obj.get(field.name)) |v| {
                        @field(out, field.name) = try parseValue(field.type, allocator, v);
                    } else if (field.defaultValue()) |default| {
                        @field(out, field.name) = default;
                    } else return JsonDecoderError.TypeMismatch;
                }

                return out;
            },
            else => @compileError("unsupported type " ++ @typeName(T)),
        };
    }
};

pub const JsonEncoder = struct {
    js: std.json.Stringify,
    document: *const Document,

    pub fn init(writer: *std.Io.Writer, document: *const Document) JsonEncoder {
        return .{
            .js = std.json.Stringify{
                .writer = writer,
                .options = .{ .whitespace = .indent_2 },
            },
            .document = document,
        };
    }

    pub fn encode(self: *JsonEncoder, allocator: Allocator) !void {
        const js = &self.js;

        try js.beginObject();
        try js.objectField("version");
        try js.write(self.document.version);

        try js.objectField("blocks");
        try js.beginArray();
        for (self.document.blocks.items) |block| switch (block) {
            .def => |d| try self.writeDefinition(d),
            .inst => |i| try self.writeInstance(allocator, i),
        };
        try js.endArray();

        try js.endObject();
    }

    fn writeDefinition(self: *JsonEncoder, d: StructDef) !void {
        const js = &self.js;

        try js.beginObject();

        try js.objectField("kind");
        try js.write("def");

        try js.objectField("id");
        try js.write(d.id);

        try js.objectField("name");
        try js.write(d.name);

        try js.objectField("fields");
        try js.write(d.fields);

        try js.endObject();
    }

    fn writeInstance(self: *JsonEncoder, allocator: Allocator, instance: Instance) !void {
        const js = &self.js;
        const def = self.document.defOf(instance) orelse return error.UnknownData;

        try js.beginObject();

        try js.objectField("type_id");
        try js.write(instance.type_id);

        try js.objectField("id");
        try js.write(instance.id);

        try js.objectField("values");
        try js.beginObject();
        for (def.fields, instance.values) |field, value| {
            try js.objectField(field.name);
            try self.writeValue(allocator, value, field.enums);
        }
        try js.endObject();

        try js.endObject();
    }

    fn writeValue(self: *JsonEncoder, gpa: Allocator, v: Value, enums: []const EnumEntry) anyerror!void {
        const js = &self.js;

        switch (v) {
            .string => |s| try js.write(s),
            .token => |t| {
                var buf: [16]u8 = undefined;
                try js.write(tokenText(&buf, t));
            },
            .i64 => |x| {
                var buf: [24]u8 = undefined;
                try js.write(try std.fmt.bufPrint(&buf, "{d}", .{x}));
            },
            .u64 => |x| {
                var buf: [24]u8 = undefined;
                try js.write(try std.fmt.bufPrint(&buf, "{d}", .{x}));
            },
            .f32 => |x| try js.write(x),
            .i32 => |x| try js.write(x),
            .u32 => |x| try js.write(x),
            .i16 => |x| try js.write(x),
            .u16 => |x| try js.write(x),
            .bool => |x| try js.write(x),
            .vec2 => |x| try js.write(x),
            .vec3 => |x| try js.write(x),
            .vec4 => |x| try js.write(x),
            .ivec3 => |x| try js.write(x),
            .placement => |x| try js.write(x),
            .enumeration => |n| {
                for (enums) |e| if (e.value == n) return js.write(e.name);
                try js.write(n);
            },
            .id => |id| try self.writeId(gpa, id),
            .array => |items| {
                try js.beginArray();
                for (items) |item| try self.writeValue(gpa, item, enums);
                try js.endArray();
            },
        }
    }

    fn writeId(self: *JsonEncoder, gpa: Allocator, id: Id) !void {
        const js = &self.js;

        var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
        defer alloc_writer.deinit();
        const writer = &alloc_writer.writer;

        switch (id) {
            .nameless => |n| try writer.print("_nameless.{x}", .{n}),
            .parts => |parts| for (parts, 0..) |p, i| {
                if (i != 0) try writer.writeByte('.');
                var buf: [16]u8 = undefined;
                try writer.writeAll(tokenText(&buf, p));
            },
        }
        try js.write(alloc_writer.written());
    }

    fn tokenText(buf: *[16]u8, value: u64) []const u8 {
        const table = "0123456789abcdefghijklmnopqrstuvwxyz_";
        var v = value;
        var n: usize = 0;
        while (v != 0) : (n += 1) {
            const d: usize = @intCast(v % 38);
            v /= 38;
            buf[n] = if (d >= 1 and d <= table.len) table[d - 1] else '?';
        }
        return buf[0..n];
    }
};
