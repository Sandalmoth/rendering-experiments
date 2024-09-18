const std = @import("std");

const glfw = @import("zglfw");

const gctx = @import("graphics_context.zig");

const app_name = "triangle";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    std.debug.assert(glfw.isVulkanSupported()); // IMPROVEMENT: print useful info

    glfw.windowHintTyped(.client_api, .no_api);
    const window = try glfw.Window.create(1320, 720, "triangle", null);
    defer window.destroy();

    try gctx.init(alloc, app_name, window);
    defer gctx.deinit();

    while (!window.shouldClose()) {
        glfw.pollEvents();
    }
}
