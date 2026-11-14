//! Metal on macOS from Zig, through the native AppKit, Metal and
//! MetalKit Objective-C headers translated by translate-c.
//!
//! - `objc` is the translated headers: every class, protocol, function and
//!   constant of AppKit, Foundation, Metal, MetalKit and the Objective-C
//!   runtime. Classes and protocols are opaque types whose methods send
//!   Objective-C messages, and `obj.as(T)` casts to a superclass or protocol.
//! - `app` runs an AppKit application with a window and an `MTKView` that
//!   calls your renderer every frame.
//! - Helpers for strings, shaders, pipelines, buffers and frame pacing, such
//!   as `newLibrary`, `newRenderPipeline`, `newBufferWithData` and
//!   `FrameSemaphore`.
//! - `math` has vector and matrix types with the memory layout of the Metal
//!   Shading Language types, and transforms.
pub const objc = @import("objc");
pub const app = @import("app.zig");
pub const math = @import("math.zig");

const util = @import("util.zig");
pub const nsString = util.nsString;
pub const zigString = util.zigString;
pub const release = util.release;
pub const fail = util.fail;
pub const newLibrary = util.newLibrary;
pub const newFunction = util.newFunction;
pub const RenderPipelineOptions = util.RenderPipelineOptions;
pub const newRenderPipeline = util.newRenderPipeline;
pub const newBuffer = util.newBuffer;
pub const newBufferWithData = util.newBufferWithData;
pub const contents = util.contents;
pub const contentsSlice = util.contentsSlice;
pub const didModify = util.didModify;
pub const FrameSemaphore = util.FrameSemaphore;

test {
    _ = math;
}
