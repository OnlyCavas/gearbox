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

const BSIIHeader: []const u8 = "BSII";

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, amount: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, amount) catch return error.OutOfData;
        if (end > self.data.len) return error.OutOfData;

        const data = self.data[self.pos..end];
        self.pos = end;

        return data;
    }

    fn int(self: *Reader, comptime T: type) !T {
        const b = try self.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
    }

    fn float(self: *Reader) !f32 {
        return @bitCast(try self.int(u32));
    }

    fn str(self: *Reader) ![]const u8 {
        const len = try self.int(u32);
        return self.take(len);
    }
};

pub const BSIIEncoder = struct {
    writer: *std.Io.Writer,
    document: *const Document,

    pub fn init(writer: *std.Io.Writer, document: *const Document) BSIIEncoder {
        return .{ .writer = writer, .document = document };
    }

    pub fn encode(self: *BSIIEncoder) !void {
        const document = self.document;
        const writer = self.writer;

        try writer.writeAll(BSIIHeader);
        try writer.writeInt(u32, document.version, .little);

        for (document.blocks.items) |block| {
            switch (block) {
                .def => |sd| try self.writeDefinition(sd),
                .inst => |inst| try self.writeInstance(inst),
            }
        }

        try writer.writeInt(u32, 0, .little);
        try writer.writeInt(u8, 0, .little);
    }

    fn writeDefinition(self: *BSIIEncoder, def: StructDef) !void {
        const writer = self.writer;

        try writer.writeInt(u32, 0, .little); // block_type
        try writer.writeInt(u8, 1, .little); // valid
        try writer.writeInt(u32, def.id, .little); // id
        try self.writeStr(def.name); // name

        for (def.fields) |field| {
            try writer.writeInt(u32, field.ty, .little);
            try self.writeStr(field.name);

            if (field.ty != 0x37 and field.ty != 0x38) continue;

            try writer.writeInt(u32, @intCast(field.enums.len), .little);

            for (field.enums) |entry| {
                try writer.writeInt(u32, entry.value, .little);
                try self.writeStr(entry.name);
            }
        }

        try writer.writeInt(u32, 0, .little);
    }

    fn writeInstance(self: *BSIIEncoder, instance: Instance) !void {
        const writer = self.writer;

        try writer.writeInt(u32, instance.type_id, .little); // block_type
        try self.writeId(instance.id); // id
        for (instance.values) |value| try self.writeValue(value); // write values
    }

    fn writeValue(self: *BSIIEncoder, value: Value) !void {
        const writer = self.writer;

        switch (value) {
            .array => |items| {
                try writer.writeInt(u32, @intCast(items.len), .little);
                for (items) |item| try self.writerScalar(item);
            },
            else => try self.writerScalar(value),
        }
    }

    fn writerScalar(self: *BSIIEncoder, v: Value) !void {
        const writer = self.writer;

        switch (v) {
            .string => |s| try self.writeStr(s),
            .token => |t| try writer.writeInt(u64, t, .little),
            .f32 => |x| try self.writeFloat(x),
            .vec2 => |a| for (a) |x| try self.writeFloat(x),
            .vec3 => |a| for (a) |x| try self.writeFloat(x),
            .vec4 => |a| for (a) |x| try self.writeFloat(x),
            .placement => |a| for (a) |x| try self.writeFloat(x),
            .ivec3 => |a| for (a) |x| try writer.writeInt(i32, x, .little),
            .i32 => |x| try writer.writeInt(i32, x, .little),
            .u32 => |x| try writer.writeInt(u32, x, .little),
            .i16 => |x| try writer.writeInt(i16, x, .little),
            .u16 => |x| try writer.writeInt(u16, x, .little),
            .i64 => |x| try writer.writeInt(i64, x, .little),
            .u64 => |x| try writer.writeInt(u64, x, .little),
            .bool => |x| try writer.writeInt(u8, @intFromBool(x), .little),
            .enumeration => |x| try writer.writeInt(u32, x, .little),
            .id => |i| try self.writeId(i),
            .array => unreachable,
        }
    }

    fn writeId(self: *BSIIEncoder, id: Id) !void {
        const writer = self.writer;

        return switch (id) {
            .nameless => |n| {
                try writer.writeInt(u8, 0xFF, .little);
                try writer.writeInt(u64, n, .little);
            },
            .parts => |parts| {
                try writer.writeInt(u8, @intCast(parts.len), .little);
                for (parts) |p| try writer.writeInt(u64, p, .little);
            },
        };
    }

    fn writeStr(self: *BSIIEncoder, s: []const u8) !void {
        const writer = self.writer;

        try writer.writeInt(u32, @intCast(s.len), .little);
        try writer.writeAll(s);
    }

    fn writeFloat(self: *BSIIEncoder, x: f32) !void {
        const writer = self.writer;
        try writer.writeInt(u32, @bitCast(x), .little);
    }
};

pub const BSIIDecoder = struct {
    reader: Reader,
    document: Document,

    pub const ReadError = error{
        InvalidFileFormat,
        UnknownData,
    };

    pub fn init(allocator: Allocator, data: []const u8) BSIIDecoder {
        return .{
            .reader = .{ .data = data },
            .document = .init(allocator),
        };
    }

    pub fn parse(self: *BSIIDecoder) !Document {
        const reader = &self.reader;
        const header = try reader.take(4);
        if (!std.mem.eql(u8, BSIIHeader, header)) return ReadError.InvalidFileFormat;

        const version = try reader.int(u32);
        if (version != 3) return ReadError.InvalidFileFormat;

        while (reader.pos < reader.data.len) {
            const block_type = try reader.int(u32);

            if (block_type == 0) {
                if (!try self.readDefinition()) break;
            } else try self.readInstance(block_type);
        }

        return self.document;
    }

    fn readDefinition(self: *BSIIDecoder) !bool {
        const reader = &self.reader;

        const valid = try reader.int(u8);
        if (valid == 0) return false;

        const allocator = self.document.alloc();
        const id = try reader.int(u32);
        const name = try allocator.dupe(u8, try reader.str());

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        while (true) {
            const ty = try reader.int(u32);
            if (ty == 0) break;

            const field_name = try allocator.dupe(u8, try reader.str());
            const parsedEnum = try self.readEnum(allocator, ty);

            try fields.append(allocator, .{
                .ty = ty,
                .name = field_name,
                .enums = parsedEnum,
            });
        }

        try self.document.addDef(.{
            .id = id,
            .name = name,
            .fields = try fields.toOwnedSlice(allocator),
        });

        return true;
    }

    fn readEnum(self: *BSIIDecoder, allocator: Allocator, ty: u32) ![]EnumEntry {
        if (ty != 0x37 and ty != 0x38) return &.{};

        var reader = &self.reader;
        var enums: std.ArrayListUnmanaged(EnumEntry) = .empty;
        const num = try reader.int(u32);

        for (0..num) |_| {
            const value = try reader.int(u32);
            const name = try allocator.dupe(u8, try reader.str());
            try enums.append(allocator, .{ .name = name, .value = value });
        }

        return enums.toOwnedSlice(allocator);
    }

    fn readInstance(self: *BSIIDecoder, type_id: u32) !void {
        const def = self.document.defs.get(type_id) orelse return ReadError.UnknownData;

        const id = try self.readId();
        const values = try self.document.alloc().alloc(Value, def.fields.len);

        for (def.fields, values) |f, *slot| {
            slot.* = readValue(self, f.ty) catch |e| {
                std.debug.print("in field '{s}' of '{s}'\n", .{ f.name, def.name });
                return e;
            };
        }

        try self.document.addInstance(.{ .type_id = type_id, .id = id, .values = values });
    }

    fn readValue(self: *BSIIDecoder, ty: u32) !Value {
        if (ty & 1 != 0) return self.readScalar(ty);

        const reader = &self.reader;
        const count = try reader.int(u32);

        if (count > reader.data.len - reader.pos) return ReadError.UnknownData;

        const items = try self.document.alloc().alloc(Value, count);
        for (items) |*item| item.* = try self.readScalar(ty - 1);

        return .{ .array = items };
    }

    fn readScalar(self: *BSIIDecoder, ty: u32) !Value {
        const r = &self.reader;
        return switch (ty) {
            0x01 => .{ .string = try self.document.dupe(try r.str()) },
            0x03 => .{ .token = try r.int(u64) },
            0x05 => .{ .f32 = try r.float() },
            0x07 => .{ .vec2 = try self.floats(2) },
            0x09 => .{ .vec3 = try self.floats(3) },
            0x11 => .{ .ivec3 = .{ try r.int(i32), try r.int(i32), try r.int(i32) } },
            0x17 => .{ .vec4 = try self.floats(4) },
            0x19 => .{ .placement = try self.floats(8) },
            0x25, 0x2f => .{ .i32 = try r.int(i32) },
            0x27 => .{ .u32 = try r.int(u32) },
            0x29 => .{ .i16 = try r.int(i16) },
            0x2b => .{ .u16 = try r.int(u16) },
            0x31 => .{ .i64 = try r.int(i64) },
            0x33 => .{ .u64 = try r.int(u64) },
            0x35 => .{ .bool = (try r.int(u8)) != 0 },
            0x37 => .{ .enumeration = try r.int(u32) },
            0x39, 0x3b, 0x3d => .{ .id = try self.readId() },
            else => {
                std.debug.print("unknown type 0x{x}\n", .{ty});
                return ReadError.UnknownData;
            },
        };
    }

    fn floats(self: *BSIIDecoder, comptime n: usize) ![n]f32 {
        var out: [n]f32 = undefined;
        for (&out) |*x| x.* = try self.reader.float();
        return out;
    }

    fn readId(self: *BSIIDecoder) !Id {
        const parts = try self.reader.int(u8);
        if (parts == 0xFF) return .{ .nameless = try self.reader.int(u64) };

        const toks = try self.document.alloc().alloc(u64, parts);
        for (toks) |*t| t.* = try self.reader.int(u64);
        return .{ .parts = toks };
    }
};
