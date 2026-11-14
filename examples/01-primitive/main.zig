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

//! Port of the metal-cpp "01-primitive" sample: a triangle with per-vertex
//! colors, from vertex buffers and a shader compiled at runtime.
//!
//! Objective-C classes and protocols are exposed by translate-c as opaque
//! types with methods (`device.newCommandQueue()`), and `obj.as(T)` casts to
//! a superclass or protocol.
const metal = @import("metal");
const objc = metal.objc;

const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct v2f {
    \\    float4 position [[position]];
    \\    half3 color;
    \\};
    \\
    \\v2f vertex vertexMain(uint vertexId [[vertex_id]],
    \\                      device const float3* positions [[buffer(0)]],
    \\                      device const float3* colors [[buffer(1)]]) {
    \\    v2f o;
    \\    o.position = float4(positions[vertexId], 1.0);
    \\    o.color = half3(colors[vertexId]);
    \\    return o;
    \\}
    \\
    \\half4 fragment fragmentMain(v2f in [[stage_in]]) {
    \\    return half4(in.color, 1.0);
    \\}
;

/// `float3` with the layout of the Metal type: 16 bytes, 16-byte aligned.
const f3 = metal.math.f3;

const positions = [_]metal.math.float3{
    f3(-0.8, 0.8, 0.0),
    f3(0.0, -0.8, 0.0),
    f3(0.8, 0.8, 0.0),
};
const colors = [_]metal.math.float3{
    f3(1.0, 0.3, 0.2),
    f3(0.8, 1.0, 0.0),
    f3(0.8, 0.0, 1.0),
};

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,
    pipeline: *objc.MTLRenderPipelineState,
    positions: *objc.MTLBuffer,
    colors: *objc.MTLBuffer,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        const library = try metal.newLibrary(device, shader_source);
        defer metal.release(library);
        return .{
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .pipeline = try metal.newRenderPipeline(device, library, .{}),
            .positions = try metal.newBufferWithData(device, &positions),
            .colors = try metal.newBufferWithData(device, &colors),
        };
    }

    pub fn deinit(r: *Renderer) void {
        metal.release(r.colors);
        metal.release(r.positions);
        metal.release(r.pipeline);
        metal.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        const cmd = r.command_queue.commandBuffer() orelse return;
        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse return;

        encoder.setRenderPipelineState(r.pipeline);
        encoder.setVertexBuffer_offset_atIndex(r.positions, 0, 0);
        encoder.setVertexBuffer_offset_atIndex(r.colors, 0, 1);
        encoder.drawPrimitives_vertexStart_vertexCount(objc.MTLPrimitiveTypeTriangle, 0, positions.len);
        encoder.as(objc.MTLCommandEncoder).endEncoding();

        if (view.currentDrawable()) |drawable| cmd.presentDrawable(drawable.as(objc.MTLDrawable));
        cmd.commit();
    }
};

pub fn main() !void {
    try metal.app.run(Renderer, .{ .title = "01 - Primitive" });
}
