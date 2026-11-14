//! Looks up the GPU devices available to Metal, using the native MetalKit
//! headers translated to Zig by translate-c.
const std = @import("std");
const metal = @import("metal");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    // `MTLCreateSystemDefaultDevice` returns `id<MTLDevice>`, which
    // translate-c exposes as a pointer to the `MTLDevice` protocol type.
    const device = metal.MTLCreateSystemDefaultDevice() orelse {
        try out.writeAll("No Metal GPU device found\n");
        try out.flush();
        return error.NoMetalDevice;
    };
    try out.writeAll("Default Metal device:\n");
    try printDevice(out, device);

    // All devices: `NSArray<id<MTLDevice>> *`.
    if (metal.MTLCopyAllDevices()) |devices| {
        const count = devices.count();
        try out.print("\nAll Metal devices ({d}):\n", .{count});
        for (0..count) |i| {
            const obj = devices.objectAtIndex(@intCast(i));
            try printDevice(out, @ptrCast(obj));
        }
        // `release` is declared by the `NSObject` protocol; `as` casts to it.
        devices.as(metal.NSObjectProtocol).release();
    }

    // A class method on a MetalKit class, to show that MetalKit was
    // imported: `+[MTKTextureLoader alloc]` / `-initWithDevice:`.
    if (metal.MTKTextureLoader.alloc()) |loader_alloc| {
        if (loader_alloc.initWithDevice(device)) |loader| {
            const loader_device = loader.device() orelse unreachable;
            try out.print("\nMTKTextureLoader created for '{s}'\n", .{nsString(loader_device.name())});
            loader.as(metal.NSObjectProtocol).release();
        }
    }

    try out.flush();
}

fn printDevice(out: *std.Io.Writer, device: *metal.MTLDevice) !void {
    const max_threads = device.maxThreadsPerThreadgroup();
    try out.print(
        \\  name:                   {s}
        \\  registry id:            0x{x}
        \\  low power:              {}
        \\  headless:               {}
        \\  unified memory:         {}
        \\  max working set:        {d} MiB
        \\  max threads/group:      {d}x{d}x{d}
        \\  max buffer length:      {d} MiB
        \\
    , .{
        nsString(device.name()),
        device.registryID(),
        device.isLowPower() != 0,
        device.isHeadless() != 0,
        device.hasUnifiedMemory() != 0,
        device.recommendedMaxWorkingSetSize() / (1024 * 1024),
        max_threads.width,
        max_threads.height,
        max_threads.depth,
        device.maxBufferLength() / (1024 * 1024),
    });
}

fn nsString(str: ?*metal.NSString) []const u8 {
    const s = str orelse return "(null)";
    return std.mem.span(s.UTF8String() orelse return "(null)");
}
