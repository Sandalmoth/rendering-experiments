const std = @import("std");
const vk = @import("vk");
const vx = @import("vulkan_context.zig");

pub const in_flight = 2;

var current_frame: u64 = 0;
var sync_image_acquired: [in_flight]vk.Semaphore = [_]vk.Semaphore{.null_handle} ** in_flight;
var sync_image_released: [in_flight]vk.Semaphore = [_]vk.Semaphore{.null_handle} ** in_flight;
var sync_image_fence: [in_flight]vk.Fence = [_]vk.Fence{.null_handle} ** in_flight;
var command_pools: [2]vk.CommandPool = [_]vk.CommandPool{.null_handle} ** in_flight;

const FrameStuff = struct {
    acquire: vk.Semaphore,
    release: vk.Semaphore,
    fence: vk.Fence,
    command_pool: vk.CommandPool,
};
pub fn getFrameStuff() FrameStuff {
    return .{
        .acquire = sync_image_acquired[current_frame % in_flight],
        .release = sync_image_released[current_frame % in_flight],
        .fence = sync_image_fence[current_frame % in_flight],
        .command_pool = command_pools[current_frame % in_flight],
    };
}

pub fn init() !void {
    for (0..in_flight) |i| {
        errdefer deinit();
        sync_image_acquired[i] = try vx.device.createSemaphore(&.{}, null);
        sync_image_released[i] = try vx.device.createSemaphore(&.{}, null);
        sync_image_fence[i] = try vx.device.createFence(&.{
            .flags = .{ .signaled_bit = true },
        }, null);
        command_pools[i] = try vx.device.createCommandPool(&.{
            .flags = .{},
            .queue_family_index = vx.graphics_compute_queue.family,
        }, null);
    }
}

pub fn deinit() void {
    for (0..in_flight) |i| {
        if (sync_image_acquired[i] != .null_handle) {
            vx.device.destroySemaphore(sync_image_acquired[i], null);
            sync_image_acquired[i] = .null_handle;
        }
        if (sync_image_released[i] != .null_handle) {
            vx.device.destroySemaphore(sync_image_released[i], null);
            sync_image_released[i] = .null_handle;
        }
        if (sync_image_fence[i] != .null_handle) {
            vx.device.destroyFence(sync_image_fence[i], null);
            sync_image_fence[i] = .null_handle;
        }
        if (command_pools[i] != .null_handle) {
            vx.device.destroyCommandPool(command_pools[i], null);
            command_pools[i] = .null_handle;
        }
    }
}

pub const Vertex = struct {
    position: @Vector(3, f32),
    normal: @Vector(3, f32),
    uv: @Vector(2, f32),

    const n_fields = std.meta.fields(Vertex).len;

    pub fn getInputBindingDescription() vk.VertexInputBindingDescription {
        return vk.VertexInputBindingDescription{
            .binding = 0, // fine for this design (one big vertex buffer)?, other considerations?
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };
    }

    pub fn getInputAttributeDescription() [n_fields]vk.VertexInputAttributeDescription {
        // we could generate this with comptime, dunno if it's a good idea though
        var result: [n_fields]vk.VertexInputAttributeDescription = undefined;
        result[0] = vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 0,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "position"),
        };
        result[1] = vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 1,
            .format = .r32g32b32_sfloat,
            .offset = @offsetOf(Vertex, "normal"),
        };
        result[2] = vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = 2,
            .format = .r32g32_sfloat,
            .offset = @offsetOf(Vertex, "uv"),
        };
        return result;
    }
};

pub const Pipeline = struct {
    // i feel like I should try to make a rendergraph as a next step

    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,

    pub fn create() !Pipeline {
        const vert = try loadShader("res/shaders/shader.vert.spv");
        defer vx.device.destroyShaderModule(vert, null);
        const frag = try loadShader("res/shaders/shader.frag.spv");
        defer vx.device.destroyShaderModule(frag, null);

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
        };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = @intCast(dynamic_states.len),
            .p_dynamic_states = &dynamic_states,
        };

        const vertex_binding_description = Vertex.getInputBindingDescription();
        const vertex_attribute_description = Vertex.getInputAttributeDescription();
        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&vertex_binding_description),
            .vertex_attribute_description_count = @intCast(vertex_attribute_description.len),
            .p_vertex_attribute_descriptions = @ptrCast(&vertex_attribute_description),
        };

        const pipeline_assembly_info = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .triangle_list,
            .primitive_restart_enable = vk.FALSE,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) },
        }; // biggest possible scissor, basically just render everything
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = null, // dynamic
            .scissor_count = 1,
            .p_scissors = @ptrCast(&scissor),
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

        const depth_stencil_state = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = vk.TRUE,
            .depth_write_enable = vk.TRUE,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = vk.FALSE,
            .stencil_test_enable = vk.FALSE,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 0.0,
        };

        const layout_info = vk.PipelineLayoutCreateInfo{};
        const pipeline_layout = try vx.device.createPipelineLayout(&layout_info, null);

        const color_attachment_formats = [_]vk.Format{.r16g16b16a16_sfloat};
        const dynamic_info = vk.PipelineRenderingCreateInfo{
            .color_attachment_count = 1,
            .p_color_attachment_formats = &color_attachment_formats,
            .depth_attachment_format = .d32_sfloat,
            .stencil_attachment_format = .undefined,
            .view_mask = 0, // what even is this?
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
        _ = try vx.device.createGraphicsPipelines(
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

    pub fn destroy(pipeline: *Pipeline) void {
        vx.device.destroyPipeline(pipeline.pipeline, null);
        vx.device.destroyPipelineLayout(pipeline.layout, null);
        pipeline.* = undefined;
    }
};

fn loadShader(path: []const u8) !vk.ShaderModule {
    // IMPORVEMENT: inelegant use of the page allocator :(
    const bytecode = try std.fs.cwd().readFileAlloc(
        std.heap.page_allocator,
        path,
        16 * 1024 * 1024,
    );
    defer std.heap.page_allocator.free(bytecode);
    std.debug.assert((@intFromPtr(bytecode.ptr) & 3) == 0); // needs to be aligned to u32

    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = bytecode.len,
        .p_code = @alignCast(@ptrCast(bytecode.ptr)),
    };
    return try vx.device.createShaderModule(&create_info, null);
}

pub fn cmdChangeImageLayout(
    command_buffer: vk.CommandBuffer,
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
) void {
    const swapchain_write_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .all_commands_bit = true },
        .src_access_mask = .{ .memory_write_bit = true },
        .dst_stage_mask = .{ .all_commands_bit = true },
        .dst_access_mask = .{
            .memory_write_bit = true,
            .memory_read_bit = true,
        },
        .old_layout = old_layout,
        .new_layout = new_layout,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
    };
    const swapchain_write_dependency_info = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&swapchain_write_barrier),
    };
    vx.device.cmdPipelineBarrier2(command_buffer, &swapchain_write_dependency_info);
}

pub fn present(
    wait: vk.Semaphore,
    image_index: u32,
) !void {
    const present_info = vk.PresentInfoKHR{
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&vx.swapchain),
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&wait),
        .p_image_indices = @ptrCast(&image_index),
    };
    // what happens to the semaphores if resize fails here?
    _ = try vx.present_queue.proxy().presentKHR(&present_info);

    current_frame += 1;
}
