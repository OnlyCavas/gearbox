const std = @import("std");

const Allocator = std.mem.Allocator;

pub const EnumEntry = struct { value: u32, name: []const u8 };

pub const Field = struct {
    ty: u32,
    name: []const u8,
    enums: []const EnumEntry = &.{},
};

pub const StructDef = struct {
    id: u32,
    name: []const u8,
    fields: []const Field,
};

pub const Id = union(enum) {
    nameless: u64,
    parts: []const u64,
};

pub const Value = union(enum) {
    string: []const u8,
    token: u64,
    f32: f32,
    i32: i32,
    u32: u32,
    i16: i16,
    u16: u16,
    i64: i64,
    u64: u64,
    bool: bool,
    vec2: [2]f32,
    vec3: [3]f32,
    vec4: [4]f32,
    ivec3: [3]i32,
    placement: [8]f32,
    enumeration: u32,
    id: Id,
    array: []Value,
};

pub const Instance = struct {
    type_id: u32,
    id: Id,
    values: []Value,
};

pub const Block = union(enum) {
    def: StructDef,
    inst: Instance,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    version: u32 = 3,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    defs: std.AutoHashMapUnmanaged(u32, StructDef) = .empty,

    pub fn init(gpa: Allocator) Document {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *Document) Allocator {
        return self.arena.allocator();
    }

    pub fn dupe(self: *Document, s: []const u8) ![]const u8 {
        return self.alloc().dupe(u8, s);
    }

    pub fn addDef(self: *Document, def: StructDef) !void {
        try self.defs.put(self.alloc(), def.id, def);
        try self.blocks.append(self.alloc(), .{ .def = def });
    }

    pub fn addInstance(self: *Document, inst: Instance) !void {
        try self.blocks.append(self.alloc(), .{ .inst = inst });
    }

    pub fn defOf(self: *const Document, inst: Instance) ?StructDef {
        return self.defs.get(inst.type_id);
    }

    pub fn defByName(self: *const Document, name: []const u8) ?StructDef {
        var it = self.defs.valueIterator();

        while (it.next()) |d| {
            if (std.mem.eql(u8, d.name, name)) return d.*;
        }

        return null;
    }

    pub fn field(self: *const Document, inst: *Instance, name: []const u8) ?*Value {
        const def = self.defOf(inst.*) orelse return null;

        for (def.fields, inst.values) |f, *v| {
            if (std.mem.eql(u8, f.name, name)) return v;
        }

        return null;
    }
};
