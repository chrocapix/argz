const std = @import("std");

pub fn build(b: *std.Build) void {
    const tgt = b.standardTargetOptions(.{});
    const opt = b.standardOptimizeOption(.{});

    const argz2 = b.addModule("argz", .{
        .target = tgt,
        .optimize = opt,
        .root_source_file = b.path("argz.zig"),
    });

    const example2 = b.addExecutable(.{
        .name = "example",
        .target = tgt,
        .optimize = opt,
        .root_source_file = b.path("example.zig"),
    });
    example2.root_module.addImport("argz", argz2);
    // b.installArtifact(example2);

    // run the CLI tool
    const run_cmd = b.addRunArtifact(example2);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
