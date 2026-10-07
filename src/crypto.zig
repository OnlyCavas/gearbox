const c = @cImport(@cInclude("zlib.h"));

const std = @import("std");
const aes = std.crypto.core.aes;

const Allocator = std.mem.Allocator;

const KEY = blk: {
    var out: [32]u8 = undefined;

    _ = std.fmt.hexToBytes(&out, "2a5fcb1791d22fb60245b3d8369ed0b2c27371563fbf1f3c9edf6b11825a5d0a") catch unreachable;

    break :blk out;
};

fn zlibInflate(allocator: Allocator, compressed: []const u8, plain_len: usize) ![]u8 {
    const max_size = 256 * 1024 * 1024;
    if (plain_len > max_size) return error.ToLarge;

    const buf = try allocator.alloc(u8, plain_len);
    errdefer allocator.free(buf);

    var dest_len: c_ulong = @intCast(plain_len);
    const rc = c.uncompress(buf.ptr, &dest_len, compressed.ptr, @intCast(compressed.len));
    if (rc != c.Z_OK) return error.InflateFailed;
    if (dest_len != plain_len) return error.SizeMismatch;

    return buf;
}

pub const Decrypted = struct {
    bytes: []u8,
    iv: [16]u8,
    hmac: [32]u8,

    pub fn deinit(self: Decrypted, allocator: Allocator) void {
        allocator.free(self.bytes);
    }
};

pub fn decrypt(allocator: Allocator, data: []const u8) !Decrypted {
    if (!std.mem.eql(u8, data[0..4], "ScsC")) return error.InvalidFormat;

    const iv: [16]u8 = data[36..52].*;
    const hmac: [32]u8 = data[4..36].*;
    const plain_text_size = std.mem.readInt(u32, data[52..56], .little);

    const ciphertext = data[56..];
    if (ciphertext.len == 0 or ciphertext.len % 16 != 0) return error.InvalidCiphertext;

    const ciphertext_alloc = try allocator.alloc(u8, ciphertext.len);
    defer allocator.free(ciphertext_alloc);

    const aes_ctx = aes.Aes256.initDec(KEY);

    var prev: [16]u8 = iv[0..16].*;
    var i: usize = 0;

    while (i < ciphertext.len) : (i += 16) {
        const block = ciphertext[i..][0..16];

        var out: [16]u8 = undefined;
        aes_ctx.decrypt(&out, block);

        for (&out, prev) |*o, p| o.* ^= p;
        @memcpy(ciphertext_alloc[i..][0..16], &out);
        prev = block.*;
    }

    const pad = ciphertext_alloc[ciphertext_alloc.len - 1];
    if (pad < 1 or pad > 16) return error.BadPadding;
    const compressed = ciphertext_alloc[0 .. ciphertext_alloc.len - pad];

    const inflated = try zlibInflate(allocator, compressed, plain_text_size);

    if (inflated.len != plain_text_size) {
        allocator.free(inflated);
        return error.SizeMismatch;
    }

    return .{ .bytes = inflated, .iv = iv, .hmac = hmac };
}
