const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Translate the Objective-C MetalKit headers into a Zig module. The `.m`
    // extension makes translate-c parse the input as Objective-C, so that
    // `#import` and `@interface`/`@protocol` declarations are understood.
    const metal = b.addTranslateC(.{
        .root_source_file = b.path("src/metal.m"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "metal-triangle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "metal", .module = metal.createModule() },
            },
        }),
    });
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("MetalKit", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    // Command line tools must link CoreGraphics for MTLCreateSystemDefaultDevice
    // to find a device.
    exe.root_module.linkFramework("CoreGraphics", .{});
    exe.root_module.linkSystemLibrary("objc", .{});
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the triangle example").dependOn(&run.step);
}
