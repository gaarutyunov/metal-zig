//! Port of the metal-cpp "02-argbuffers" sample: the triangle of
//! 01-primitive, with its vertex buffers passed to the shader through an
//! argument buffer, encoded with an `MTLArgumentEncoder`.
const objc = @import("metal");
const common = @import("common");
const util = common.util;
const math = common.math;
const f3 = math.f3;

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
    \\v2f vertex vertexMain(device const VertexData* vertexData [[buffer(0)]], uint vertexId [[vertex_id]]) {
    \\    v2f o;
    \\    o.position = float4(vertexData->positions[vertexId], 1.0);
    \\    o.color = half3(vertexData->colors[vertexId]);
    \\    return o;
    \\}
    \\
    \\half4 fragment fragmentMain(v2f in [[stage_in]]) {
    \\    return half4(in.color, 1.0);
    \\}
;

const positions = [_]math.float3{ f3(-0.8, 0.8, 0.0), f3(0.0, -0.8, 0.0), f3(0.8, 0.8, 0.0) };
const colors = [_]math.float3{ f3(1.0, 0.3, 0.2), f3(0.8, 1.0, 0.0), f3(0.8, 0.0, 1.0) };

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,
    library: *objc.MTLLibrary,
    pipeline: *objc.MTLRenderPipelineState,
    positions: *objc.MTLBuffer,
    colors: *objc.MTLBuffer,
    arg_buffer: *objc.MTLBuffer,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        const library = try util.newLibrary(device, shader_source);
        const positions_buffer = try util.newBufferWithData(device, &positions);
        const colors_buffer = try util.newBufferWithData(device, &colors);
        return .{
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .library = library,
            .pipeline = try util.newRenderPipeline(device, library, .{}),
            .positions = positions_buffer,
            .colors = colors_buffer,
            .arg_buffer = try buildArgBuffer(device, library, positions_buffer, colors_buffer),
        };
    }

    /// Encodes the `VertexData` struct of the shader, which points to the
    /// position and color buffers.
    fn buildArgBuffer(
        device: *objc.MTLDevice,
        library: *objc.MTLLibrary,
        positions_buffer: *objc.MTLBuffer,
        colors_buffer: *objc.MTLBuffer,
    ) !*objc.MTLBuffer {
        const vertex_fn = try util.newFunction(library, "vertexMain");
        defer common.release(vertex_fn);
        const arg_encoder = vertex_fn.newArgumentEncoderWithBufferIndex(0) orelse return error.NoArgumentEncoder;
        defer common.release(arg_encoder);

        const arg_buffer = try util.newBuffer(device, arg_encoder.encodedLength());
        arg_encoder.setArgumentBuffer_offset(arg_buffer, 0);
        arg_encoder.setBuffer_offset_atIndex(positions_buffer, 0, 0);
        arg_encoder.setBuffer_offset_atIndex(colors_buffer, 0, 1);
        util.didModify(arg_buffer);
        return arg_buffer;
    }

    pub fn deinit(r: *Renderer) void {
        common.release(r.arg_buffer);
        common.release(r.colors);
        common.release(r.positions);
        common.release(r.pipeline);
        common.release(r.library);
        common.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        const cmd = r.command_queue.commandBuffer() orelse return;
        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse return;

        encoder.setRenderPipelineState(r.pipeline);
        encoder.setVertexBuffer_offset_atIndex(r.arg_buffer, 0, 0);
        // The buffers referenced by the argument buffer must be made resident.
        encoder.useResource_usage(r.positions.as(objc.MTLResource), objc.MTLResourceUsageRead);
        encoder.useResource_usage(r.colors.as(objc.MTLResource), objc.MTLResourceUsageRead);
        encoder.drawPrimitives_vertexStart_vertexCount(objc.MTLPrimitiveTypeTriangle, 0, positions.len);
        encoder.as(objc.MTLCommandEncoder).endEncoding();

        if (view.currentDrawable()) |drawable| cmd.presentDrawable(drawable.as(objc.MTLDrawable));
        cmd.commit();
    }
};

pub fn main() !void {
    try common.app.run(Renderer, .{ .title = "02 - Argument Buffers" });
}
