const std = @import("std");
const vx = @import("vulkan_context.zig");

pub const Vertex = struct {
    position: @Vector(3, f32),
    normal: @Vector(3, f32),
    uv: @Vector(2, f32),
};
