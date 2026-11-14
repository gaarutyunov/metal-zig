//! A gradient triangle rendered with Metal, in the spirit of the metal-cpp
//! "01-primitive" sample, but written in Zig against the native Objective-C
//! AppKit/Metal/MetalKit headers translated by translate-c (no metal-cpp).
//!
//! Objective-C classes and protocols are exposed by translate-c as opaque
//! types with methods (`device.newCommandQueue()`), and `obj.as(T)` casts to
//! a superclass or protocol. The application and view delegates are created
//! at runtime with the Objective-C runtime API, with Zig functions as method
//! implementations.
const std = @import("std");
const objc = @import("metal");

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

/// `float3` in a Metal buffer has the size and alignment of `simd_float3`.
const float3 = objc.simd_float3;
comptime {
    std.debug.assert(@sizeOf(float3) == 16);
}

const positions = [_]float3{
    .{ -0.8, 0.8, 0.0 },
    .{ 0.0, -0.8, 0.0 },
    .{ 0.8, 0.8, 0.0 },
};
const colors = [_]float3{
    .{ 1.0, 0.3, 0.2 },
    .{ 0.8, 1.0, 0.0 },
    .{ 0.8, 0.0, 1.0 },
};

const Renderer = struct {
    device: *objc.MTLDevice,
    command_queue: *objc.MTLCommandQueue,
    pipeline: *objc.MTLRenderPipelineState,
    positions: *objc.MTLBuffer,
    colors: *objc.MTLBuffer,

    fn init(device: *objc.MTLDevice) !Renderer {
        return .{
            .device = device,
            .command_queue = device.newCommandQueue() orelse return error.NoCommandQueue,
            .pipeline = try buildShaders(device),
            .positions = try newBuffer(device, std.mem.sliceAsBytes(&positions)),
            .colors = try newBuffer(device, std.mem.sliceAsBytes(&colors)),
        };
    }

    fn buildShaders(device: *objc.MTLDevice) !*objc.MTLRenderPipelineState {
        var err: ?*objc.NSError = null;
        const library = device.newLibraryWithSource_options_error(nsString(shader_source), null, &err) orelse
            return fail("compiling shaders", err);
        defer release(library);

        const vertex_fn = library.newFunctionWithName(nsString("vertexMain"));
        defer release(vertex_fn);
        const fragment_fn = library.newFunctionWithName(nsString("fragmentMain"));
        defer release(fragment_fn);

        const desc = objc.MTLRenderPipelineDescriptor.alloc().?.init().?;
        defer release(desc);
        desc.setVertexFunction(vertex_fn);
        desc.setFragmentFunction(fragment_fn);
        desc.colorAttachments().?.objectAtIndexedSubscript(0).?.setPixelFormat(objc.MTLPixelFormatBGRA8Unorm_sRGB);

        return device.newRenderPipelineStateWithDescriptor_error(desc, &err) orelse
            return fail("creating the render pipeline", err);
    }

    fn newBuffer(device: *objc.MTLDevice, bytes: []const u8) !*objc.MTLBuffer {
        return device.newBufferWithBytes_length_options(bytes.ptr, bytes.len, objc.MTLResourceStorageModeShared) orelse
            error.NoBuffer;
    }

    fn draw(r: *Renderer, view: *objc.MTKView) void {
        const pool = objc.NSAutoreleasePool.alloc().?.init().?;
        defer pool.drain();

        const cmd = r.command_queue.commandBuffer() orelse return;
        const pass = view.currentRenderPassDescriptor() orelse return;
        const encoder = cmd.renderCommandEncoderWithDescriptor(pass) orelse return;

        encoder.setRenderPipelineState(r.pipeline);
        encoder.setVertexBuffer_offset_atIndex(r.positions, 0, 0);
        encoder.setVertexBuffer_offset_atIndex(r.colors, 0, 1);
        encoder.drawPrimitives_vertexStart_vertexCount(objc.MTLPrimitiveTypeTriangle, 0, positions.len);
        encoder.as(objc.MTLCommandEncoder).endEncoding();

        if (view.currentDrawable()) |drawable| cmd.presentDrawable(drawable.as(objc.MTLDrawable));
        cmd.commit();
    }
};

/// State shared with the Objective-C callbacks.
var app_state: struct {
    window: ?*objc.NSWindow = null,
    view: ?*objc.MTKView = null,
    renderer: ?Renderer = null,
} = .{};

pub fn main() !void {
    const pool = objc.NSAutoreleasePool.alloc().?.init().?;
    defer pool.drain();

    const app = objc.NSApplication.sharedApplication().?;
    const delegate = try createDelegate();
    app.setDelegate(@ptrCast(delegate));
    app.run();
}

// ---------------------------------------------------------------------------
// Application delegate, implemented as an Objective-C class created at runtime
// ---------------------------------------------------------------------------

/// Objective-C type encoding of `BOOL`.
const bool_encoding = if (objc.BOOL == bool) "B" else "c";

fn createDelegate() !*objc.NSObject {
    const superclass = objc.objc_lookUpClass("NSObject");
    const cls = objc.objc_allocateClassPair(superclass, "ZigTriangleDelegate", 0) orelse
        return error.CannotCreateClass;

    addMethod(cls, "applicationWillFinishLaunching:", &applicationWillFinishLaunching, "v@:@");
    addMethod(cls, "applicationDidFinishLaunching:", &applicationDidFinishLaunching, "v@:@");
    addMethod(cls, "applicationShouldTerminateAfterLastWindowClosed:", &applicationShouldTerminateAfterLastWindowClosed, bool_encoding ++ "@:@");
    addMethod(cls, "drawInMTKView:", &drawInMTKView, "v@:@");
    addMethod(cls, "mtkView:drawableSizeWillChange:", &drawableSizeWillChange, "v@:@{CGSize=dd}");
    for ([_][*:0]const u8{ "NSApplicationDelegate", "MTKViewDelegate" }) |name| {
        if (objc.objc_getProtocol(name)) |protocol| _ = objc.class_addProtocol(cls, protocol);
    }
    objc.objc_registerClassPair(cls);

    const instance: *objc.NSObject = @ptrCast(objc.class_createInstance(cls, 0) orelse return error.OutOfMemory);
    return instance.init() orelse error.CannotCreateDelegate;
}

fn addMethod(cls: objc.Class, comptime selector: [:0]const u8, imp: anytype, comptime types: [:0]const u8) void {
    std.debug.assert(objc.class_addMethod(cls, objc.sel_registerName(selector), @ptrCast(imp), types) != 0);
}

fn applicationWillFinishLaunching(_: ?*anyopaque, _: objc.SEL, notification: ?*objc.NSNotification) callconv(.c) void {
    const app: *objc.NSApplication = @ptrCast(notification.?.object());
    app.setMainMenu(createMenuBar());
    _ = app.setActivationPolicy(objc.NSApplicationActivationPolicyRegular);
}

fn applicationDidFinishLaunching(_: ?*anyopaque, _: objc.SEL, notification: ?*objc.NSNotification) callconv(.c) void {
    const app: *objc.NSApplication = @ptrCast(notification.?.object());
    createWindow() catch |err| {
        std.log.err("failed to create the window: {t}", .{err});
        app.terminate(null);
        return;
    };
    app.activateIgnoringOtherApps(1);
}

fn applicationShouldTerminateAfterLastWindowClosed(_: ?*anyopaque, _: objc.SEL, _: ?*objc.NSApplication) callconv(.c) objc.BOOL {
    return 1;
}

fn drawInMTKView(_: ?*anyopaque, _: objc.SEL, view: ?*objc.MTKView) callconv(.c) void {
    if (app_state.renderer) |*renderer| renderer.draw(view.?);
}

fn drawableSizeWillChange(_: ?*anyopaque, _: objc.SEL, _: ?*objc.MTKView, _: objc.CGSize) callconv(.c) void {}

fn createWindow() !void {
    const device = objc.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
    std.log.info("using Metal device '{s}'", .{std.mem.span(device.name().?.UTF8String())});

    const frame: objc.CGRect = .{
        .origin = .{ .x = 100.0, .y = 100.0 },
        .size = .{ .width = 512.0, .height = 512.0 },
    };

    const view = objc.MTKView.alloc().?.initWithFrame_device(frame, device) orelse return error.NoView;
    view.setColorPixelFormat(objc.MTLPixelFormatBGRA8Unorm_sRGB);
    view.setClearColor(.{ .red = 1.0, .green = 0.0, .blue = 0.0, .alpha = 1.0 });

    app_state.renderer = try Renderer.init(device);
    view.setDelegate(@ptrCast(objc.NSApplication.sharedApplication().?.delegate()));

    const window = objc.NSWindow.alloc().?.initWithContentRect_styleMask_backing_defer(
        frame,
        objc.NSWindowStyleMaskClosable | objc.NSWindowStyleMaskTitled |
            objc.NSWindowStyleMaskMiniaturizable | objc.NSWindowStyleMaskResizable,
        objc.NSBackingStoreBuffered,
        0,
    ) orelse return error.NoWindow;
    window.setContentView(view.as(objc.NSView));
    window.setTitle(nsString("Zig Metal: 01 - Primitive"));
    window.makeKeyAndOrderFront(null);

    app_state.window = window;
    app_state.view = view;
}

fn createMenuBar() ?*objc.NSMenu {
    const main_menu = objc.NSMenu.alloc().?.init().?;

    // Application menu with "Quit".
    const app_menu_item = objc.NSMenuItem.alloc().?.init().?;
    const app_menu = objc.NSMenu.alloc().?.initWithTitle(nsString("Appname")).?;
    const quit_item = objc.NSMenuItem.alloc().?.initWithTitle_action_keyEquivalent(
        nsString("Quit"),
        objc.sel_registerName("terminate:"),
        nsString("q"),
    ).?;
    quit_item.setKeyEquivalentModifierMask(objc.NSEventModifierFlagCommand);
    app_menu.addItem(quit_item);
    app_menu_item.setSubmenu(app_menu);

    // Window menu with "Close Window".
    const window_menu_item = objc.NSMenuItem.alloc().?.init().?;
    const window_menu = objc.NSMenu.alloc().?.initWithTitle(nsString("Window")).?;
    const close_item = objc.NSMenuItem.alloc().?.initWithTitle_action_keyEquivalent(
        nsString("Close Window"),
        objc.sel_registerName("performClose:"),
        nsString("w"),
    ).?;
    close_item.setKeyEquivalentModifierMask(objc.NSEventModifierFlagCommand);
    window_menu.addItem(close_item);
    window_menu_item.setSubmenu(window_menu);

    main_menu.addItem(app_menu_item);
    main_menu.addItem(window_menu_item);
    return main_menu;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn nsString(comptime str: [:0]const u8) ?*objc.NSString {
    return objc.NSString.stringWithUTF8String(str);
}

/// Sends `release` (declared by the `NSObject` protocol) to any object.
fn release(obj: anytype) void {
    const ptr = switch (@typeInfo(@TypeOf(obj))) {
        .optional => obj orelse return,
        else => obj,
    };
    ptr.as(objc.NSObjectProtocol).release();
}

fn fail(what: []const u8, err: ?*objc.NSError) error{Metal} {
    const description = if (err) |e| std.mem.span(e.localizedDescription().?.UTF8String()) else "unknown error";
    std.log.err("{s}: {s}", .{ what, description });
    return error.Metal;
}
