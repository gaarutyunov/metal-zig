# zig-metal-device

Looks up the Metal GPU devices of a Mac from Zig, using the native
Metal/MetalKit Objective-C headers translated to Zig by `translate-c`.

`src/metal.m` imports the headers:

```objc
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
```

and `build.zig` turns it into the `metal` module with `b.addTranslateC`.
Objective-C classes and protocols become opaque Zig types whose methods send
Objective-C messages:

```zig
const device = metal.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
const name = device.name().?.UTF8String();
```

## Requirements

A Zig 0.18 build with Objective-C support in translate-c, from the
`objc-import` branches of:

- https://github.com/gaarutyunov/zig
- https://github.com/gaarutyunov/arocc
- https://github.com/gaarutyunov/translate-c
- https://github.com/gaarutyunov/zls (editor support)

## Usage

```sh
zig build run
```
