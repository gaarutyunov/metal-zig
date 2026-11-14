//! Port of the metal-cpp "10-frame-debugging" sample: the animated cubes of
//! 09-compute-to-render, with a programmatic GPU frame capture. A frame is
//! captured to a `.gputrace` document in the temporary directory, which is
//! then opened (in Xcode), either from the Capture menu (Cmd-C) or
//! automatically after three seconds.
//!
//! Capturing requires `MetalCaptureEnabled` in the app's Info.plist, or the
//! `METAL_CAPTURE_ENABLED=1` environment variable for a plain executable like
//! this one, which `main` sets.
const std = @import("std");
const objc = @import("metal");
const common = @import("common");
const util = common.util;
const math = common.math;
const f3 = math.f3;

const max_frames_in_flight = 3;
const instance_rows = 10;
const instance_columns = 10;
const instance_depth = 10;
const num_instances = instance_rows * instance_columns * instance_depth;
const depth_pixel_format = objc.MTLPixelFormatDepth16Unorm;
const texture_width = 128;
const texture_height = 128;
const auto_capture_timeout_secs = 3;

/// Set from the Capture menu to capture the next frame.
var begin_capture = false;

const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct v2f {
    \\    float4 position [[position]];
    \\    float3 normal;
    \\    half3 color;
    \\    float2 texcoord;
    \\};
    \\
    \\struct VertexData {
    \\    float3 position;
    \\    float3 normal;
    \\    float2 texcoord;
    \\};
    \\
    \\struct InstanceData {
    \\    float4x4 instanceTransform;
    \\    float3x3 instanceNormalTransform;
    \\    float4 instanceColor;
    \\};
    \\
    \\struct CameraData {
    \\    float4x4 perspectiveTransform;
    \\    float4x4 worldTransform;
    \\    float3x3 worldNormalTransform;
    \\};
    \\
    \\v2f vertex vertexMain(device const VertexData* vertexData [[buffer(0)]],
    \\                      device const InstanceData* instanceData [[buffer(1)]],
    \\                      device const CameraData& cameraData [[buffer(2)]],
    \\                      uint vertexId [[vertex_id]],
    \\                      uint instanceId [[instance_id]]) {
    \\    v2f o;
    \\
    \\    const device VertexData& vd = vertexData[vertexId];
    \\    float4 pos = float4(vd.position, 1.0);
    \\    pos = instanceData[instanceId].instanceTransform * pos;
    \\    pos = cameraData.perspectiveTransform * cameraData.worldTransform * pos;
    \\    o.position = pos;
    \\
    \\    float3 normal = instanceData[instanceId].instanceNormalTransform * vd.normal;
    \\    normal = cameraData.worldNormalTransform * normal;
    \\    o.normal = normal;
    \\
    \\    o.color = half3(instanceData[instanceId].instanceColor.rgb);
    \\    o.texcoord = vd.texcoord.xy;
    \\    return o;
    \\}
    \\
    \\half4 fragment fragmentMain(v2f in [[stage_in]], texture2d<half, access::sample> tex [[texture(0)]]) {
    \\    constexpr sampler s(address::repeat, filter::linear);
    \\    half3 texel = tex.sample(s, in.texcoord).rgb;
    \\
    \\    // assume light coming from (front-top-right)
    \\    float3 l = normalize(float3(1.0, 1.0, 0.8));
    \\    float3 n = normalize(in.normal);
    \\
    \\    half ndotl = half(saturate(dot(n, l)));
    \\
    \\    half3 illum = (in.color * texel * 0.1) + (in.color * texel * ndotl);
    \\    return half4(illum, 1.0);
    \\}
;

const kernel_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\kernel void mandelbrot_set(texture2d<half, access::write> tex [[texture(0)]],
    \\                           uint2 index [[thread_position_in_grid]],
    \\                           uint2 gridSize [[threads_per_grid]],
    \\                           device const uint* frame [[buffer(0)]]) {
    \\    constexpr float kAnimationFrequency = 0.01;
    \\    constexpr float kAnimationSpeed = 4;
    \\    constexpr float kAnimationScaleLow = 0.62;
    \\    constexpr float kAnimationScale = 0.38;
    \\
    \\    constexpr float2 kMandelbrotPixelOffset = {-0.2, -0.35};
    \\    constexpr float2 kMandelbrotOrigin = {-1.2, -0.32};
    \\    constexpr float2 kMandelbrotScale = {2.2, 2.0};
    \\
    \\    // Map time to zoom value in [kAnimationScaleLow, 1]
    \\    float zoom = kAnimationScaleLow + kAnimationScale * cos(kAnimationFrequency * *frame);
    \\    // Speed up zooming
    \\    zoom = pow(zoom, kAnimationSpeed);
    \\
    \\    // Scale
    \\    float x0 = zoom * kMandelbrotScale.x * ((float)index.x / gridSize.x + kMandelbrotPixelOffset.x) + kMandelbrotOrigin.x;
    \\    float y0 = zoom * kMandelbrotScale.y * ((float)index.y / gridSize.y + kMandelbrotPixelOffset.y) + kMandelbrotOrigin.y;
    \\
    \\    // Implement Mandelbrot set
    \\    float x = 0.0;
    \\    float y = 0.0;
    \\    uint iteration = 0;
    \\    uint max_iteration = 1000;
    \\    float xtmp = 0.0;
    \\    while (x * x + y * y <= 4 && iteration < max_iteration) {
    \\        xtmp = x * x - y * y + x0;
    \\        y = 2 * x * y + y0;
    \\        x = xtmp;
    \\        iteration += 1;
    \\    }
    \\
    \\    // Convert iteration result to colors
    \\    half color = (0.5 + 0.5 * cos(3.0 + iteration * 0.15));
    \\    tex.write(half4(color, color, color, 1.0), index, 0);
    \\}
;

const VertexData = extern struct {
    position: math.float3,
    normal: math.float3,
    texcoord: math.float2,
};

const InstanceData = extern struct {
    transform: math.float4x4,
    normal_transform: math.float3x3,
    color: math.float4,
};

const CameraData = extern struct {
    perspective: math.float4x4,
    world: math.float4x4,
    world_normal: math.float3x3,
};

fn v(position: math.float3, normal: math.float3, texcoord: math.float2) VertexData {
    return .{ .position = position, .normal = normal, .texcoord = texcoord };
}

const f2 = math.f2;

const s = 0.5;
const vertices = [_]VertexData{
    // Positions         Normals          Texture coordinates
    v(f3(-s, -s, s), f3(0, 0, 1), f2(0, 1)),
    v(f3(s, -s, s), f3(0, 0, 1), f2(1, 1)),
    v(f3(s, s, s), f3(0, 0, 1), f2(1, 0)),
    v(f3(-s, s, s), f3(0, 0, 1), f2(0, 0)),

    v(f3(s, -s, s), f3(1, 0, 0), f2(0, 1)),
    v(f3(s, -s, -s), f3(1, 0, 0), f2(1, 1)),
    v(f3(s, s, -s), f3(1, 0, 0), f2(1, 0)),
    v(f3(s, s, s), f3(1, 0, 0), f2(0, 0)),

    v(f3(s, -s, -s), f3(0, 0, -1), f2(0, 1)),
    v(f3(-s, -s, -s), f3(0, 0, -1), f2(1, 1)),
    v(f3(-s, s, -s), f3(0, 0, -1), f2(1, 0)),
    v(f3(s, s, -s), f3(0, 0, -1), f2(0, 0)),

    v(f3(-s, -s, -s), f3(-1, 0, 0), f2(0, 1)),
    v(f3(-s, -s, s), f3(-1, 0, 0), f2(1, 1)),
    v(f3(-s, s, s), f3(-1, 0, 0), f2(1, 0)),
    v(f3(-s, s, -s), f3(-1, 0, 0), f2(0, 0)),

    v(f3(-s, s, s), f3(0, 1, 0), f2(0, 1)),
    v(f3(s, s, s), f3(0, 1, 0), f2(1, 1)),
    v(f3(s, s, -s), f3(0, 1, 0), f2(1, 0)),
    v(f3(-s, s, -s), f3(0, 1, 0), f2(0, 0)),

    v(f3(-s, -s, -s), f3(0, -1, 0), f2(0, 1)),
    v(f3(s, -s, -s), f3(0, -1, 0), f2(1, 1)),
    v(f3(s, -s, s), f3(0, -1, 0), f2(1, 0)),
    v(f3(-s, -s, s), f3(0, -1, 0), f2(0, 0)),
};
const indices = [_]u16{
    0, 1, 2, 2, 3, 0, // front
    4, 5, 6, 6, 7, 4, // right
    8, 9, 10, 10, 11, 8, // back
    12, 13, 14, 14, 15, 12, // left
    16, 17, 18, 18, 19, 16, // top
    20, 21, 22, 22, 23, 20, // bottom
};

const Renderer = struct {
    device: *objc.MTLDevice,
    command_queue: *objc.MTLCommandQueue,
    pipeline: *objc.MTLRenderPipelineState,
    depth_stencil_state: *objc.MTLDepthStencilState,
    vertex_buffer: *objc.MTLBuffer,
    index_buffer: *objc.MTLBuffer,
    texture: *objc.MTLTexture,
    compute_pipeline: *objc.MTLComputePipelineState,
    texture_animation: *objc.MTLBuffer,
    animation_index: u32 = 0,
    start_time: objc.time_t,
    has_captured: bool = false,
    capturing: bool = false,
    trace_path: [std.fs.max_path_bytes:0]u8 = undefined,
    instance_data: [max_frames_in_flight]*objc.MTLBuffer,
    camera_data: [max_frames_in_flight]*objc.MTLBuffer,
    semaphore: util.FrameSemaphore,
    angle: f32 = 0,
    frame: usize = 0,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        const library = try util.newLibrary(device, shader_source);
        defer common.release(library);

        var instance_data: [max_frames_in_flight]*objc.MTLBuffer = undefined;
        for (&instance_data) |*buffer| buffer.* = try util.newBuffer(device, num_instances * @sizeOf(InstanceData));
        var camera_data: [max_frames_in_flight]*objc.MTLBuffer = undefined;
        for (&camera_data) |*buffer| buffer.* = try util.newBuffer(device, @sizeOf(CameraData));

        return .{
            .device = device,
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .pipeline = try util.newRenderPipeline(device, library, .{ .depth_pixel_format = depth_pixel_format }),
            .depth_stencil_state = try buildDepthStencilState(device),
            .vertex_buffer = try util.newBufferWithData(device, &vertices),
            .index_buffer = try util.newBufferWithData(device, &indices),
            .texture = try buildTexture(device),
            .compute_pipeline = try buildComputePipeline(device),
            .texture_animation = try util.newBuffer(device, @sizeOf(u32)),
            .instance_data = instance_data,
            .camera_data = camera_data,
            .semaphore = .init(max_frames_in_flight),
            .start_time = objc.time(null),
        };
    }

    fn buildComputePipeline(device: *objc.MTLDevice) !*objc.MTLComputePipelineState {
        const library = try util.newLibrary(device, kernel_source);
        defer common.release(library);
        const mandelbrot_fn = try util.newFunction(library, "mandelbrot_set");
        defer common.release(mandelbrot_fn);

        var err: ?*objc.NSError = null;
        return device.newComputePipelineStateWithFunction_error(mandelbrot_fn, &err) orelse
            util.fail("creating the compute pipeline", err);
    }

    fn buildDepthStencilState(device: *objc.MTLDevice) !*objc.MTLDepthStencilState {
        const desc = objc.MTLDepthStencilDescriptor.alloc().?.init().?;
        defer common.release(desc);
        desc.setDepthCompareFunction(objc.MTLCompareFunctionLess);
        desc.setDepthWriteEnabled(1);
        return device.newDepthStencilStateWithDescriptor(desc) orelse error.NoDepthStencilState;
    }

    /// A texture for the compute kernel to write and the fragment shader to
    /// sample.
    fn buildTexture(device: *objc.MTLDevice) !*objc.MTLTexture {
        const desc = objc.MTLTextureDescriptor.alloc().?.init().?;
        defer common.release(desc);
        desc.setWidth(texture_width);
        desc.setHeight(texture_height);
        desc.setPixelFormat(objc.MTLPixelFormatRGBA8Unorm);
        desc.setTextureType(objc.MTLTextureType2D);
        desc.setStorageMode(objc.MTLStorageModeManaged);
        desc.setUsage(objc.MTLResourceUsageSample | objc.MTLResourceUsageRead | objc.MTLResourceUsageWrite);

        return device.newTextureWithDescriptor(desc) orelse error.NoTexture;
    }

    /// Encodes the compute kernel over every pixel of the texture, for the
    /// next animation frame.
    fn generateMandelbrotTexture(r: *Renderer, cmd: *objc.MTLCommandBuffer) void {
        util.contents(u32, r.texture_animation).* = r.animation_index % 5000;
        r.animation_index +%= 1;
        util.didModify(r.texture_animation);

        const encoder = cmd.computeCommandEncoder() orelse return;
        encoder.setComputePipelineState(r.compute_pipeline);
        encoder.setTexture_atIndex(r.texture, 0);
        encoder.setBuffer_offset_atIndex(r.texture_animation, 0, 0);

        const grid_size: objc.MTLSize = .{ .width = texture_width, .height = texture_height, .depth = 1 };
        const threadgroup_size: objc.MTLSize = .{ .width = r.compute_pipeline.maxTotalThreadsPerThreadgroup(), .height = 1, .depth = 1 };
        encoder.dispatchThreads_threadsPerThreadgroup(grid_size, threadgroup_size);

        encoder.as(objc.MTLCommandEncoder).endEncoding();
    }

    /// Starts capturing the commands sent to the device into a GPU trace
    /// document.
    fn triggerCapture(r: *Renderer) !void {
        const capture_manager = objc.MTLCaptureManager.sharedCaptureManager().?;
        if (capture_manager.supportsDestination(objc.MTLCaptureDestinationGPUTraceDocument) == 0) {
            std.log.err("capture support is not enabled", .{});
            return error.CaptureNotSupported;
        }

        var filename: [64:0]u8 = undefined;
        const now = objc.time(null);
        const len = objc.strftime(&filename, filename.len, "capture-%H-%M-%S_%m-%d-%y.gputrace", objc.localtime(&now));
        filename[len] = 0;
        const path = objc.NSTemporaryDirectory().?.stringByAppendingString(objc.NSString.stringWithUTF8String(&filename)).?;
        const path_utf8 = util.zigString(path);
        if (path_utf8.len >= r.trace_path.len) return error.NameTooLong;
        @memcpy(r.trace_path[0..path_utf8.len], path_utf8);
        r.trace_path[path_utf8.len] = 0;

        const url = objc.NSURL.alloc().?.initFileURLWithPath(path).?;
        defer common.release(url);

        const desc = objc.MTLCaptureDescriptor.alloc().?.init().?;
        defer common.release(desc);
        desc.setDestination(objc.MTLCaptureDestinationGPUTraceDocument);
        desc.setOutputURL(url);
        desc.setCaptureObject(@ptrCast(@alignCast(r.device)));

        var err: ?*objc.NSError = null;
        if (capture_manager.startCaptureWithDescriptor_error(desc, &err) == 0) {
            std.log.err("failed to start capture: \"{s}\" for file \"{s}\"", .{
                if (err) |e| util.zigString(e.localizedDescription()) else "unknown error",
                path_utf8,
            });
            return error.CaptureFailed;
        }
        r.capturing = true;
    }

    /// Stops the capture and opens the trace document.
    fn finishCapture(r: *Renderer) void {
        objc.MTLCaptureManager.sharedCaptureManager().?.stopCapture();
        r.capturing = false;

        const path = std.mem.sliceTo(&r.trace_path, 0);
        std.log.info("captured a GPU trace to {s}", .{path});
        var command: [std.fs.max_path_bytes + 16:0]u8 = undefined;
        const open_command = std.fmt.bufPrintSentinel(&command, "open '{s}'", .{path}, 0) catch return;
        _ = objc.system(open_command.ptr);
    }

    pub fn deinit(r: *Renderer) void {
        // Wait for the frames in flight before releasing their resources.
        r.semaphore.deinit();
        for (r.camera_data) |buffer| common.release(buffer);
        for (r.instance_data) |buffer| common.release(buffer);
        common.release(r.texture_animation);
        common.release(r.compute_pipeline);
        common.release(r.texture);
        common.release(r.index_buffer);
        common.release(r.vertex_buffer);
        common.release(r.depth_stencil_state);
        common.release(r.pipeline);
        common.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        if (begin_capture) {
            r.triggerCapture() catch {
                begin_capture = false;
                r.has_captured = true;
            };
        }

        r.frame = (r.frame + 1) % max_frames_in_flight;
        const instance_buffer = r.instance_data[r.frame];
        const camera_buffer = r.camera_data[r.frame];

        const cmd = r.command_queue.commandBuffer() orelse return;
        r.semaphore.wait();
        r.semaphore.signalOnCompletion(cmd);

        r.angle += 0.002;
        updateInstances(util.contentsSlice(InstanceData, instance_buffer), r.angle);
        util.didModify(instance_buffer);

        const world = math.identity();
        util.contents(CameraData, camera_buffer).* = .{
            .perspective = math.perspective(45.0 * std.math.pi / 180.0, 1.0, 0.03, 500.0),
            .world = world,
            .world_normal = math.discardTranslation(world),
        };
        util.didModify(camera_buffer);

        // Update the texture before the render pass samples it.
        r.generateMandelbrotTexture(cmd);

        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse {
            cmd.commit();
            return;
        };
        encoder.setRenderPipelineState(r.pipeline);
        encoder.setDepthStencilState(r.depth_stencil_state);
        encoder.setVertexBuffer_offset_atIndex(r.vertex_buffer, 0, 0);
        encoder.setVertexBuffer_offset_atIndex(instance_buffer, 0, 1);
        encoder.setVertexBuffer_offset_atIndex(camera_buffer, 0, 2);
        encoder.setFragmentTexture_atIndex(r.texture, 0);
        encoder.setCullMode(objc.MTLCullModeBack);
        encoder.setFrontFacingWinding(objc.MTLWindingCounterClockwise);
        encoder.drawIndexedPrimitives_indexCount_indexType_indexBuffer_indexBufferOffset_instanceCount(
            objc.MTLPrimitiveTypeTriangle,
            indices.len,
            objc.MTLIndexTypeUInt16,
            r.index_buffer,
            0,
            num_instances,
        );
        encoder.as(objc.MTLCommandEncoder).endEncoding();

        if (view.currentDrawable()) |drawable| cmd.presentDrawable(drawable.as(objc.MTLDrawable));
        cmd.commit();

        if (begin_capture) {
            if (r.capturing) r.finishCapture();
            begin_capture = false;
            r.has_captured = true;
        }

        // Automatically trigger a capture if the user has not used the menu
        // to trigger one.
        if (!r.has_captured and objc.time(null) - r.start_time > auto_capture_timeout_secs) {
            begin_capture = true;
        }
    }
};

/// Lays the cubes out in a grid, spinning individually and as a whole.
fn updateInstances(instances: []InstanceData, a: f32) void {
    const scl = 0.2;
    const object_position: math.Vec3 = .{ 0, 0, -10 };
    const full_object_rot = math.mulAll(&.{
        math.translate(object_position),
        math.rotateY(-a),
        math.rotateX(a * 0.5),
        math.translate(-object_position),
    });

    for (instances[0..num_instances], 0..) |*instance, i| {
        const ix: f32 = @floatFromInt(i % instance_rows);
        const iy: f32 = @floatFromInt((i / instance_rows) % instance_columns);
        const iz: f32 = @floatFromInt(i / (instance_rows * instance_columns));

        const x = (ix - instance_rows / 2.0) * (2.0 * scl) + scl;
        const y = (iy - instance_columns / 2.0) * (2.0 * scl) + scl;
        const z = (iz - instance_depth / 2.0) * (2.0 * scl);
        const transform = math.mulAll(&.{
            full_object_rot,
            math.translate(object_position + math.Vec3{ x, y, z }),
            math.rotateY(a * @cos(iy)),
            math.rotateZ(a * @sin(ix)),
            math.scale(@splat(scl)),
        });

        const t = @as(f32, @floatFromInt(i)) / num_instances;
        instance.* = .{
            .transform = transform,
            .normal_transform = math.discardTranslation(transform),
            .color = math.f4(t, 1.0 - t, @sin(std.math.pi * 2.0 * t), 1.0),
        };
    }
}

fn beginCapture() void {
    begin_capture = true;
}

pub fn main() !void {
    // Enable GPU capture without an Info.plist with `MetalCaptureEnabled`.
    _ = objc.setenv("METAL_CAPTURE_ENABLED", "1", 1);

    try common.app.run(Renderer, .{
        .title = "10 - Programmatic GPU Capture",
        .menu = .{ .title = "Capture", .item_title = "Begin Capture", .key = "c", .action = &beginCapture },
        .clear_color = .{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 },
        .depth_stencil_pixel_format = depth_pixel_format,
    });
}
