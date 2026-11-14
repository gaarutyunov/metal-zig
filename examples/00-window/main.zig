//! Port of the metal-cpp "00-window" sample: opens a window with an
//! `MTKView` and clears it to red every frame.
const objc = @import("metal");
const common = @import("common");

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        return .{ .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue };
    }

    pub fn deinit(r: *Renderer) void {
        common.release(r.command_queue);
    }

    pub fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        const cmd = r.command_queue.commandBuffer() orelse return;
        // The render pass clears to the view's clear color; nothing is drawn.
        const encoder = cmd.renderCommandEncoderWithDescriptor(view.currentRenderPassDescriptor()) orelse return;
        encoder.as(objc.MTLCommandEncoder).endEncoding();
        if (view.currentDrawable()) |drawable| cmd.presentDrawable(drawable.as(objc.MTLDrawable));
        cmd.commit();
    }
};

pub fn main() !void {
    try common.app.run(Renderer, .{ .title = "00 - Window" });
}
