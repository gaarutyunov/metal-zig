const std = @import("std");

const Example = struct {
    name: []const u8,
    description: []const u8,
};

const examples = [_]Example{
    .{ .name = "00-window", .description = "Open a window with a Metal view" },
    .{ .name = "01-primitive", .description = "Render a gradient triangle in a window" },
    .{ .name = "02-argbuffers", .description = "Pass vertex data through an argument buffer" },
    .{ .name = "03-animation", .description = "Animate a triangle with per-frame data" },
    .{ .name = "04-instancing", .description = "Draw many quads with instanced rendering" },
    .{ .name = "05-perspective", .description = "Draw cubes with a perspective projection" },
    .{ .name = "06-lighting", .description = "Light the cubes with per-vertex normals" },
    .{ .name = "07-texturing", .description = "Texture the cubes with a checkerboard" },
    .{ .name = "08-compute", .description = "Generate the texture with a compute kernel" },
    .{ .name = "09-compute-to-render", .description = "Animate the compute texture every frame" },
    .{ .name = "10-frame-debugging", .description = "Capture a GPU trace programmatically" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Translate the Objective-C headers into a Zig module. The `.m` extension
    // makes translate-c parse the input as Objective-C, so that `#import` and
    // `@interface`/`@protocol` declarations are understood.
    const objc = b.addTranslateC(.{
        .root_source_file = b.path("src/metal.m"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    // The library, available to other packages as
    // `b.dependency("metal", ...).module("metal")`. It re-exports the
    // translated headers as `objc` and links the frameworks, so importing it
    // is all an executable needs.
    const metal = b.addModule("metal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "objc", .module = objc },
        },
    });
    for ([_][]const u8{ "Metal", "MetalKit", "Foundation", "AppKit", "QuartzCore" }) |framework| {
        metal.linkFramework(framework, .{});
    }
    // Command line tools must link CoreGraphics for
    // MTLCreateSystemDefaultDevice to find a device.
    metal.linkFramework("CoreGraphics", .{});
    metal.linkSystemLibrary("objc", .{});

    const test_step = b.step("test", "Run the unit tests");
    const tests = b.addTest(.{ .root_module = metal });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "metal", .module = metal },
                },
            }),
        });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        run.addPassthruArgs();
        b.step(b.fmt("run-{s}", .{example.name}), example.description).dependOn(&run.step);
    }
}
