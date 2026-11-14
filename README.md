# metal-zig

Metal examples in Zig, using the **native** AppKit, Metal and MetalKit
Objective-C headers translated to Zig by `translate-c`. No metal-cpp, no
hand-written bindings.

`src/metal.m` imports the headers:

```objc
#import <objc/runtime.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
```

and `build.zig` turns it into a Zig module with `b.addTranslateC`. Objective-C
classes and protocols become opaque Zig types whose methods send Objective-C
messages, and `obj.as(T)` casts to a superclass or protocol to reach inherited
methods:

```zig
const device = objc.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
const queue = device.newCommandQueue().?;
const encoder = queue.commandBuffer().?.renderCommandEncoderWithDescriptor(pass).?;
encoder.drawPrimitives_vertexStart_vertexCount(objc.MTLPrimitiveTypeTriangle, 0, 3);
encoder.as(objc.MTLCommandEncoder).endEncoding();
```

## Examples

### 00-device

Lists the Metal GPU devices and their properties, and creates a MetalKit
`MTKTextureLoader` for the default device.

```sh
zig build run-00-device
```

![00-device](docs/00-device.gif)

### 01-primitive

The classic gradient triangle, modelled on the
[metal-cpp](https://developer.apple.com/metal/cpp/) `01-primitive` sample: an
AppKit window with an `MTKView`, a shader compiled at runtime and one triangle
with per-vertex colors. The application and `MTKView` delegates are
Objective-C classes created at runtime with `objc_allocateClassPair`, using Zig
functions as method implementations. Cmd-W closes the window and Cmd-Q quits.

```sh
zig build run-01-primitive
```

<img src="docs/01-primitive.png" alt="01-primitive" width="512">

## Requirements

A Zig 0.18 build with Objective-C support in translate-c, from the
`objc-import` branches of:

- https://github.com/gaarutyunov/zig
- https://github.com/gaarutyunov/arocc
- https://github.com/gaarutyunov/translate-c
- https://github.com/gaarutyunov/zls (editor support)

## Media

`tools/record.sh` regenerates the media in `docs/`: the terminal recording is
made with [asciinema](https://asciinema.org) and rendered to a GIF with
[agg](https://github.com/asciinema/agg), and the window is captured with
`screencapture -l <window id>`.
