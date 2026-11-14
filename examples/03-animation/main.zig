// Copyright 2022 Apple Inc.
// Copyright 2026 German Arutyunov
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Ported to Zig from Apple's LearnMetalCPP sample code, and modified.

//! Port of the metal-cpp "03-animation" sample: the triangle of
//! 02-argbuffers, rotated by an angle that the CPU updates every frame.
//!
//! The per-frame data lives in one buffer per frame in flight, so that the CPU
//! never writes a buffer that the GPU is still reading. A semaphore, signalled
//! from the command buffer's completion handler, limits the frames in flight.
const metal = @import("metal");
const objc = metal.objc;
const math = metal.math;
const f3 = math.f3;

const max_frames_in_flight = 3;

const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct v2f {
    \\    float4 position [[position]];
    \\    half3 color;
    \\};
    \\
    \\struct VertexData {
    \\    device float3* positions [[id(0)]];
    \\    device float3* colors [[id(1)]];
    \\};
    \\
    \\struct FrameData {
    \\    float angle;
    \\};
    \\
    \\v2f vertex vertexMain(device const VertexData* vertexData [[buffer(0)]],
    \\                      constant FrameData* frameData [[buffer(1)]],
    \\                      uint vertexId [[vertex_id]]) {
    \\    float a = frameData->angle;
    \\    float3x3 rotationMatrix = float3x3(sin(a), cos(a), 0.0, cos(a), -sin(a), 0.0, 0.0, 0.0, 1.0);
    \\    v2f o;
    \\    o.position = float4(rotationMatrix * vertexData->positions[vertexId], 1.0);
    \\    o.color = half3(vertexData->colors[vertexId]);
    \\    return o;
    \\}
    \\
    \\half4 fragment fragmentMain(v2f in [[stage_in]]) {
    \\    return half4(in.color, 1.0);
    \\}
;

const FrameData = extern struct {
    angle: f32,
};

const positions = [_]math.float3{ f3(-0.8, 0.8, 0.0), f3(0.0, -0.8, 0.0), f3(0.8, 0.8, 0.0) };
const colors = [_]math.float3{ f3(1.0, 0.3, 0.2), f3(0.8, 1.0, 0.0), f3(0.8, 0.0, 1.0) };

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,
    library: *objc.MTLLibrary,
    pipeline: *objc.MTLRenderPipelineState,
    positions: *objc.MTLBuffer,
    colors: *objc.MTLBuffer,
    arg_buffer: *objc.MTLBuffer,
    frame_data: [max_frames_in_flight]*objc.MTLBuffer,
    semaphore: metal.FrameSemaphore,
    angle: f32 = 0,
    frame: usize = 0,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        const library = try metal.newLibrary(device, shader_source);
        const positions_buffer = try metal.newBufferWithData(device, &positions);
        const colors_buffer = try metal.newBufferWithData(device, &colors);

        var frame_data: [max_frames_in_flight]*objc.MTLBuffer = undefined;
        for (&frame_data) |*buffer| buffer.* = try metal.newBuffer(device, @sizeOf(FrameData));

        return .{
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .library = library,
            .pipeline = try metal.newRenderPipeline(device, library, .{}),
            .positions = positions_buffer,
            .colors = colors_buffer,
            .arg_buffer = try buildArgBuffer(device, library, positions_buffer, colors_buffer),
            .frame_data = frame_data,
            .semaphore = .init(max_frames_in_flight),
        };
    }

    fn buildArgBuffer(
        device: *objc.MTLDevice,
        library: *objc.MTLLibrary,
        positions_buffer: *objc.MTLBuffer,
        colors_buffer: *objc.MTLBuffer,
    ) !*objc.MTLBuffer {
        const vertex_fn = try metal.newFunction(library, "vertexMain");
        defer metal.release(vertex_fn);
        const arg_encoder = vertex_fn.newArgumentEncoderWithBufferIndex(0) orelse return error.NoArgumentEncoder;
        defer metal.release(arg_encoder);

        const arg_buffer = try metal.newBuffer(device, arg_encoder.encodedLength());
        arg_encoder.setArgumentBuffer_offset(arg_buffer, 0);
        arg_encoder.setBuffer_offset_atIndex(positions_buffer, 0, 0);
        arg_encoder.setBuffer_offset_atIndex(colors_buffer, 0, 1);
        metal.didModify(arg_buffer);
        return arg_buffer;
    }

    pub fn deinit(r: *Renderer) void {
        // Wait for the frames in flight before releasing their resources.
        r.semaphore.deinit();
        for (r.frame_data) |buffer| metal.release(buffer);
        metal.release(r.arg_buffer);
        metal.release(r.colors);
        metal.release(r.positions);
        metal.release(r.pipeline);
        metal.release(r.library);
        metal.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        r.frame = (r.frame + 1) % max_frames_in_flight;
        const frame_data_buffer = r.frame_data[r.frame];

        const cmd = r.command_queue.commandBuffer() orelse return;
        r.semaphore.wait();
        r.semaphore.signalOnCompletion(cmd);

        r.angle += 0.01;
        metal.contents(FrameData, frame_data_buffer).angle = r.angle;
        metal.didModify(frame_data_buffer);

        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse {
            cmd.commit();
            return;
        };
        encoder.setRenderPipelineState(r.pipeline);
        encoder.setVertexBuffer_offset_atIndex(r.arg_buffer, 0, 0);
        encoder.useResource_usage(r.positions.as(objc.MTLResource), objc.MTLResourceUsageRead);
        encoder.useResource_usage(r.colors.as(objc.MTLResource), objc.MTLResourceUsageRead);
        encoder.setVertexBuffer_offset_atIndex(frame_data_buffer, 0, 1);
        encoder.drawPrimitives_vertexStart_vertexCount(objc.MTLPrimitiveTypeTriangle, 0, positions.len);
        encoder.as(objc.MTLCommandEncoder).endEncoding();

        if (view.currentDrawable()) |drawable| cmd.presentDrawable(drawable.as(objc.MTLDrawable));
        cmd.commit();
    }
};

pub fn main() !void {
    try metal.app.run(Renderer, .{ .title = "03 - Animation" });
}
