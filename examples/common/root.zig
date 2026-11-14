//! Code shared by the examples.
pub const app = @import("app.zig");
pub const math = @import("math.zig");
pub const util = @import("util.zig");

pub const nsString = util.nsString;
pub const release = util.release;

test {
    _ = math;
}
