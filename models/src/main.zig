const std = @import("std");
const pf = @import("platform.zig");
const vx = @import("vulkan_context.zig");

const ResourceLoader = @import("ResourceLoader.zig");

const app_name = "models";

// goal for this experiment:
// - load model(s) and texture(s) form disk
// - draw a bunch of them using multidrawindirect

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    try pf.init(app_name, 1280, 720);
    defer pf.deinit();

    // might be neater to provide callbacks for the important functions
    // rather than to have the context pull them directly from the platform layer
    try vx.init(alloc, app_name);
    defer vx.deinit();

    var rl = try ResourceLoader.init(alloc);
    defer rl.deinit();

    const filenames = [_][]const u8{
        "res/suzanne.obj",
        "res/bunny.obj",
        "res/brick.qoi",
        "res/wood.qoi",
    };
    const resources = try rl.load(&filenames);
    _ = resources;

    // basically guaranteed, and possible to work around if really needed
    // (could use the swapchain as a color buffer and render a fullscreen quad)
    if (!vx.swapchain_supports_transfer_dst) std.log.err("Surface must support TRANSFER_DST", .{});

    while (!pf.shouldClose()) {
        pf.pollEvents();
        try vx.updateSwapchain();
    }
}
