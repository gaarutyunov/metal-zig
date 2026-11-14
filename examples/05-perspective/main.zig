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

//! Port of the metal-cpp "05-perspective" sample: instanced cubes, rotating
//! in 3D, with a perspective projection, a depth buffer and back-face
//! culling. The transforms come from the tiny math library in
//! `metal.math`.
const std = @import("std");
const metal = @import("metal");
const objc = metal.objc;
const math = metal.math;
const f3 = math.f3;

const max_frames_in_flight = 3;
const num_instances = 32;
const depth_pixel_format = objc.MTLPixelFormatDepth16Unorm;

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
    \\struct CameraData {
    \\    float4x4 perspectiveTransform;
    \\    float4x4 worldTransform;
    \\};
    \\
    \\v2f vertex vertexMain(device const VertexData* vertexData [[buffer(0)]],
    \\                      device const InstanceData* instanceData [[buffer(1)]],
    \\                      device const CameraData& cameraData [[buffer(2)]],
    \\                      uint vertexId [[vertex_id]],
    \\                      uint instanceId [[instance_id]]) {
    \\    v2f o;
    \\    float4 pos = float4(vertexData[vertexId].position, 1.0);
    \\    pos = instanceData[instanceId].instanceTransform * pos;
    \\    pos = cameraData.perspectiveTransform * cameraData.worldTransform * pos;
    \\    o.position = pos;
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

const CameraData = extern struct {
    perspective: math.float4x4,
    world: math.float4x4,
};

const s = 0.5;
const vertices = [_]math.float3{
    f3(-s, -s, s),  f3(s, -s, s),  f3(s, s, s),  f3(-s, s, s),
    f3(-s, -s, -s), f3(-s, s, -s), f3(s, s, -s), f3(s, -s, -s),
};
const indices = [_]u16{
    0, 1, 2, 2, 3, 0, // front
    1, 7, 6, 6, 2, 1, // right
    7, 4, 5, 5, 6, 7, // back
    4, 0, 3, 3, 5, 4, // left
    3, 2, 6, 6, 5, 3, // top
    4, 7, 1, 1, 0, 4, // bottom
};

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,
    pipeline: *objc.MTLRenderPipelineState,
    depth_stencil_state: *objc.MTLDepthStencilState,
    vertex_buffer: *objc.MTLBuffer,
    index_buffer: *objc.MTLBuffer,
    instance_data: [max_frames_in_flight]*objc.MTLBuffer,
    camera_data: [max_frames_in_flight]*objc.MTLBuffer,
    semaphore: metal.FrameSemaphore,
    angle: f32 = 0,
    frame: usize = 0,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        const library = try metal.newLibrary(device, shader_source);
        defer metal.release(library);

        var instance_data: [max_frames_in_flight]*objc.MTLBuffer = undefined;
        for (&instance_data) |*buffer| buffer.* = try metal.newBuffer(device, num_instances * @sizeOf(InstanceData));
        var camera_data: [max_frames_in_flight]*objc.MTLBuffer = undefined;
        for (&camera_data) |*buffer| buffer.* = try metal.newBuffer(device, @sizeOf(CameraData));

        return .{
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .pipeline = try metal.newRenderPipeline(device, library, .{ .depth_pixel_format = depth_pixel_format }),
            .depth_stencil_state = try buildDepthStencilState(device),
            .vertex_buffer = try metal.newBufferWithData(device, &vertices),
            .index_buffer = try metal.newBufferWithData(device, &indices),
            .instance_data = instance_data,
            .camera_data = camera_data,
            .semaphore = .init(max_frames_in_flight),
        };
    }

    fn buildDepthStencilState(device: *objc.MTLDevice) !*objc.MTLDepthStencilState {
        const desc = objc.MTLDepthStencilDescriptor.alloc().?.init().?;
        defer metal.release(desc);
        desc.setDepthCompareFunction(objc.MTLCompareFunctionLess);
        desc.setDepthWriteEnabled(1);
        return device.newDepthStencilStateWithDescriptor(desc) orelse error.NoDepthStencilState;
    }

    pub fn deinit(r: *Renderer) void {
        // Wait for the frames in flight before releasing their resources.
        r.semaphore.deinit();
        for (r.camera_data) |buffer| metal.release(buffer);
        for (r.instance_data) |buffer| metal.release(buffer);
        metal.release(r.index_buffer);
        metal.release(r.vertex_buffer);
        metal.release(r.depth_stencil_state);
        metal.release(r.pipeline);
        metal.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        r.frame = (r.frame + 1) % max_frames_in_flight;
        const instance_buffer = r.instance_data[r.frame];
        const camera_buffer = r.camera_data[r.frame];

        const cmd = r.command_queue.commandBuffer() orelse return;
        r.semaphore.wait();
        r.semaphore.signalOnCompletion(cmd);

        r.angle += 0.01;
        const a = r.angle;
        const scl = 0.1;

        // Rotate the whole group of instances around its center.
        const object_position: math.Vec3 = .{ 0, 0, -5 };
        const full_object_rot = math.mulAll(&.{
            math.translate(object_position),
            math.rotateY(-a),
            math.translate(-object_position),
        });

        for (metal.contentsSlice(InstanceData, instance_buffer), 0..) |*instance, i| {
            const t = @as(f32, @floatFromInt(i)) / num_instances;
            const xoff = (t * 2.0 - 1.0) + (1.0 / @as(f32, num_instances));
            const yoff = @sin((t + a) * 2.0 * std.math.pi);
            instance.* = .{
                .transform = math.mulAll(&.{
                    full_object_rot,
                    math.translate(object_position + math.Vec3{ xoff, yoff, 0 }),
                    math.rotateY(a),
                    math.rotateZ(a),
                    math.scale(@splat(scl)),
                }),
                .color = math.f4(t, 1.0 - t, @sin(std.math.pi * 2.0 * t), 1.0),
            };
        }
        metal.didModify(instance_buffer);

        metal.contents(CameraData, camera_buffer).* = .{
            .perspective = math.perspective(45.0 * std.math.pi / 180.0, 1.0, 0.03, 500.0),
            .world = math.identity(),
        };
        metal.didModify(camera_buffer);

        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse {
            cmd.commit();
            return;
        };
        encoder.setRenderPipelineState(r.pipeline);
        encoder.setDepthStencilState(r.depth_stencil_state);
        encoder.setVertexBuffer_offset_atIndex(r.vertex_buffer, 0, 0);
        encoder.setVertexBuffer_offset_atIndex(instance_buffer, 0, 1);
        encoder.setVertexBuffer_offset_atIndex(camera_buffer, 0, 2);
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
    }
};

pub fn main() !void {
    try metal.app.run(Renderer, .{
        .title = "05 - Perspective",
        .clear_color = .{ .red = 0.1, .green = 0.1, .blue = 0.1, .alpha = 1.0 },
        .depth_stencil_pixel_format = depth_pixel_format,
    });
}
