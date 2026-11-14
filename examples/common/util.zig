//! Small helpers for the Objective-C and Metal APIs translated by translate-c.
const std = @import("std");
const objc = @import("metal");

/// An `NSString` from a string literal. The string is autoreleased.
pub fn nsString(comptime str: [:0]const u8) ?*objc.NSString {
    return objc.NSString.stringWithUTF8String(str);
}

/// The UTF-8 contents of an `NSString`.
pub fn zigString(str: ?*objc.NSString) []const u8 {
    const s = str orelse return "(null)";
    return std.mem.span(s.UTF8String() orelse return "(null)");
}

/// Sends `release` (declared by the `NSObject` protocol) to any object.
pub fn release(obj: anytype) void {
    const ptr = switch (@typeInfo(@TypeOf(obj))) {
        .optional => obj orelse return,
        else => obj,
    };
    ptr.as(objc.NSObjectProtocol).release();
}

/// Logs an `NSError` and returns `error.Metal`.
pub fn fail(what: []const u8, err: ?*objc.NSError) error{Metal} {
    const description = if (err) |e| zigString(e.localizedDescription()) else "unknown error";
    std.log.err("{s}: {s}", .{ what, description });
    return error.Metal;
}

/// Compiles Metal Shading Language source into a library.
pub fn newLibrary(device: *objc.MTLDevice, comptime source: [:0]const u8) !*objc.MTLLibrary {
    var err: ?*objc.NSError = null;
    return device.newLibraryWithSource_options_error(nsString(source), null, &err) orelse
        fail("compiling shaders", err);
}

pub fn newFunction(library: *objc.MTLLibrary, comptime name: [:0]const u8) !*objc.MTLFunction {
    return library.newFunctionWithName(nsString(name)) orelse {
        std.log.err("no function '{s}' in the shader library", .{name});
        return error.Metal;
    };
}

pub const RenderPipelineOptions = struct {
    vertex_function: [:0]const u8 = "vertexMain",
    fragment_function: [:0]const u8 = "fragmentMain",
    color_pixel_format: objc.MTLPixelFormat = objc.MTLPixelFormatBGRA8Unorm_sRGB,
    depth_pixel_format: objc.MTLPixelFormat = objc.MTLPixelFormatInvalid,
};

/// Creates a render pipeline from a vertex and a fragment function.
pub fn newRenderPipeline(
    device: *objc.MTLDevice,
    library: *objc.MTLLibrary,
    comptime options: RenderPipelineOptions,
) !*objc.MTLRenderPipelineState {
    const vertex_fn = try newFunction(library, options.vertex_function);
    defer release(vertex_fn);
    const fragment_fn = try newFunction(library, options.fragment_function);
    defer release(fragment_fn);

    const desc = objc.MTLRenderPipelineDescriptor.alloc().?.init().?;
    defer release(desc);
    desc.setVertexFunction(vertex_fn);
    desc.setFragmentFunction(fragment_fn);
    desc.colorAttachments().?.objectAtIndexedSubscript(0).?.setPixelFormat(options.color_pixel_format);
    desc.setDepthAttachmentPixelFormat(options.depth_pixel_format);

    var err: ?*objc.NSError = null;
    return device.newRenderPipelineStateWithDescriptor_error(desc, &err) orelse
        fail("creating the render pipeline", err);
}

/// A managed buffer of `len` bytes.
pub fn newBuffer(device: *objc.MTLDevice, len: usize) !*objc.MTLBuffer {
    return device.newBufferWithLength_options(len, objc.MTLResourceStorageModeManaged) orelse
        error.NoBuffer;
}

/// A managed buffer holding a copy of `data`.
pub fn newBufferWithData(device: *objc.MTLDevice, data: anytype) !*objc.MTLBuffer {
    const bytes = std.mem.sliceAsBytes(data);
    return device.newBufferWithBytes_length_options(bytes.ptr, bytes.len, objc.MTLResourceStorageModeManaged) orelse
        error.NoBuffer;
}

/// The contents of a buffer, as a pointer to `T`.
pub fn contents(comptime T: type, buffer: *objc.MTLBuffer) *T {
    return @ptrCast(@alignCast(buffer.contents().?));
}

/// The contents of a buffer, as a slice of `T`.
pub fn contentsSlice(comptime T: type, buffer: *objc.MTLBuffer) []T {
    const ptr: [*]T = @ptrCast(@alignCast(buffer.contents().?));
    return ptr[0 .. buffer.length() / @sizeOf(T)];
}

/// Tells Metal that the CPU modified the whole of a managed buffer.
pub fn didModify(buffer: *objc.MTLBuffer) void {
    buffer.didModifyRange(.{ .location = 0, .length = buffer.length() });
}

/// Limits the number of frames the CPU prepares ahead of the GPU, like the
/// `dispatch_semaphore_t` and completion handler in the metal-cpp samples.
pub const FrameSemaphore = struct {
    semaphore: objc.dispatch_semaphore_t,
    max_frames_in_flight: isize,

    pub fn init(max_frames_in_flight: isize) FrameSemaphore {
        return .{
            .semaphore = objc.dispatch_semaphore_create(max_frames_in_flight),
            .max_frames_in_flight = max_frames_in_flight,
        };
    }

    /// Waits for the frames in flight to complete, and releases the
    /// semaphore.
    pub fn deinit(self: FrameSemaphore) void {
        // libdispatch crashes when a semaphore is released with a lower
        // count than it was created with, so give the slots back.
        for (0..@intCast(self.max_frames_in_flight)) |_| self.wait();
        for (0..@intCast(self.max_frames_in_flight)) |_| _ = objc.dispatch_semaphore_signal(self.semaphore);
        release(self.semaphore);
    }

    /// Waits until fewer than `max_frames_in_flight` frames are in flight.
    pub fn wait(self: FrameSemaphore) void {
        _ = objc.dispatch_semaphore_wait(self.semaphore, objc.DISPATCH_TIME_FOREVER);
    }

    /// Signals the semaphore when the GPU has completed `cmd`.
    pub fn signalOnCompletion(self: FrameSemaphore, cmd: *objc.MTLCommandBuffer) void {
        // `addCompletedHandler:` takes an Objective-C block, which
        // translate-c exposes as an opaque pointer. Build a block literal
        // following the Clang block ABI: like the one Clang emits for
        // `^(id<MTLCommandBuffer>) { dispatch_semaphore_signal(sem); }`, it
        // lives on the stack and `addCompletedHandler:` copies it to the heap
        // with `Block_copy`.
        var block: SignalBlock = .{
            .isa = @ptrCast(&objc._NSConcreteStackBlock),
            .flags = 0,
            .invoke = &SignalBlock.signal,
            .descriptor = &SignalBlock.block_descriptor,
            .semaphore = self.semaphore,
        };
        cmd.addCompletedHandler(@ptrCast(&block));
    }

    const SignalBlock = extern struct {
        isa: ?*anyopaque,
        flags: c_int,
        reserved: c_int = 0,
        invoke: *const fn (*SignalBlock, ?*objc.MTLCommandBuffer) callconv(.c) void,
        descriptor: *const BlockDescriptor,
        // Captured variables.
        semaphore: objc.dispatch_semaphore_t,

        const block_descriptor: BlockDescriptor = .{ .size = @sizeOf(SignalBlock) };

        fn signal(block: *SignalBlock, _: ?*objc.MTLCommandBuffer) callconv(.c) void {
            _ = objc.dispatch_semaphore_signal(block.semaphore);
        }
    };

    const BlockDescriptor = extern struct {
        reserved: c_ulong = 0,
        size: c_ulong,
    };
};
