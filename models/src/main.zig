const std = @import("std");
const pf = @import("platform.zig");
const vx = @import("vulkan_context.zig");
const vk = @import("vk");
const renderer = @import("renderer.zig");
const zm = @import("zmath");

const ResourceLoader = @import("ResourceLoader.zig");

const app_name = "models";

// goal for this experiment:
// - load model(s) and texture(s) form disk
// - draw a bunch of them using multidrawindirect

const UP = zm.f32x4(0.0, -1.0, 0.0, 0.0);

const ObjectData = extern struct {
    mvp: zm.Mat,
};

const Camera = struct {
    position: zm.Vec,
    orientation: zm.Quat,
    fov: f32,
    aspect: f32,
    near: f32,
    far: f32,

    fn vp(camera: Camera) zm.Mat {
        return zm.mul(
            zm.lookAtRh(
                camera.position,
                zm.rotate(camera.orientation, zm.f32x4(1.0, 0.0, 0.0, 1.0)),
                UP,
            ),
            zm.perspectiveFovRh(camera.fov, camera.aspect, camera.near, camera.far),
        );
    }
};

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
        // "res/triangle.obj",
        // "res/quad.obj",
        // "res/smooth_cube.obj",
        "res/bunny.obj",
        // "res/brick.qoi",
        // "res/wood.qoi",
    };
    const resource_handle = try rl.load(&filenames);
    const resources = resource_handle.wait();
    defer resources.deinit();

    try renderer.init();
    defer renderer.deinit();

    // we need the descriptor set layout during pipeline creation
    const data_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .storage_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
    };
    const layout_create_info = vk.DescriptorSetLayoutCreateInfo{
        .binding_count = 1,
        .p_bindings = @ptrCast(&data_layout_binding),
    };
    const descriptor_set_layout =
        try vx.device.createDescriptorSetLayout(&layout_create_info, null);
    defer vx.device.destroyDescriptorSetLayout(descriptor_set_layout, null);

    var pipeline = try renderer.Pipeline.create(descriptor_set_layout);
    defer pipeline.destroy();

    // basically guaranteed, and possible to work around if really needed
    // (could use the swapchain as a color buffer and render a fullscreen quad)
    if (!vx.swapchain_supports_transfer_dst) std.log.err("Surface must support TRANSFER_DST", .{});

    // --- setup drawIndirect ---
    var cursor: usize = 0;
    const max_objects = 4096;

    const indirect_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(vk.DrawIndexedIndirectCommand) * max_objects,
        .usage = .{ .transfer_dst_bit = true, .indirect_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const indirect_buffer = try vx.device.createBuffer(&indirect_buffer_info, null);
    defer vx.device.destroyBuffer(indirect_buffer, null);
    const indirect_buffer_memreq = vx.device.getBufferMemoryRequirements(indirect_buffer);
    std.debug.print("{}\n", .{indirect_buffer_memreq});
    cursor = std.mem.alignForward(usize, cursor, indirect_buffer_memreq.alignment);
    cursor += indirect_buffer_memreq.size;

    const data_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(ObjectData) * max_objects,
        .usage = .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const data_buffer = try vx.device.createBuffer(&data_buffer_info, null);
    defer vx.device.destroyBuffer(data_buffer, null);
    const data_buffer_memreq = vx.device.getBufferMemoryRequirements(data_buffer);
    std.debug.print("{}\n", .{data_buffer_memreq});
    cursor = std.mem.alignForward(usize, cursor, data_buffer_memreq.alignment);
    cursor += data_buffer_memreq.size;

    // seems reasonable to keep this data in host visible/coherent
    // since we just want to refill the buffers every frame
    // though i guess an optimal strategy would separate frequently and infrequently updated data?
    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = cursor,
        .memory_type_index = try vx.findMemoryType(
            indirect_buffer_memreq.memory_type_bits & data_buffer_memreq.memory_type_bits,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        ),
    };
    std.debug.print("{}\n", .{alloc_info});
    const memory = try vx.device.allocateMemory(&alloc_info, null);
    defer vx.device.freeMemory(memory, null);

    cursor = 0;

    cursor = std.mem.alignForward(usize, cursor, indirect_buffer_memreq.alignment);
    try vx.device.bindBufferMemory(indirect_buffer, memory, cursor);
    cursor += indirect_buffer_memreq.size;

    cursor = std.mem.alignForward(usize, cursor, data_buffer_memreq.alignment);
    try vx.device.bindBufferMemory(data_buffer, memory, cursor);
    cursor += data_buffer_memreq.size;

    // --- end setup drawIndirect ---

    var camera = Camera{
        .position = zm.f32x4(10.0, 0.0, 0.0, 1.0),
        .orientation = zm.qidentity(),
        .fov = 70,
        .aspect = 16 / 9, // TODO respect resize
        .near = 0.1,
        .far = 1000.0,
    };
    camera = camera;

    while (!pf.shouldClose()) {
        pf.pollEvents();
        try vx.updateSwapchain();

        // --- fill drawIndirect buffers ---
        cursor = 0;

        cursor = std.mem.alignForward(usize, cursor, indirect_buffer_memreq.alignment);
        const p_indirect: [*]vk.DrawIndexedIndirectCommand =
            @alignCast(@ptrCast(try vx.device.mapMemory(
            memory,
            cursor,
            indirect_buffer_memreq.size,
            .{},
        )));
        var it_models = resources.models.iterator();
        var i: usize = 0;
        while (it_models.next()) |model| {
            p_indirect[i] = vk.DrawIndexedIndirectCommand{
                .index_count = model.value_ptr.index_count,
                .instance_count = 1,
                .first_index = model.value_ptr.index_offset,
                .vertex_offset = @intCast(model.value_ptr.vertex_offset),
                .first_instance = 0,
            };
            i += 1;
        }
        const mdi_draw_count: u32 = @intCast(i);
        vx.device.unmapMemory(memory);
        cursor += indirect_buffer_memreq.size;

        cursor = std.mem.alignForward(usize, cursor, data_buffer_memreq.alignment);
        const p_data: [*]ObjectData = @alignCast(@ptrCast(try vx.device.mapMemory(
            memory,
            cursor,
            data_buffer_memreq.size,
            .{},
        )));
        it_models = resources.models.iterator();
        i = 0;
        while (it_models.next()) |model| {
            _ = model;
            p_data[i] = ObjectData{
                .mvp = zm.mul(
                    zm.translation(0.0, 0.0, @floatFromInt(2 * i)),
                    camera.vp(),
                ),
            };
            i += 1;
        }
        vx.device.unmapMemory(memory);
        std.debug.assert(i == mdi_draw_count);
        cursor += data_buffer_memreq.size;

        // --- end fill drawIndirect buffers ---

        const frame = renderer.getFrameStuff();
        if (try vx.device.waitForFences(
            1,
            @ptrCast(&frame.fence),
            vk.TRUE,
            1000_000_000,
        ) == .timeout) continue; // maybe?
        try vx.device.resetFences(1, @ptrCast(&frame.fence));
        const swapchain_image = vx.getNextSwapchainImage(frame.acquire) catch continue;

        try vx.device.resetDescriptorPool(frame.descriptor_pool, .{});

        var descriptor_set: vk.DescriptorSet = .null_handle;
        try vx.device.allocateDescriptorSets(&.{
            .descriptor_pool = frame.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
        }, @ptrCast(&descriptor_set));

        try vx.device.resetCommandPool(frame.command_pool, .{});

        const descriptor_buffer_info = vk.DescriptorBufferInfo{
            .buffer = data_buffer,
            .offset = 0,
            .range = vk.WHOLE_SIZE,
        };
        const descriptor_write = vk.WriteDescriptorSet{
            .dst_set = descriptor_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_type = .storage_buffer,
            .descriptor_count = 1,
            .p_buffer_info = @ptrCast(&descriptor_buffer_info),
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        vx.device.updateDescriptorSets(1, @ptrCast(&descriptor_write), 0, null);

        var command_buffer: vk.CommandBuffer = .null_handle;
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
            .y = @as(f32, @floatFromInt(swapchain_image.extent.height)),
            .width = @as(f32, @floatFromInt(swapchain_image.extent.width)),
            .height = -@as(f32, @floatFromInt(swapchain_image.extent.height)),
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

        vx.device.cmdBindDescriptorSets(
            command_buffer,
            .graphics,
            pipeline.layout,
            0,
            1,
            @ptrCast(&descriptor_set),
            0,
            null,
        );

        vx.device.cmdDrawIndexedIndirect(
            command_buffer,
            indirect_buffer,
            0,
            mdi_draw_count,
            @sizeOf(vk.DrawIndexedIndirectCommand),
        );

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
