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

//! Port of the metal-cpp "00-window" sample: opens a window with an
//! `MTKView` and clears it to red every frame.
const metal = @import("metal");
const objc = metal.objc;

const Renderer = struct {
    command_queue: *objc.MTLCommandQueue,

    pub fn init(device: *objc.MTLDevice) !Renderer {
        return .{ .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue };
    }

    pub fn deinit(r: *Renderer) void {
        metal.release(r.command_queue);
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
    try metal.app.run(Renderer, .{ .title = "00 - Window" });
}
