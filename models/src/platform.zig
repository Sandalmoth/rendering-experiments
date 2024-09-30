const std = @import("std");
const glfw = @import("zglfw");
const vk = @import("vk");

const vx = @import("vulkan_context.zig");

const log = std.log.scoped(.platform);

extern fn glfwGetInstanceProcAddress(
    instance: vk.Instance,
    procname: [*:0]const u8,
) vk.PfnVoidFunction;

extern fn glfwCreateWindowSurface(
    instance: vk.Instance,
    window: *glfw.Window,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
    surface: *vk.SurfaceKHR,
) vk.Result;

pub const getInstanceProcAddress = glfwGetInstanceProcAddress;

// global state section
var window: *glfw.Window = undefined;
var mouse_x: f32 = std.math.nan(f32);
var mouse_y: f32 = std.math.nan(f32);
// end global state section

pub fn init(app_name: [:0]const u8, width: i32, height: i32) !void {
    try glfw.init();

    glfw.windowHintTyped(.client_api, .no_api);
    window = try glfw.Window.create(width, height, app_name, null);
    _ = window.setFramebufferSizeCallback(framebufferResizeCallback);

    window.setInputMode(.cursor, glfw.Cursor.Mode.disabled);
}

pub fn isDown(key: glfw.Key) bool {
    return window.getKey(key) == .press;
}

const MouseMove = struct { dx: f32, dy: f32 };
pub fn getMouseMove() MouseMove {
    const mouse_pos = window.getCursorPos();
    const xprev = mouse_x;
    const yprev = mouse_y;
    mouse_x = @floatCast(mouse_pos[0]);
    mouse_y = @floatCast(mouse_pos[1]);
    if (std.math.isNan(xprev)) return .{ .dx = 0, .dy = 0 };
    return .{
        .dx = mouse_x - xprev,
        .dy = mouse_y - yprev,
    };
}

pub fn deinit() void {
    glfw.terminate();
    window.destroy();
}

pub fn shouldClose() bool {
    return window.shouldClose();
}

pub fn pollEvents() void {
    glfw.pollEvents();
}

// ### functions that interact with vulkan_context ###
fn framebufferResizeCallback(_: *glfw.Window, _: i32, _: i32) callconv(.C) void {
    vx.rebuild_swapchain = true;
}

pub fn getRequiredInstanceExtensions() ![][*:0]const u8 {
    return try glfw.getRequiredInstanceExtensions();
}

pub fn createWindowSurface(instance: vk.Instance) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    const success = glfwCreateWindowSurface(instance, window, null, &surface);
    if (success != .success) return error.SurfaceCreateFailed;
    return surface;
}

pub fn getFramebufferSize() vk.Extent2D {
    const framebuffer_size = window.getFramebufferSize();
    return .{
        .width = @intCast(framebuffer_size[0]),
        .height = @intCast(framebuffer_size[1]),
    };
}
// ### end functions that interact with vulkan_context ###
