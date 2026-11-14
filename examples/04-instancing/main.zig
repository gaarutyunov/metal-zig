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

//! Port of the metal-cpp "04-instancing" sample: a row of quads drawn with a
//! single instanced draw call, with a per-instance transform and color that
//! the CPU animates every frame.
const std = @import("std");
const metal = @import("metal");
const objc = metal.objc;
const math = metal.math;
const f3 = math.f3;

const max_frames_in_flight = 3;
const num_instances = 32;

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
    \\    float3 position;
    \\};
    \\
    \\struct InstanceData {
    \\    float4x4 instanceTransform;
    \\    float4 instanceColor;
    \\};
    \\
    \\v2f vertex vertexMain(device const VertexData* vertexData [[buffer(0)]],
    \\                      device const InstanceData* instanceData [[buffer(1)]],
    \\                      uint vertexId [[vertex_id]],
    \\                      uint instanceId [[instance_id]]) {
    \\    v2f o;
    \\    float4 pos = float4(vertexData[vertexId].position, 1.0);
    \\    o.position = instanceData[instanceId].instanceTransform * pos;
    \\    o.color = half3(instanceData[instanceId].instanceColor.rgb);
    \\    return o;
    \\}
    \\
    \\half4 fragment fragmentMain(v2f in [[stage_in]]) {
    \\    return half4(in.color, 1.0);
    \\}
;

const InstanceData = extern struct {
    transform: math.float4x4,
    color: math.float4,
};

const s = 0.5;
const vertices = [_]math.float3{ f3(-s, -s, s), f3(s, -s, s), f3(s, s, s), f3(-s, s, s) };
const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,
    pipeline: *objc.MTLRenderPipelineState,
    vertex_buffer: *objc.MTLBuffer,
    index_buffer: *objc.MTLBuffer,
    instance_data: [max_frames_in_flight]*objc.MTLBuffer,
    semaphore: metal.FrameSemaphore,
    angle: f32 = 0,
    frame: usize = 0,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        const library = try metal.newLibrary(device, shader_source);
        defer metal.release(library);

        var instance_data: [max_frames_in_flight]*objc.MTLBuffer = undefined;
        for (&instance_data) |*buffer| buffer.* = try metal.newBuffer(device, num_instances * @sizeOf(InstanceData));

        return .{
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .pipeline = try metal.newRenderPipeline(device, library, .{}),
            .vertex_buffer = try metal.newBufferWithData(device, &vertices),
            .index_buffer = try metal.newBufferWithData(device, &indices),
            .instance_data = instance_data,
            .semaphore = .init(max_frames_in_flight),
        };
    }

    pub fn deinit(r: *Renderer) void {
        // Wait for the frames in flight before releasing their resources.
        r.semaphore.deinit();
        for (r.instance_data) |buffer| metal.release(buffer);
        metal.release(r.index_buffer);
        metal.release(r.vertex_buffer);
        metal.release(r.pipeline);
        metal.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        r.frame = (r.frame + 1) % max_frames_in_flight;
        const instance_buffer = r.instance_data[r.frame];

        const cmd = r.command_queue.commandBuffer() orelse return;
        r.semaphore.wait();
        r.semaphore.signalOnCompletion(cmd);

        r.angle += 0.01;
        const a = r.angle;
        const scl = 0.1;
        for (metal.contentsSlice(InstanceData, instance_buffer), 0..) |*instance, i| {
            const t = @as(f32, @floatFromInt(i)) / num_instances;
            const xoff = (t * 2.0 - 1.0) + (1.0 / @as(f32, num_instances));
            const yoff = @sin((t + a) * 2.0 * std.math.pi);
            instance.* = .{
                .transform = math.fromColumns(
                    .{ scl * @sin(a), scl * @cos(a), 0, 0 },
                    .{ scl * @cos(a), scl * -@sin(a), 0, 0 },
                    .{ 0, 0, scl, 0 },
                    .{ xoff, yoff, 0, 1 },
                ),
                .color = math.f4(t, 1.0 - t, @sin(std.math.pi * 2.0 * t), 1.0),
            };
        }
        metal.didModify(instance_buffer);

        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse {
            cmd.commit();
            return;
        };
        encoder.setRenderPipelineState(r.pipeline);
        encoder.setVertexBuffer_offset_atIndex(r.vertex_buffer, 0, 0);
        encoder.setVertexBuffer_offset_atIndex(instance_buffer, 0, 1);
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
    }
};

pub fn main() !void {
    try metal.app.run(Renderer, .{ .title = "04 - Instancing" });
}
