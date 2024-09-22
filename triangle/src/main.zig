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

    var pipeline = try Pipeline.create();
    defer pipeline.destroy();

    const rendertarget_extent = vk.Extent3D{ .width = 1920, .height = 1080, .depth = 1 };
    const rendertarget_image_create_info = vk.ImageCreateInfo{
        .image_type = .@"2d",
        .format = .r16g16b16a16_sfloat,
        .extent = rendertarget_extent,
        .usage = .{
            .transfer_src_bit = true,
            .transfer_dst_bit = true,
            // .storage_bit = true, // i think we don't want this as it disables compression?
            .color_attachment_bit = true,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 1,
        .p_queue_family_indices = @ptrCast(&gctx.graphics_queue.family),
        .initial_layout = .undefined,
    };
    var rendertarget = try gctx.vk_alloc.createImage(
        rendertarget_extent,
        &rendertarget_image_create_info,
    );
    defer gctx.vk_alloc.destroyImage(rendertarget);
    const rendertarget_view_create_info = vk.ImageViewCreateInfo{
        .image = rendertarget.image,
        .format = .r16g16b16a16_sfloat,
        .view_type = .@"2d",
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    rendertarget.view = try gctx.device.createImageView(&rendertarget_view_create_info, null);
    defer gctx.device.destroyImageView(rendertarget.view, null);

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
            .new_layout = .transfer_dst_optimal,
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

        const rendertarget_draw_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{
                .memory_write_bit = true,
                .memory_read_bit = true,
            },
            .old_layout = .undefined,
            .new_layout = .color_attachment_optimal,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = rendertarget.image,
        };
        const rendertarget_draw_dependency_info = vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&rendertarget_draw_barrier),
        };
        gctx.device.cmdPipelineBarrier2(command_buffer, &rendertarget_draw_dependency_info);

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
            .image_view = rendertarget.view,
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
                .extent = .{
                    .width = rendertarget_extent.width,
                    .height = rendertarget_extent.height,
                },
                .offset = .{ .x = 0, .y = 0 },
            },
        };
        gctx.device.cmdBeginRendering(command_buffer, &render_info);

        gctx.device.cmdBindPipeline(command_buffer, .graphics, pipeline.pipeline);
        const viewport: vk.Viewport = .{
            .x = 0,
            .y = 0,
            .width = @as(f32, @floatFromInt(rendertarget_extent.width)),
            .height = @as(f32, @floatFromInt(rendertarget_extent.height)),
            .min_depth = 0,
            .max_depth = 1,
        };
        gctx.device.cmdSetViewport(command_buffer, 0, 1, @ptrCast(&viewport));
        const scissor: vk.Rect2D = .{
            .extent = .{
                .width = rendertarget_extent.width,
                .height = rendertarget_extent.height,
            },
            .offset = .{ .x = 0, .y = 0 },
        };
        gctx.device.cmdSetScissor(command_buffer, 0, 1, @ptrCast(&scissor));

        gctx.device.cmdDraw(command_buffer, 3, 1, 0, 0);

        gctx.device.cmdEndRendering(command_buffer);
        // END DRAW STUFF

        const rendertarget_read_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{
                .memory_write_bit = true,
                .memory_read_bit = true,
            },
            .old_layout = .color_attachment_optimal,
            .new_layout = .transfer_src_optimal,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = rendertarget.image,
        };
        const rendertarget_read_dependency_info = vk.DependencyInfo{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&rendertarget_read_barrier),
        };
        gctx.device.cmdPipelineBarrier2(command_buffer, &rendertarget_read_dependency_info);

        const blit_region = vk.ImageBlit2{
            .src_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{
                    .x = @intCast(rendertarget_extent.width),
                    .y = @intCast(rendertarget_extent.height),
                    .z = 1,
                },
            },
            .dst_offsets = .{
                .{ .x = 0, .y = 0, .z = 0 },
                .{
                    .x = @intCast(gctx.swapchain_extent.width),
                    .y = @intCast(gctx.swapchain_extent.height),
                    .z = 1,
                },
            },
            .src_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .dst_subresource = .{
                .aspect_mask = .{ .color_bit = true },
                .mip_level = 0,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        const blit_info = vk.BlitImageInfo2{
            .src_image = rendertarget.image,
            .dst_image = swapchain_image.image,
            .src_image_layout = .transfer_src_optimal,
            .dst_image_layout = .transfer_dst_optimal,
            .region_count = 1,
            .p_regions = @ptrCast(&blit_region),
            .filter = .linear,
        };
        gctx.device.cmdBlitImage2(command_buffer, &blit_info);

        const swapchain_present_barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = .{ .all_commands_bit = true },
            .src_access_mask = .{ .memory_write_bit = true },
            .dst_stage_mask = .{ .all_commands_bit = true },
            .dst_access_mask = .{
                .memory_write_bit = true,
                .memory_read_bit = true,
            },
            .old_layout = .transfer_dst_optimal,
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

const Pipeline = struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,

    fn create() !Pipeline {
        const vert = try loadShader("res/shaders/shader.vert");
        defer gctx.device.destroyShaderModule(vert, null);
        const frag = try loadShader("res/shaders/shader.frag");
        defer gctx.device.destroyShaderModule(frag, null);

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = "main",
            },
            .{
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = "main",
            },
        };

        const dynamic_states = [_]vk.DynamicState{
            .viewport,
            .scissor,
        };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = @intCast(dynamic_states.len),
            .p_dynamic_states = &dynamic_states,
        };

        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 0,
            .vertex_attribute_description_count = 0,
        };

        const pipeline_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = vk.FALSE,
            .rasterizer_discard_enable = vk.FALSE,
            .polygon_mode = .fill,
            .line_width = 1.0,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = vk.FALSE,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sample_shading_enable = vk.FALSE,
            .rasterization_samples = .{ .@"1_bit" = true },
            .min_sample_shading = 1.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = vk.FALSE,
            .alpha_to_one_enable = vk.FALSE,
        };

        const blending = [_]vk.PipelineColorBlendAttachmentState{
            .{
                .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
                .blend_enable = vk.FALSE,
                .src_color_blend_factor = .one,
                .dst_color_blend_factor = .zero,
                .color_blend_op = .add,
                .src_alpha_blend_factor = .one,
                .dst_alpha_blend_factor = .zero,
                .alpha_blend_op = .add,
            },
        };

        const blend_info = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = vk.FALSE,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = &blending,
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        const layout_info = vk.PipelineLayoutCreateInfo{};
        const pipeline_layout = try gctx.device.createPipelineLayout(&layout_info, null);

        const color_attachment_formats = [_]vk.Format{.r16g16b16a16_sfloat};
        const dynamic_info = vk.PipelineRenderingCreateInfo{
            .color_attachment_count = 1,
            .p_color_attachment_formats = &color_attachment_formats,
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
            .view_mask = 0, // what even is this?
        };

        const depth_stencil_state = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.FALSE,
            .depth_write_enable = vk.FALSE,
            .depth_compare_op = .never,
            .depth_bounds_test_enable = vk.FALSE,
            .stencil_test_enable = vk.FALSE,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 0.0,
        };

        const create_info = vk.GraphicsPipelineCreateInfo{
            .stage_count = @intCast(shader_stages.len),
            .p_stages = @ptrCast(&shader_stages[0]),
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &pipeline_assembly_info,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterizer,
            .p_multisample_state = &multisampling,
            .p_depth_stencil_state = &depth_stencil_state,
            .p_color_blend_state = &blend_info,
            .p_dynamic_state = &dynamic_state,
            .layout = pipeline_layout,
            .render_pass = .null_handle, // NOTE dynamic rendering
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
            .p_next = &dynamic_info,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try gctx.device.createGraphicsPipelines(
            .null_handle,
            1,
            @ptrCast(&create_info),
            null,
            @ptrCast(&pipeline),
        );

        return .{
            .layout = pipeline_layout,
            .pipeline = pipeline,
        };
    }

    fn destroy(pipeline: *Pipeline) void {
        gctx.device.destroyPipeline(pipeline.pipeline, null);
        gctx.device.destroyPipelineLayout(pipeline.layout, null);
        pipeline.* = undefined;
    }
};

fn loadShader(path: []const u8) !vk.ShaderModule {
    const bytecode = try std.fs.cwd().readFileAlloc(gctx.alloc, path, 16 * 1024 * 1024);
    defer gctx.alloc.free(bytecode);
    std.debug.assert((@intFromPtr(bytecode.ptr) & 3) == 0); // needs to be aligned to u32

    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = @alignCast(@ptrCast(bytecode.ptr)),
    };
    return try gctx.device.createShaderModule(&create_info, null);
}
