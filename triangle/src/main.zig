const std = @import("std");

const glfw = @import("zglfw");
const vk = @import("vk.zig");

const gctx = @import("graphics_context.zig");

const app_name = "triangle";

fn framebufferResizeCallback(
    window: *glfw.Window,
    width: i32,
    height: i32,
) callconv(.C) void {
    _ = window;
    _ = width;
    _ = height;
    // IMPROVEMENT: how can we handle errors here?
    // an option could be to instead set a flag, and recreate in the render loop
    gctx.recreateSwapchain() catch {
        std.debug.print("resize failed\n", .{});
    };
}

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

    _ = window.setFramebufferSizeCallback(framebufferResizeCallback);

    std.debug.assert(gctx.frames_in_flight == 2);
    // TODO support >2 frames in flight?
    var command_pools: [2]vk.CommandPool = undefined;
    command_pools[0] = try gctx.device.createCommandPool(&.{
        .flags = .{},
        .queue_family_index = gctx.graphics_queue.family,
    }, null);
    defer gctx.device.destroyCommandPool(command_pools[0], null);
    command_pools[1] = try gctx.device.createCommandPool(&.{
        .flags = .{},
        .queue_family_index = gctx.graphics_queue.family,
    }, null);
    defer gctx.device.destroyCommandPool(command_pools[1], null);

    while (!window.shouldClose()) {
        glfw.pollEvents();
        if (window.getKey(.escape) == .press) window.setShouldClose(true);

        const sync = gctx.getSync();
        // IMPORVEMENT: what can this return? what should happen on timeout?
        // I'm thinking we should just continue our game loop and skip rendering this time around
        _ = try gctx.device.waitForFences(1, @ptrCast(&sync.fence), vk.TRUE, 1000_000_000);
        try gctx.device.resetFences(1, @ptrCast(&sync.fence));

        // this can fail in the same way, same consideration?
        const swapchain_image = try gctx.getNextSwapchainImage();

        try gctx.device.resetCommandPool(
            command_pools[gctx.current_frame % gctx.frames_in_flight],
            .{},
        );

        var command_buffer: vk.CommandBuffer = undefined;
        try gctx.device.allocateCommandBuffers(&.{
            .command_pool = command_pools[gctx.current_frame % gctx.frames_in_flight],
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));

        try gctx.device.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        const swapchain_write_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{
                .memory_write_bit = true,
                .memory_read_bit = true,
            },
            .old_layout = .undefined,
            .new_layout = .general,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = swapchain_image.image,
        };
        const swapchain_write_dependency_info = vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&swapchain_write_barrier),
        };
        gctx.device.cmdPipelineBarrier2(command_buffer, &swapchain_write_dependency_info);

        var grey: f32 = @floatCast(0.5 + 0.5 * @sin(
            3.14e-3 * @as(f64, @floatFromInt(std.time.milliTimestamp())),
        ));
        grey = std.math.clamp(grey, 0.0, 1.0);
        const clear_color = vk.ClearColorValue{ .float_32 = .{
            grey,
            grey,
            grey,
            1.0,
        } };
        const clear_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        };
        gctx.device.cmdClearColorImage(
            command_buffer,
            swapchain_image.image,
            .general,
            &clear_color,
            1,
            @ptrCast(&clear_range),
        );

        const swapchain_present_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{
                .memory_write_bit = true,
                .memory_read_bit = true,
            },
            .old_layout = .general,
            .new_layout = .present_src_khr,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = swapchain_image.image,
        };
        const swapchain_present_dependency_info = vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&swapchain_present_barrier),
        };
        gctx.device.cmdPipelineBarrier2(command_buffer, &swapchain_present_dependency_info);

        try gctx.device.endCommandBuffer(command_buffer);

        const wait_semaphore_submit_info = vk.SemaphoreSubmitInfo{
            .semaphore = sync.acquire,
            .device_index = 0,
            .value = 0, // i think this only matters if it's a timeline semaphore?
            .stage_mask = .{ .color_attachment_output_bit = true },
        };
        const signal_semaphore_submit_info = vk.SemaphoreSubmitInfo{
            .semaphore = sync.release,
            .device_index = 0,
            .value = 0,
            .stage_mask = .{ .all_graphics_bit = true },
        };
        const command_buffer_submit_info = vk.CommandBufferSubmitInfo{
            .command_buffer = command_buffer,
            .device_mask = 0, // we're just using one device
        };
        const submit_info = vk.SubmitInfo2{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = @ptrCast(&wait_semaphore_submit_info),
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = @ptrCast(&signal_semaphore_submit_info),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&command_buffer_submit_info),
        };
        try gctx.graphics_queue.proxy().submit2(1, @ptrCast(&submit_info), sync.fence);

        const present_info = vk.PresentInfoKHR{
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&gctx.swapchain),
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&sync.release),
            .p_image_indices = @ptrCast(&swapchain_image.image_index),
        };
        // what happens to the semaphores if resize fails here?
        _ = try gctx.present_queue.proxy().presentKHR(&present_info);
        gctx.current_frame += 1;
    }

    try gctx.device.deviceWaitIdle();

    // you cant defer commands that can fail (sensible I suppose)
    // so manually clear these to destroy the command bufferst before destroying the pools
    try gctx.device.resetCommandPool(command_pools[0], .{});
    try gctx.device.resetCommandPool(command_pools[1], .{});
}
