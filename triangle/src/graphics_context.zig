const std = @import("std");

const glfw = @import("zglfw");
const vk = @import("vk.zig");

const log = std.log.scoped(.graphics_context);

// config section
const apis: []const vk.ApiInfo = &.{
    .{
        .base_commands = .{
            .createInstance = true,
            .getInstanceProcAddr = true,
            .enumerateInstanceExtensionProperties = true,
            .enumerateInstanceLayerProperties = true,
        },
        .instance_commands = .{
            .destroyInstance = true,
            .enumeratePhysicalDevices = true,
            .enumerateDeviceExtensionProperties = true,
            .getPhysicalDeviceProperties = true,
            .getPhysicalDeviceMemoryProperties = true,
            .getPhysicalDeviceFeatures = true,
            .getPhysicalDeviceQueueFamilyProperties = true,
            .getPhysicalDeviceSurfaceSupportKHR = true,
            .destroySurfaceKHR = true,
            .createDevice = true,
            .getDeviceProcAddr = true,
            .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
            .getPhysicalDeviceSurfaceFormatsKHR = true,
            .getPhysicalDeviceSurfacePresentModesKHR = true,
        },
        .device_commands = .{
            .destroyDevice = true,
            .getDeviceQueue = true,
            .createImageView = true,
            .destroyImageView = true,
            .createSwapchainKHR = true,
            .destroySwapchainKHR = true,
            .getSwapchainImagesKHR = true,
        },
    },
};

const api_version = vk.API_VERSION_1_3;

const instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
};

const layers = [_][*:0]const u8{};
const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const enable_validation = @import("builtin").mode == .Debug;

const device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
};

const device_features = vk.PhysicalDeviceFeatures{};

const swapchain_surface_formats = [_]vk.SurfaceFormatKHR{
    // ranking of preferred formats for the swapchain surfaces
    // if none are present, the first format from getPhysicalDeviceSurfaceFormats is used
    .{ .format = vk.Format.b8g8r8a8_srgb, .color_space = vk.ColorSpaceKHR.srgb_nonlinear_khr },
    .{ .format = vk.Format.r8g8b8a8_srgb, .color_space = vk.ColorSpaceKHR.srgb_nonlinear_khr },
};
// end config section

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

extern fn glfwGetInstanceProcAddress(
    instance: vk.Instance,
    procname: [*:0]const u8,
) vk.PfnVoidFunction;

extern fn glfwGetPhysicalDevicePresentationSupport(
    instance: vk.Instance,
    pdev: vk.PhysicalDevice,
    queuefamily: u32,
) c_int;

extern fn glfwCreateWindowSurface(
    instance: vk.Instance,
    window: *glfw.Window,
    allocation_callbacks: ?*const vk.AllocationCallbacks,
    surface: *vk.SurfaceKHR,
) vk.Result;

// global state section
var alloc: std.mem.Allocator = undefined;
var frame_arena: std.heap.ArenaAllocator = undefined;
var frame_alloc: std.mem.Allocator = undefined;

var vkb: BaseDispatch = undefined;
var instance: Instance = undefined;
var device: Device = undefined;

var surface: vk.SurfaceKHR = undefined;
var physical_device: vk.PhysicalDevice = undefined;
var physical_device_properties: vk.PhysicalDeviceProperties = undefined;
var physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties = undefined;
var physical_device_features: vk.PhysicalDeviceFeatures = undefined;

var graphics_queue: Queue = undefined;
var present_queue: Queue = undefined;

var swapchain: vk.SwapchainKHR = undefined;
var swapchain_format: vk.Format = undefined;
var swapchain_extent: vk.Extent2D = undefined;
var swapchain_images: []vk.Image = &.{};
var swapchain_views: []vk.ImageView = &.{};
var swapchain_supports_transfer_dst: bool = false;
// end global state section

pub fn init(_alloc: std.mem.Allocator, app_name: [*:0]const u8, window: *glfw.Window) !void {
    alloc = _alloc;
    frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer frame_arena.deinit();
    frame_alloc = frame_arena.allocator();
    vkb = try BaseDispatch.load(glfwGetInstanceProcAddress);

    try initInstance(app_name);
    errdefer deinitInstance();
    try createSurface(window);
    errdefer destroySurface();
    const physical_device_candidate = try pickPhysicalDevice();
    try initDevice(physical_device_candidate);
    errdefer deinitDevice();
    try createSwapchain(window);
    errdefer destroySwapchain();

    _ = frame_arena.reset(.retain_capacity);
}

pub fn deinit() void {
    destroySwapchain();
    deinitDevice();
    destroySurface();
    deinitInstance();
    frame_arena.deinit();
}

fn initInstance(app_name: [*:0]const u8) !void {
    const all_layers = if (enable_validation) layers ++ validation_layers else layers;
    if (!try checkLayerSupport(&all_layers)) {
        return error.UnsupportedLayer;
    }

    // i can't find any info on whether duplication is allowed, so deduplicate just in case
    const glfw_extensions = try glfw.getRequiredInstanceExtensions();
    var all_extensions = std.ArrayList([*:0]const u8).init(frame_alloc);
    try all_extensions.appendSlice(glfw_extensions);
    outer: for (instance_extensions) |ext1| {
        for (all_extensions.items) |ext2| if (std.mem.eql(
            u8,
            std.mem.sliceTo(ext1, 0),
            std.mem.sliceTo(ext2, 0),
        )) continue :outer;
        try all_extensions.append(ext1);
    }
    if (!try checkInstanceExtensionSupport(all_extensions.items)) {
        return error.UnsupportedInstanceExtension;
    }

    const app_info = vk.ApplicationInfo{
        .p_application_name = app_name,
        .application_version = 0,
        .p_engine_name = app_name,
        .engine_version = 0,
        .api_version = api_version,
    };
    const create_info = vk.InstanceCreateInfo{
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(all_layers.len),
        .pp_enabled_layer_names = &all_layers,
        .enabled_extension_count = @intCast(all_extensions.items.len),
        .pp_enabled_extension_names = all_extensions.items.ptr,
    };
    // IMPROVEMENT: could we test if api_version is supported before creating the instance?
    const instance_handle = try vkb.createInstance(&create_info, null);
    const vki = try alloc.create(InstanceDispatch);
    errdefer alloc.destroy(vki);
    vki.* = try InstanceDispatch.load(instance_handle, vkb.dispatch.vkGetInstanceProcAddr);
    instance = Instance.init(instance_handle, vki);
}

fn deinitInstance() void {
    instance.destroyInstance(null);
    alloc.destroy(instance.wrapper);
}

fn checkInstanceExtensionSupport(required_exts: []const [*:0]const u8) !bool {
    const available_exts = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, frame_alloc);

    for (required_exts) |req| {
        const req_name = std.mem.sliceTo(req, 0);
        var supported = false;

        for (available_exts) |ava| {
            const ava_name = std.mem.sliceTo(&ava.extension_name, 0);
            if (!std.mem.eql(u8, req_name, ava_name)) continue;
            supported = true;
            break;
        }

        if (!supported) {
            log.err("Unsupported instance extension: {s}", .{req_name});
            return false;
        }
    }
    return true;
}

fn checkLayerSupport(required_layers: []const [*:0]const u8) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(frame_alloc);

    for (required_layers) |req| {
        const req_name = std.mem.sliceTo(req, 0);
        var supported = false;

        for (available_layers) |ava| {
            const ava_name = std.mem.sliceTo(&ava.layer_name, 0);
            if (!std.mem.eql(u8, req_name, ava_name)) continue;
            supported = true;
            break;
        }

        if (!supported) {
            log.err("Unsupported layer: {s}", .{req_name});
            return false;
        }
    }
    return true;
}

fn createSurface(window: *glfw.Window) !void {
    const success = glfwCreateWindowSurface(instance.handle, window, null, &surface);
    if (success != .success) return error.SurfaceInitFailed;
}

fn destroySurface() void {
    instance.destroySurfaceKHR(surface, null);
}

const PhysicalDeviceCandidate = struct {
    device: vk.PhysicalDevice,
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    features: vk.PhysicalDeviceFeatures,

    graphics_queue_family: u32,
    present_queue_family: u32,

    /// pick the discrete_gpu with the most memory
    fn cmp(ctx: void, a: PhysicalDeviceCandidate, b: PhysicalDeviceCandidate) bool {
        _ = ctx;
        if (cmpDeviceType(a, b)) |result| return result;
        if (cmpMemory(a, b)) |result| return result;

        return true;
    }

    fn cmpDeviceType(a: PhysicalDeviceCandidate, b: PhysicalDeviceCandidate) ?bool {
        const dta: i32 = switch (a.properties.device_type) {
            .discrete_gpu => 2,
            .integrated_gpu, .virtual_gpu => 1,
            else => 0,
        };
        const dtb: i32 = switch (b.properties.device_type) {
            .discrete_gpu => 2,
            .integrated_gpu, .virtual_gpu => 1,
            else => 0,
        };
        if (dtb == dta) return null;
        return dta > dtb;
    }

    fn cmpMemory(a: PhysicalDeviceCandidate, b: PhysicalDeviceCandidate) ?bool {
        var ha: i64 = 0;
        for (a.memory_properties.memory_heaps[0..a.memory_properties.memory_heap_count]) |heap| {
            if (!heap.flags.device_local_bit) continue;
            ha += @intCast(heap.size);
        }
        var hb: i64 = 0;
        for (b.memory_properties.memory_heaps[0..b.memory_properties.memory_heap_count]) |heap| {
            if (!heap.flags.device_local_bit) continue;
            hb += @intCast(heap.size);
        }
        if (ha == hb) return null;
        return hb > ha;
    }
};

fn pickPhysicalDevice() !PhysicalDeviceCandidate {
    const devices = try instance.enumeratePhysicalDevicesAlloc(frame_alloc);
    var candidates = std.ArrayList(PhysicalDeviceCandidate).init(frame_alloc);
    for (devices) |dev| {
        const properties = instance.getPhysicalDeviceProperties(dev);
        const memory_properties = instance.getPhysicalDeviceMemoryProperties(dev);
        const features = instance.getPhysicalDeviceFeatures(dev);

        if (!try checkDeviceExtensionSupport(dev)) {
            log.info(
                "Did not pick {s}: Unsupported device extensions",
                .{std.mem.sliceTo(&properties.device_name, 0)},
            );
            continue;
        }

        // TODO check required features

        var graphics_queue_family: ?u32 = null;
        var present_queue_family: ?u32 = null;
        const queue_families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(
            dev,
            frame_alloc,
        );
        for (queue_families, 0..) |family, i| {
            if (graphics_queue_family == null and
                family.queue_flags.graphics_bit) graphics_queue_family = @intCast(i);
            if (present_queue_family == null and
                try instance.getPhysicalDeviceSurfaceSupportKHR(
                dev,
                @intCast(i),
                surface,
            ) == vk.TRUE) present_queue_family = @intCast(i);
        }

        if (graphics_queue_family == null) {
            log.info(
                "Did not pick {s}: No graphics queue",
                .{std.mem.sliceTo(&properties.device_name, 0)},
            );
            continue;
        }
        if (present_queue_family == null) {
            log.info(
                "Did not pick {s}: No present queue",
                .{std.mem.sliceTo(&properties.device_name, 0)},
            );
            continue;
        }

        try candidates.append(.{
            .device = dev,
            .properties = properties,
            .memory_properties = memory_properties,
            .features = features,
            .graphics_queue_family = graphics_queue_family.?,
            .present_queue_family = present_queue_family.?,
        });
    }

    if (candidates.items.len == 0) {
        log.err("No compatible physical device", .{});
        return error.NoCompatiblePhysicalDevice;
    }
    std.sort.insertion(PhysicalDeviceCandidate, candidates.items, {}, PhysicalDeviceCandidate.cmp);
    log.info(
        "Selected physical device: {s}",
        .{std.mem.sliceTo(&candidates.items[0].properties.device_name, 0)},
    );
    return candidates.items[0];
}

fn checkDeviceExtensionSupport(dev: vk.PhysicalDevice) !bool {
    const available_exts = try instance.enumerateDeviceExtensionPropertiesAlloc(
        dev,
        null,
        frame_alloc,
    );

    for (device_extensions) |req| {
        const req_name = std.mem.sliceTo(req, 0);
        var supported = false;

        for (available_exts) |ava| {
            const ava_name = std.mem.sliceTo(&ava.extension_name, 0);
            if (!std.mem.eql(u8, req_name, ava_name)) continue;
            supported = true;
            break;
        }

        if (!supported) {
            log.err("Unsupported instance extension: {s}", .{req_name});
            return false;
        }
    }
    return true;
}

const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }

    fn proxy(q: Queue) vk.QueueProxy(apis) {
        return vk.QueueProxy(apis).init(q.handle, device.wrapper);
    }
};

fn initDevice(candidate: PhysicalDeviceCandidate) !void {
    var queue_create_infos = std.AutoArrayHashMap(
        u32,
        vk.DeviceQueueCreateInfo,
    ).init(frame_alloc);
    const priority: f32 = 1.0;
    try queue_create_infos.put(candidate.graphics_queue_family, .{
        .queue_family_index = candidate.graphics_queue_family,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    });

    const dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeaturesKHR{
        .dynamic_rendering = vk.TRUE,
    };
    const create_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @intCast(queue_create_infos.count()),
        .p_queue_create_infos = queue_create_infos.values().ptr,
        .p_enabled_features = &device_features,
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = @ptrCast(&device_extensions),
        .p_next = &dynamic_rendering_features,
    };

    const device_handle = try instance.createDevice(candidate.device, &create_info, null);
    const vkd = try alloc.create(DeviceDispatch);
    errdefer alloc.destroy(vkd);
    vkd.* = try DeviceDispatch.load(device_handle, instance.wrapper.dispatch.vkGetDeviceProcAddr);
    device = Device.init(device_handle, vkd);

    physical_device = candidate.device;
    physical_device_properties = candidate.properties;
    physical_device_memory_properties = candidate.memory_properties;
    physical_device_features = candidate.features;
    graphics_queue = Queue.init(candidate.graphics_queue_family);
    present_queue = Queue.init(candidate.present_queue_family);
}

fn deinitDevice() void {
    device.destroyDevice(null);
    alloc.destroy(device.wrapper);
}

fn createSwapchain(window: *glfw.Window) !void {
    const capabilities = try instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        physical_device,
        surface,
    );
    const formats = try instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        physical_device,
        surface,
        frame_alloc,
    );
    const present_modes = try instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        physical_device,
        surface,
        frame_alloc,
    );

    const format = pickSwapchainFormat(formats);
    log.debug("Selected swapchain format: {} {}", .{ format.format, format.color_space });
    const present_mode = pickSwapchainPresentMode(present_modes);
    log.debug("Selected swapchain present_mode: {}", .{present_mode});

    var extent = blk: {
        const framebuffer_size = window.getFramebufferSize();
        break :blk vk.Extent2D{
            .width = @intCast(framebuffer_size[0]),
            .height = @intCast(framebuffer_size[1]),
        };
    };
    extent.width = std.math.clamp(
        extent.width,
        capabilities.min_image_extent.width,
        capabilities.max_image_extent.width,
    );
    extent.height = std.math.clamp(
        extent.height,
        capabilities.min_image_extent.height,
        capabilities.max_image_extent.height,
    );
    std.log.debug("Swapchain extent: {}", .{extent});

    var count = capabilities.min_image_count + 1;
    if (capabilities.max_image_count > 0) count = @min(count, capabilities.max_image_count);
    std.log.debug("Swapchain image count: {}", .{count});

    var create_info = vk.SwapchainCreateInfoKHR{
        .surface = surface,
        .min_image_count = count,
        .image_format = format.format,
        .image_color_space = format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{
            .color_attachment_bit = true,
            .transfer_dst_bit = capabilities.supported_usage_flags.transfer_dst_bit,
        },
        .image_sharing_mode = .exclusive, // see below, might get set to concurrent
        .pre_transform = capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    };
    var queue_families = std.AutoArrayHashMap(u32, void).init(frame_alloc);
    try queue_families.put(graphics_queue.family, {});
    try queue_families.put(present_queue.family, {});
    if (queue_families.count() > 1) {
        create_info.image_sharing_mode = .concurrent;
        create_info.queue_family_index_count = @intCast(queue_families.count());
        create_info.p_queue_family_indices = queue_families.keys().ptr;
    }
    swapchain = try device.createSwapchainKHR(&create_info, null);
    errdefer device.destroySwapchainKHR(swapchain, null);
    swapchain_format = format.format;
    swapchain_extent = extent;
    swapchain_images = try device.getSwapchainImagesAllocKHR(swapchain, alloc);
    swapchain_supports_transfer_dst = capabilities.supported_usage_flags.transfer_dst_bit;
    errdefer alloc.free(swapchain_images);

    swapchain_views = try alloc.alloc(vk.ImageView, swapchain_images.len);
    errdefer alloc.free(swapchain_views);
    for (swapchain_images, 0..) |image, i| {
        const view_create_info = vk.ImageViewCreateInfo{
            .image = image,
            .view_type = .@"2d",
            .format = swapchain_format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        // if we fail, cleanup the views we have created so far
        swapchain_views[i] = device.createImageView(&view_create_info, null) catch |e| {
            var j = i;
            while (j > 0) : (j -= 1) device.destroyImageView(swapchain_views[j - 1], null);
            return e;
        };
    }
}

fn destroySwapchain() void {
    for (swapchain_views) |view| device.destroyImageView(view, null);
    alloc.free(swapchain_views);
    alloc.free(swapchain_images);
    device.destroySwapchainKHR(swapchain, null);
}

fn pickSwapchainFormat(formats: []vk.SurfaceFormatKHR) vk.SurfaceFormatKHR {
    std.debug.assert(formats.len > 0);
    var mask: [swapchain_surface_formats.len]bool = undefined;

    outer: for (swapchain_surface_formats, 0..) |req, i| {
        mask[i] = false;
        for (formats) |ava| {
            if (!std.meta.eql(req, ava)) continue;
            mask[i] = true;
            continue :outer;
        }
    }

    for (swapchain_surface_formats, mask) |format, available| {
        if (!available) continue;
        return format;
    }

    log.warn("None of the requested swapchain surface formats were found", .{});
    return formats[0];
}

fn pickSwapchainPresentMode(modes: []vk.PresentModeKHR) vk.PresentModeKHR {
    for (modes) |mode| if (mode == .mailbox_khr) return mode;
    return vk.PresentModeKHR.fifo_khr; // guaranteed support, should be fine not to check
}
