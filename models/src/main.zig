const std = @import("std");
const pf = @import("platform.zig");
const vx = @import("vulkan_context.zig");
const vk = @import("vk");
const renderer = @import("renderer.zig");

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
    const resource_handle = try rl.load(&filenames);
    const resources = resource_handle.wait();
    defer resources.deinit();

    try renderer.init();
    defer renderer.deinit();

    var pipeline = try renderer.Pipeline.create();
    defer pipeline.destroy();

    // basically guaranteed, and possible to work around if really needed
    // (could use the swapchain as a color buffer and render a fullscreen quad)
    if (!vx.swapchain_supports_transfer_dst) std.log.err("Surface must support TRANSFER_DST", .{});

    while (!pf.shouldClose()) {
        pf.pollEvents();
        try vx.updateSwapchain();

        const frame = renderer.getFrameStuff();
        if (try vx.device.waitForFences(
            1,
            @ptrCast(&frame.fence),
            vk.TRUE,
            1000_000_000,
        ) == .timeout) continue; // maybe?
        try vx.device.resetFences(1, @ptrCast(&frame.fence));
        const swapchain_image = vx.getNextSwapchainImage(frame.acquire) catch continue;

        try vx.device.resetCommandPool(frame.command_pool, .{});

        var command_buffer: vk.CommandBuffer = undefined;
        try vx.device.allocateCommandBuffers(&.{
            .command_pool = frame.command_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&command_buffer));

        try vx.device.beginCommandBuffer(command_buffer, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        renderer.cmdChangeImageLayout(
            command_buffer,
            swapchain_image.image,
            .undefined,
            .color_attachment_optimal,
        );

        // DRAW STUFF
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
        const color_attachement_info = vk.RenderingAttachmentInfoKHR{
            .image_view = swapchain_image.view,
            .resolve_mode = .{},
            .image_layout = .color_attachment_optimal,
            .resolve_image_view = .null_handle,
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = .{ .color = clear_color },
        };
        const render_info = vk.RenderingInfoKHR{
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachement_info),
            .layer_count = 1,
            .view_mask = 0,
            .render_area = .{
                .extent = swapchain_image.extent,
                .offset = .{ .x = 0, .y = 0 },
            },
        };
        vx.device.cmdBeginRendering(command_buffer, &render_info);

        vx.device.cmdBindPipeline(command_buffer, .graphics, pipeline.pipeline);
        const viewport: vk.Viewport = .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(swapchain_image.extent.width)),
            .height = @as(f32, @floatFromInt(swapchain_image.extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };
        vx.device.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));

        const vertex_buffer_offsets: vk.DeviceSize = 0;
        vx.device.cmdBindVertexBuffers(
            command_buffer,
            0,
            1,
            @ptrCast(&resources.vertex_buffer),
            @ptrCast(&vertex_buffer_offsets),
        );

        vx.device.cmdBindIndexBuffer(
            command_buffer,
            resources.index_buffer,
            0,
            .uint32,
        );

        var it_models = resources.models.iterator();
        while (it_models.next()) |model| {
            vx.device.cmdDrawIndexed(
                command_buffer,
                model.value_ptr.index_count,
                1,
                0,
                @intCast(model.value_ptr.vertex_offset),
                0,
            );
        }

        vx.device.cmdEndRendering(command_buffer);
        // END DRAW STUFF

        renderer.cmdChangeImageLayout(
            command_buffer,
            swapchain_image.image,
            .color_attachment_optimal,
            .present_src_khr,
        );

        try vx.device.endCommandBuffer(command_buffer);

        const wait_semaphore_submit_info = vk.SemaphoreSubmitInfo{
            .semaphore = frame.acquire,
            .device_index = 0,
            .value = 0, // i think this only matters if it's a timeline semaphore?
            .stage_mask = .{ .color_attachment_output_bit = true },
        };
        const signal_semaphore_submit_info = vk.SemaphoreSubmitInfo{
            .semaphore = frame.release,
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
        try vx.graphics_compute_queue.proxy().submit2(1, @ptrCast(&submit_info), frame.fence);

        try renderer.present(frame.release, swapchain_image.image_index);
    }

    try vx.device.deviceWaitIdle();
}
