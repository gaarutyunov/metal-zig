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

//! The AppKit scaffolding shared by the windowed examples: an application
//! delegate that creates the menu bar, a window and an `MTKView`, and forwards
//! `drawInMTKView:` to the example's renderer. This plays the role of
//! `MyAppDelegate` and `MyMTKViewDelegate` in the metal-cpp samples.
//!
//! The delegate is an Objective-C class created at runtime with the
//! Objective-C runtime API, with Zig functions as method implementations.
const std = @import("std");
const objc = @import("objc");
const util = @import("util.zig");

const nsString = util.nsString;

/// An extra menu with a single item, whose action calls a Zig function.
pub const ExtraMenu = struct {
    title: [:0]const u8,
    item_title: [:0]const u8,
    /// Key equivalent, used with the Command modifier.
    key: [:0]const u8,
    action: *const fn () void,
};

pub const Options = struct {
    /// The window title.
    title: [:0]const u8,
    clear_color: objc.MTLClearColor = .{ .red = 1.0, .green = 0.0, .blue = 0.0, .alpha = 1.0 },
    /// `MTLPixelFormatInvalid` means the view has no depth buffer.
    depth_stencil_pixel_format: objc.MTLPixelFormat = objc.MTLPixelFormatInvalid,
    clear_depth: f64 = 1.0,
    menu: ?ExtraMenu = null,
};

/// The pixel format of the view's drawables, which the render pipelines must
/// match.
pub const color_pixel_format = objc.MTLPixelFormatBGRA8Unorm_sRGB;

/// Runs the application until the window is closed or Cmd-Q is pressed.
///
/// `Renderer` must have `fn init(*objc.MTLDevice) !Renderer` and
/// `fn draw(*Renderer, *objc.MTKView) void`, and may have
/// `fn deinit(*Renderer) void`.
pub fn run(comptime Renderer: type, comptime options: Options) !void {
    return App(Renderer, options).run();
}

fn App(comptime Renderer: type, comptime options: Options) type {
    return struct {
        /// State shared with the Objective-C callbacks.
        var window: ?*objc.NSWindow = null;
        var view: ?*objc.MTKView = null;
        var device: ?*objc.MTLDevice = null;
        var renderer: ?Renderer = null;

        fn run() !void {
            const pool = objc.NSAutoreleasePool.alloc().?.init().?;
            defer pool.drain();

            const app = objc.NSApplication.sharedApplication().?;
            const delegate = try createDelegate();
            app.setDelegate(@ptrCast(delegate));
            app.run();
        }

        fn createDelegate() !*objc.NSObject {
            const superclass = objc.objc_lookUpClass("NSObject");
            const cls = objc.objc_allocateClassPair(superclass, "ZigMetalAppDelegate", 0) orelse
                return error.CannotCreateClass;

            addMethod(cls, "applicationWillFinishLaunching:", &applicationWillFinishLaunching, "v@:@");
            addMethod(cls, "applicationDidFinishLaunching:", &applicationDidFinishLaunching, "v@:@");
            addMethod(cls, "applicationShouldTerminateAfterLastWindowClosed:", &applicationShouldTerminateAfterLastWindowClosed, bool_encoding ++ "@:@");
            addMethod(cls, "applicationWillTerminate:", &applicationWillTerminate, "v@:@");
            addMethod(cls, "drawInMTKView:", &drawInMTKView, "v@:@");
            addMethod(cls, "mtkView:drawableSizeWillChange:", &drawableSizeWillChange, "v@:@{CGSize=dd}");
            addMethod(cls, "extraMenuAction:", &extraMenuAction, "v@:@");
            for ([_][*:0]const u8{ "NSApplicationDelegate", "MTKViewDelegate" }) |name| {
                if (objc.objc_getProtocol(name)) |protocol| _ = objc.class_addProtocol(cls, protocol);
            }
            objc.objc_registerClassPair(cls);

            const instance: *objc.NSObject = @ptrCast(objc.class_createInstance(cls, 0) orelse return error.OutOfMemory);
            return instance.init() orelse error.CannotCreateDelegate;
        }

        fn applicationWillFinishLaunching(_: ?*anyopaque, _: objc.SEL, notification: ?*objc.NSNotification) callconv(.c) void {
            const app: *objc.NSApplication = @ptrCast(notification.?.object());
            app.setMainMenu(createMenuBar(app.delegate()));
            _ = app.setActivationPolicy(objc.NSApplicationActivationPolicyRegular);
        }

        fn applicationDidFinishLaunching(_: ?*anyopaque, _: objc.SEL, notification: ?*objc.NSNotification) callconv(.c) void {
            const app: *objc.NSApplication = @ptrCast(notification.?.object());
            createWindow(app) catch |err| {
                std.log.err("failed to create the window: {t}", .{err});
                app.terminate(null);
                return;
            };
            app.activateIgnoringOtherApps(1);
        }

        fn applicationShouldTerminateAfterLastWindowClosed(_: ?*anyopaque, _: objc.SEL, _: ?*objc.NSApplication) callconv(.c) objc.BOOL {
            return 1;
        }

        fn applicationWillTerminate(_: ?*anyopaque, _: objc.SEL, _: ?*objc.NSNotification) callconv(.c) void {
            if (renderer) |*r| {
                if (@hasDecl(Renderer, "deinit")) r.deinit();
                renderer = null;
            }
            util.release(view);
            util.release(window);
            util.release(device);
        }

        fn drawInMTKView(_: ?*anyopaque, _: objc.SEL, v: ?*objc.MTKView) callconv(.c) void {
            if (renderer) |*r| r.draw(v.?);
        }

        fn drawableSizeWillChange(_: ?*anyopaque, _: objc.SEL, _: ?*objc.MTKView, _: objc.CGSize) callconv(.c) void {}

        fn extraMenuAction(_: ?*anyopaque, _: objc.SEL, _: ?*anyopaque) callconv(.c) void {
            if (options.menu) |menu| menu.action();
        }

        fn createWindow(app: *objc.NSApplication) !void {
            const frame: objc.CGRect = .{
                .origin = .{ .x = 100.0, .y = 100.0 },
                .size = .{ .width = 512.0, .height = 512.0 },
            };

            const w = objc.NSWindow.alloc().?.initWithContentRect_styleMask_backing_defer(
                frame,
                objc.NSWindowStyleMaskClosable | objc.NSWindowStyleMaskTitled,
                objc.NSBackingStoreBuffered,
                0,
            ) orelse return error.NoWindow;
            // The application releases the window when it closes; keep
            // our reference valid until `applicationWillTerminate:`.
            w.setReleasedWhenClosed(0);
            window = w;

            const d = objc.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
            device = d;
            std.log.info("using Metal device '{s}'", .{std.mem.span(d.name().?.UTF8String())});

            const v = objc.MTKView.alloc().?.initWithFrame_device(frame, d) orelse return error.NoView;
            view = v;
            v.setColorPixelFormat(color_pixel_format);
            v.setClearColor(options.clear_color);
            if (options.depth_stencil_pixel_format != objc.MTLPixelFormatInvalid) {
                v.setDepthStencilPixelFormat(options.depth_stencil_pixel_format);
                v.setClearDepth(options.clear_depth);
            }

            renderer = try Renderer.init(d);
            v.setDelegate(@ptrCast(app.delegate()));

            w.setContentView(v.as(objc.NSView));
            w.setTitle(nsString(options.title));
            w.makeKeyAndOrderFront(null);
        }

        fn createMenuBar(delegate: ?*objc.NSApplicationDelegate) ?*objc.NSMenu {
            const main_menu = objc.NSMenu.alloc().?.init().?;

            // Application menu with "Quit <app name>".
            const app_name = objc.NSRunningApplication.currentApplication().?.localizedName();
            const quit_title = nsString("Quit ").?.stringByAppendingString(app_name);
            main_menu.addItem(submenu("Appname", quit_title, "terminate:", "q", null));

            // Window menu with "Close Window".
            main_menu.addItem(submenu("Window", nsString("Close Window"), "performClose:", "w", null));

            if (options.menu) |menu| {
                main_menu.addItem(submenu(menu.title, nsString(menu.item_title), "extraMenuAction:", menu.key, delegate));
            }

            return @ptrCast(main_menu.as(objc.NSObjectProtocol).autorelease());
        }

        /// A menu bar item with a submenu holding a single item.
        fn submenu(
            comptime title: [:0]const u8,
            item_title: ?*objc.NSString,
            comptime action: [:0]const u8,
            comptime key: [:0]const u8,
            target: ?*objc.NSApplicationDelegate,
        ) *objc.NSMenuItem {
            const menu = objc.NSMenu.alloc().?.initWithTitle(nsString(title)).?;
            defer util.release(menu);

            const item = menu.addItemWithTitle_action_keyEquivalent(item_title, objc.sel_registerName(action), nsString(key)).?;
            item.setKeyEquivalentModifierMask(objc.NSEventModifierFlagCommand);
            if (target) |t| item.setTarget(@ptrCast(@alignCast(t)));

            const menu_item = objc.NSMenuItem.alloc().?.init().?;
            menu_item.setSubmenu(menu);
            return @ptrCast(menu_item.as(objc.NSObjectProtocol).autorelease());
        }
    };
}

/// Objective-C type encoding of `BOOL`.
const bool_encoding = if (objc.BOOL == bool) "B" else "c";

fn addMethod(cls: objc.Class, comptime selector: [:0]const u8, imp: anytype, comptime types: [:0]const u8) void {
    std.debug.assert(objc.class_addMethod(cls, objc.sel_registerName(selector), @ptrCast(imp), types) != 0);
}
