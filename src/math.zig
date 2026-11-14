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

//! The tiny math library of the metal-cpp samples.
//!
//! The types have the memory layout of the Metal Shading Language types of
//! the same name, so they can be used in structs shared with shaders: `float3`
//! takes 16 bytes, and matrices are arrays of column vectors.
//!
//! (translate-c's `simd_float4x4` from `<simd/simd.h>` cannot be used in
//! `extern struct`s, because its columns are Zig vectors, which have no
//! guaranteed in-memory representation.)
const std = @import("std");

pub const float2 = extern struct {
    x: f32 align(8),
    y: f32,
};

pub const float3 = extern struct {
    x: f32 align(16),
    y: f32,
    z: f32,
    _pad: f32 = 0,
};

pub const float4 = extern struct {
    x: f32 align(16),
    y: f32,
    z: f32,
    w: f32,

    pub fn vec(v: float4) Vec4 {
        return .{ v.x, v.y, v.z, v.w };
    }
};

pub const float3x3 = extern struct {
    columns: [3]float3,
};

pub const float4x4 = extern struct {
    columns: [4]float4,

    pub fn column(m: float4x4, i: usize) Vec4 {
        return m.columns[i].vec();
    }
};

comptime {
    std.debug.assert(@sizeOf(float2) == 8 and @alignOf(float2) == 8);
    std.debug.assert(@sizeOf(float3) == 16 and @alignOf(float3) == 16);
    std.debug.assert(@sizeOf(float4) == 16 and @alignOf(float4) == 16);
    std.debug.assert(@sizeOf(float3x3) == 48 and @alignOf(float3x3) == 16);
    std.debug.assert(@sizeOf(float4x4) == 64 and @alignOf(float4x4) == 16);
}

/// Vectors for arithmetic.
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub fn f2(x: f32, y: f32) float2 {
    return .{ .x = x, .y = y };
}

pub fn f3(x: f32, y: f32, z: f32) float3 {
    return .{ .x = x, .y = y, .z = z };
}

pub fn f4(x: f32, y: f32, z: f32, w: f32) float4 {
    return .{ .x = x, .y = y, .z = z, .w = w };
}

fn fromVec4(v: Vec4) float4 {
    return f4(v[0], v[1], v[2], v[3]);
}

pub fn fromColumns(c0: Vec4, c1: Vec4, c2: Vec4, c3: Vec4) float4x4 {
    return .{ .columns = .{ fromVec4(c0), fromVec4(c1), fromVec4(c2), fromVec4(c3) } };
}

/// Like `simd_matrix_from_rows`.
pub fn fromRows(r0: Vec4, r1: Vec4, r2: Vec4, r3: Vec4) float4x4 {
    return fromColumns(
        .{ r0[0], r1[0], r2[0], r3[0] },
        .{ r0[1], r1[1], r2[1], r3[1] },
        .{ r0[2], r1[2], r2[2], r3[2] },
        .{ r0[3], r1[3], r2[3], r3[3] },
    );
}

pub fn identity() float4x4 {
    return fromColumns(
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    );
}

pub fn perspective(fov_radians: f32, aspect: f32, znear: f32, zfar: f32) float4x4 {
    const ys = 1.0 / @tan(fov_radians * 0.5);
    const xs = ys / aspect;
    const zs = zfar / (znear - zfar);
    return fromRows(
        .{ xs, 0, 0, 0 },
        .{ 0, ys, 0, 0 },
        .{ 0, 0, zs, znear * zs },
        .{ 0, 0, -1, 0 },
    );
}

pub fn rotateX(a: f32) float4x4 {
    return fromRows(
        .{ 1, 0, 0, 0 },
        .{ 0, @cos(a), @sin(a), 0 },
        .{ 0, -@sin(a), @cos(a), 0 },
        .{ 0, 0, 0, 1 },
    );
}

pub fn rotateY(a: f32) float4x4 {
    return fromRows(
        .{ @cos(a), 0, @sin(a), 0 },
        .{ 0, 1, 0, 0 },
        .{ -@sin(a), 0, @cos(a), 0 },
        .{ 0, 0, 0, 1 },
    );
}

pub fn rotateZ(a: f32) float4x4 {
    return fromRows(
        .{ @cos(a), @sin(a), 0, 0 },
        .{ -@sin(a), @cos(a), 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    );
}

pub fn translate(v: Vec3) float4x4 {
    return fromColumns(
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ v[0], v[1], v[2], 1 },
    );
}

pub fn scale(v: Vec3) float4x4 {
    return fromColumns(
        .{ v[0], 0, 0, 0 },
        .{ 0, v[1], 0, 0 },
        .{ 0, 0, v[2], 0 },
        .{ 0, 0, 0, 1 },
    );
}

/// The upper-left 3x3 matrix.
pub fn discardTranslation(m: float4x4) float3x3 {
    var result: float3x3 = undefined;
    for (&result.columns, m.columns[0..3]) |*dst, src| dst.* = f3(src.x, src.y, src.z);
    return result;
}

/// The matrix product `a * b`.
pub fn mul(a: float4x4, b: float4x4) float4x4 {
    var result: float4x4 = undefined;
    for (&result.columns, b.columns) |*dst, col| dst.* = fromVec4(mulVector(a, col.vec()));
    return result;
}

/// The product of the matrices, from left to right.
pub fn mulAll(matrices: []const float4x4) float4x4 {
    var result = matrices[0];
    for (matrices[1..]) |m| result = mul(result, m);
    return result;
}

/// The matrix-vector product `m * v`.
pub fn mulVector(m: float4x4, v: Vec4) Vec4 {
    var result: Vec4 = @splat(0);
    inline for (0..4) |k| result += m.column(k) * @as(Vec4, @splat(v[k]));
    return result;
}

test mul {
    const a = mulAll(&.{ translate(.{ 1, 2, 3 }), rotateZ(0.5), scale(.{ 2, 2, 2 }) });
    const p = mulVector(a, .{ 1, 0, 0, 1 });
    try std.testing.expectApproxEqAbs(1 + 2 * @cos(@as(f32, 0.5)), p[0], 1e-6);
    try std.testing.expectApproxEqAbs(2 - 2 * @sin(@as(f32, 0.5)), p[1], 1e-6);
    try std.testing.expectApproxEqAbs(3, p[2], 1e-6);
    try std.testing.expectEqual(mul(identity(), a), a);
}

test perspective {
    // A point on the near plane maps to depth 0, one on the far plane to 1.
    const p = perspective(std.math.pi / 2.0, 1, 1, 100);
    const near = mulVector(p, .{ 0, 0, -1, 1 });
    const far = mulVector(p, .{ 0, 0, -100, 1 });
    try std.testing.expectApproxEqAbs(0, near[2] / near[3], 1e-6);
    try std.testing.expectApproxEqAbs(1, far[2] / far[3], 1e-6);
}
