const Io = @import("std").Io;

pub const Style = struct {
    enabled: bool,

    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31;1m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const cyan = "\x1b[36m";

    pub fn detect(stderr_is_tty: bool, no_color_set: bool) Style {
        return .{ .enabled = stderr_is_tty and !no_color_set };
    }

    pub fn paint(
        self: Style,
        w: *Io.Writer,
        code: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (self.enabled) try w.writeAll(code);
        try w.print(fmt, args);
        if (self.enabled) try w.writeAll(reset);
    }
};
