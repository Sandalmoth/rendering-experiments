const std = @import("std");
const pf = @import("platform.zig");
const vx = @import("vulkan_context.zig");

const app_name = "streaming-models";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try pf.init(app_name, 1280, 720);
    defer pf.deinit();

    try vx.init(alloc, app_name);
    defer vx.deinit();

    while (!pf.shouldClose()) {
        pf.pollEvents();
    }
}
