const std = @import("std");

const zlib_sources = [_][]const u8{
    "adler32.c", "compress.c", "crc32.c", "deflate.c", "gzclose.c", "gzlib.c", "gzread.c", "gzwrite.c", "infback.c", "inffast.c", "inflate.c", "inftrees.c", "trees.c", "uncompr.c", "zutil.c",
};

pub fn build(b: *std.Build) void {
    const allocator = b.allocator;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;

    const z_lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    var z_lib_flags: std.ArrayList([]const u8) = .empty;
    defer z_lib_flags.deinit(b.allocator);

    z_lib_flags.appendSlice(allocator, &.{
        "-DHAVE_SYS_TYPES_H",
        "-DHAVE_STDINT_H",
        "-DHAVE_STDDEF_H",
    }) catch @panic("OOM");

    if (!is_windows)
        z_lib_flags.append(allocator, "-DZ_HAVE_UNISTD_H") catch @panic("OOM");

    z_lib_mod.addCSourceFiles(.{
        .root = b.path("vendor/zlib-1.3.2"),
        .files = &zlib_sources,
        .flags = z_lib_flags.items,
    });

    z_lib_mod.addIncludePath(b.path("vendor/zlib-1.3.2"));

    const z_lib = b.addLibrary(.{
        .name = "z",
        .linkage = .static,
        .root_module = z_lib_mod,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
    });

    const exe = b.addExecutable(.{
        .name = "gearbox",
        .root_module = root_module,
    });

    root_module.addIncludePath(b.path("vendor/zlib-1.3.2"));
    root_module.linkLibrary(z_lib);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
