const std = @import("std");
const vk = @import("vk");
const pf = @import("platform.zig");

const log = std.log.scoped(.vulkan_context);

// ### config section ###
const apis: []const vk.ApiInfo = &.{
    .{
        .base_commands = .{
            .createInstance = true,
            .enumerateInstanceExtensionProperties = true,
            .enumerateInstanceLayerProperties = true,
            .getInstanceProcAddr = true,
        },
        .instance_commands = .{
            .createDevice = true,
            .destroyInstance = true,
            .destroySurfaceKHR = true,
            .enumerateDeviceExtensionProperties = true,
            .enumeratePhysicalDevices = true,
            .getDeviceProcAddr = true,
            .getPhysicalDeviceFeatures2 = true,
            .getPhysicalDeviceMemoryProperties = true,
            .getPhysicalDeviceProperties = true,
            .getPhysicalDeviceQueueFamilyProperties = true,
            .getPhysicalDeviceSurfaceSupportKHR = true,
            // .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
            // .getPhysicalDeviceSurfaceFormatsKHR = true,
            // .getPhysicalDeviceSurfacePresentModesKHR = true,
        },
        .device_commands = .{
            .destroyDevice = true,
            .getDeviceQueue = true,
            // .createImageView = true,
            // .destroyImageView = true,
            // .createSwapchainKHR = true,
            // .destroySwapchainKHR = true,
            // .getSwapchainImagesKHR = true,
            // .createFence = true,
            // .destroyFence = true,
            // .createSemaphore = true,
            // .destroySemaphore = true,
            // .waitForFences = true,
            // .resetFences = true,
            // .acquireNextImageKHR = true,
            // .deviceWaitIdle = true,
            // .createCommandPool = true,
            // .destroyCommandPool = true,
            // .allocateCommandBuffers = true,
            // .beginCommandBuffer = true,
            // .resetCommandPool = true,
            // .endCommandBuffer = true,
            // .cmdClearColorImage = true,
            // .cmdPipelineBarrier2 = true,
            // .queuePresentKHR = true,
            // .queueSubmit2 = true,
            // .cmdBlitImage2 = true,
            // .createShaderModule = true,
            // .destroyShaderModule = true,
            // .createGraphicsPipelines = true,
            // .createPipelineLayout = true,
            // .destroyPipeline = true,
            // .destroyPipelineLayout = true,
            // .cmdBeginRendering = true,
            // .cmdBindPipeline = true,
            // .cmdSetViewport = true,
            // .cmdSetScissor = true,
            // .cmdDraw = true,
            // .cmdEndRendering = true,
        },
    },
};

const api_version = vk.API_VERSION_1_3;

pub const frames_in_flight = 2;

const enable_debug = @import("builtin").mode == .Debug;

const layers = [_][*:0]const u8{};
const debug_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};

const instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
};
const debug_instance_extensions = [_][*:0]const u8{};

const device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
};
const debug_device_extensions = [_][*:0]const u8{};

// (i don't think there are any debug-specific features?)
const device_features = vk.PhysicalDeviceFeatures{};
const device_features_1_1 = vk.PhysicalDeviceVulkan11Features{
    .p_next = @constCast(@ptrCast(&device_features_1_2)),
};
const device_features_1_2 = vk.PhysicalDeviceVulkan12Features{
    .p_next = @constCast(@ptrCast(&device_features_1_3)),
    .descriptor_indexing = vk.TRUE,
    .buffer_device_address = vk.TRUE,
};
const device_features_1_3 = vk.PhysicalDeviceVulkan13Features{
    .dynamic_rendering = vk.TRUE,
    .synchronization_2 = vk.TRUE,
};

const swapchain_surface_formats = [_]vk.SurfaceFormatKHR{
    // ranking of preferred formats for the swapchain surfaces
    // if none are present, the first format from getPhysicalDeviceSurfaceFormats is used
    .{ .format = vk.Format.b8g8r8a8_srgb, .color_space = vk.ColorSpaceKHR.srgb_nonlinear_khr },
    .{ .format = vk.Format.r8g8b8a8_srgb, .color_space = vk.ColorSpaceKHR.srgb_nonlinear_khr },
};
// ### end config section ###

const BaseDispatch = vk.BaseWrapper(apis);
const InstanceDispatch = vk.InstanceWrapper(apis);
const DeviceDispatch = vk.DeviceWrapper(apis);

const Instance = vk.InstanceProxy(apis);
const Device = vk.DeviceProxy(apis);

// ### global state section ###
pub var alloc: std.mem.Allocator = undefined;

var vkb: BaseDispatch = undefined;
var instance: Instance = undefined;
pub var device: Device = undefined;

var surface: vk.SurfaceKHR = .null_handle;

var physical_device: vk.PhysicalDevice = .null_handle;
var physical_device_properties: vk.PhysicalDeviceProperties = undefined;
var physical_device_memory_properties: vk.PhysicalDeviceMemoryProperties = undefined;
var physical_device_features: vk.PhysicalDeviceFeatures = undefined;

// NOTE some or all of these may alias the same queue
pub var graphics_compute_queue: Queue = undefined;
pub var async_compute_queue: Queue = undefined;
pub var transfer_queue: Queue = undefined;
pub var present_queue: Queue = undefined;

var swapchain: vk.SwapchainKHR = .null_handle;
var swapchain_format: vk.SurfaceFormatKHR = undefined;
var swapchain_extent: vk.Extent2D = undefined;
var swapchain_images: []vk.Image = undefined;
var swapchain_views: []vk.ImageView = undefined;
var swapchain_supports_transfer_dst: bool = undefined;
// ### end global state section ###

pub fn init(_alloc: std.mem.Allocator, app_name: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    alloc = _alloc;
    vkb = try BaseDispatch.load(pf.getInstanceProcAddress);

    try initInstance(arena_alloc, app_name);
    errdefer deinitInstance();
    try createSurface();
    errdefer destroySurface();
    const physical_device_candidate = try pickPhysicalDevice(arena_alloc);
    try initDevice(arena_alloc, physical_device_candidate);
    errdefer deinitDevice();
    // try createSynchronization();
    // errdefer destroySynchronization();
    // try createSwapchain();
    // errdefer destroySwapchain(true);
    // try createAllocator();
    // errdefer destroyAllocator();
}

pub fn deinit() void {
    // destroyAllocator();
    // destroySwapchain(true);
    // destroySynchronization();
    deinitDevice();
    destroySurface();
    deinitInstance();
}

fn initInstance(arena_alloc: std.mem.Allocator, app_name: [*:0]const u8) !void {
    const all_layers = if (enable_debug) layers ++ debug_layers else layers;
    if (!try checkLayerSupport(arena_alloc, &all_layers)) {
        return error.UnsupportedLayer;
    }

    // i can't find any info on whether duplication is allowed, so deduplicate just in case
    const glfw_extensions = try pf.getRequiredInstanceExtensions();
    var all_extensions = std.ArrayList([*:0]const u8).init(arena_alloc);
    try all_extensions.appendSlice(glfw_extensions);
    outer: for (if (enable_debug)
        instance_extensions ++ debug_instance_extensions
    else
        instance_extensions) |ext1|
    {
        for (all_extensions.items) |ext2| if (std.mem.eql(
            u8,
            std.mem.sliceTo(ext1, 0),
            std.mem.sliceTo(ext2, 0),
        )) continue :outer;
        try all_extensions.append(ext1);
    }
    if (!try checkInstanceExtensionSupport(arena_alloc, all_extensions.items)) {
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

fn checkInstanceExtensionSupport(
    arena_alloc: std.mem.Allocator,
    required_exts: []const [*:0]const u8,
) !bool {
    const available_exts = try vkb.enumerateInstanceExtensionPropertiesAlloc(null, arena_alloc);

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

fn checkLayerSupport(
    arena_alloc: std.mem.Allocator,
    required_layers: []const [*:0]const u8,
) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(arena_alloc);

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

fn createSurface() !void {
    surface = try pf.createWindowSurface(instance.handle);
}

fn destroySurface() void {
    instance.destroySurfaceKHR(surface, null);
    surface = .null_handle;
}

const PhysicalDeviceCandidate = struct {
    device: vk.PhysicalDevice,
    // TODO expand properties/memory_properties in the same way as the features?
    properties: vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    features: vk.PhysicalDeviceFeatures,
    features_1_1: vk.PhysicalDeviceVulkan11Features,
    features_1_2: vk.PhysicalDeviceVulkan12Features,
    features_1_3: vk.PhysicalDeviceVulkan13Features,

    graphics_compute_queue_family: ?u32,
    async_compute_queue_family: ?u32,
    transfer_queue_family: ?u32,
    present_queue_family: ?u32,

    fn init(arena_alloc: std.mem.Allocator, dev: vk.PhysicalDevice) !PhysicalDeviceCandidate {
        var candidate = PhysicalDeviceCandidate{
            .device = dev,
            .properties = instance.getPhysicalDeviceProperties(dev),
            .memory_properties = instance.getPhysicalDeviceMemoryProperties(dev),
            .features = undefined,
            .features_1_1 = .{},
            .features_1_2 = .{},
            .features_1_3 = .{},
            .graphics_compute_queue_family = null,
            .async_compute_queue_family = null,
            .transfer_queue_family = null,
            .present_queue_family = null,
        };
        candidate.features_1_2.p_next = &candidate.features_1_3;
        candidate.features_1_1.p_next = &candidate.features_1_2;
        var features2 = vk.PhysicalDeviceFeatures2{
            .p_next = &candidate.features_1_1,
            .features = .{},
        };
        instance.getPhysicalDeviceFeatures2(candidate.device, &features2);
        candidate.features = features2.features;
        candidate.features_1_1.p_next = null;
        candidate.features_1_2.p_next = null;
        candidate.features_1_3.p_next = null;

        // graphics queue must support graphics and compute
        // async compute should preferably be compute-only queue, otherwise same as graphics
        // transfer should preferably be transfer-only queue,
        //   otherwise same as async compute, otherwise same as graphics
        // present queue should preferably be same as graphics
        const queue_families =
            try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(dev, arena_alloc);
        for (queue_families, 0..) |family, i| {
            if (family.queue_flags.graphics_bit) continue;
            if (family.queue_flags.compute_bit) continue;
            if (!family.queue_flags.transfer_bit) continue;
            candidate.transfer_queue_family = @intCast(i);
            break;
        }
        for (queue_families, 0..) |family, i| {
            if (family.queue_flags.graphics_bit) continue;
            if (!family.queue_flags.compute_bit) continue;
            candidate.async_compute_queue_family = @intCast(i);
            break;
        }
        for (queue_families, 0..) |family, i| {
            if (!family.queue_flags.graphics_bit) continue;
            if (!family.queue_flags.compute_bit) continue;
            if (try instance.getPhysicalDeviceSurfaceSupportKHR(
                candidate.device,
                @intCast(i),
                surface,
            ) != vk.TRUE) continue;
            candidate.graphics_compute_queue_family = @intCast(i);
            candidate.present_queue_family = @intCast(i);
        }
        if (candidate.graphics_compute_queue_family == null) {
            for (queue_families, 0..) |family, i| {
                if (!family.queue_flags.graphics_bit) continue;
                if (!family.queue_flags.compute_bit) continue;
                candidate.graphics_compute_queue_family = @intCast(i);
            }
        }
        if (candidate.present_queue_family == null) {
            for (queue_families, 0..) |_, i| {
                if (try instance.getPhysicalDeviceSurfaceSupportKHR(
                    candidate.device,
                    @intCast(i),
                    surface,
                ) != vk.TRUE) continue;
                candidate.present_queue_family = @intCast(i);
            }
        }
        if (candidate.async_compute_queue_family == null) {
            candidate.async_compute_queue_family = candidate.graphics_compute_queue_family;
        }
        if (candidate.transfer_queue_family == null) {
            candidate.transfer_queue_family = candidate.async_compute_queue_family;
        }

        return candidate;
    }

    fn checkExtensionSupport(
        candidate: *const PhysicalDeviceCandidate,
        arena_alloc: std.mem.Allocator,
    ) !bool {
        const available_exts = try instance.enumerateDeviceExtensionPropertiesAlloc(
            candidate.device,
            null,
            arena_alloc,
        );

        for (if (enable_debug)
            device_extensions ++ debug_device_extensions
        else
            device_extensions) |req|
        {
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

    fn checkFeatureSupport(candidate: *const PhysicalDeviceCandidate) !bool {
        inline for (std.meta.fields(vk.PhysicalDeviceFeatures)) |field| {
            if (field.type != vk.Bool32) continue;
            if (@field(device_features, field.name) == vk.FALSE) continue;
            if (@field(candidate.features, field.name) == vk.FALSE) return false;
        }
        inline for (std.meta.fields(vk.PhysicalDeviceVulkan11Features)) |field| {
            if (field.type != vk.Bool32) continue;
            if (@field(device_features_1_1, field.name) == vk.FALSE) continue;
            if (@field(candidate.features_1_1, field.name) == vk.FALSE) return false;
        }
        inline for (std.meta.fields(vk.PhysicalDeviceVulkan12Features)) |field| {
            if (field.type != vk.Bool32) continue;
            if (@field(device_features_1_2, field.name) == vk.FALSE) continue;
            if (@field(candidate.features_1_2, field.name) == vk.FALSE) return false;
        }
        inline for (std.meta.fields(vk.PhysicalDeviceVulkan13Features)) |field| {
            if (field.type != vk.Bool32) continue;
            if (@field(device_features_1_3, field.name) == vk.FALSE) continue;
            if (@field(candidate.features_1_3, field.name) == vk.FALSE) return false;
        }
        return true;
    }

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

fn pickPhysicalDevice(arena_alloc: std.mem.Allocator) !PhysicalDeviceCandidate {
    const devices = try instance.enumeratePhysicalDevicesAlloc(arena_alloc);
    var candidates = std.ArrayList(PhysicalDeviceCandidate).init(arena_alloc);
    for (devices) |dev| {
        const candidate = try PhysicalDeviceCandidate.init(arena_alloc, dev);
        const name = std.mem.sliceTo(&candidate.properties.device_name, 0);

        if (!try candidate.checkExtensionSupport(arena_alloc)) {
            log.info("Did not pick {s}: Unsupported device extensions", .{name});
            continue;
        }

        if (!try candidate.checkFeatureSupport()) {
            log.info("Did not pick {s}: Unsupported device extensions", .{name});
            continue;
        }

        if (candidate.graphics_compute_queue_family == null) {
            log.info("Did not pick {s}: No graphics queue", .{name});
            continue;
        }
        if (candidate.present_queue_family == null) {
            log.info("Did not pick {s}: No present queue", .{name});
            continue;
        }

        std.debug.assert(candidate.async_compute_queue_family != null);
        std.debug.assert(candidate.transfer_queue_family != null);

        try candidates.append(candidate);
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
    log.debug("- Graphics queue family: {}", .{candidates.items[0].graphics_compute_queue_family.?});
    log.debug(
        "- Async compute queue family: {}",
        .{candidates.items[0].async_compute_queue_family.?},
    );
    log.debug("- Transfer queue family: {}", .{candidates.items[0].transfer_queue_family.?});
    log.debug("- Present queue family: {}", .{candidates.items[0].present_queue_family.?});
    return candidates.items[0];
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

    pub fn proxy(q: Queue) vk.QueueProxy(apis) {
        return vk.QueueProxy(apis).init(q.handle, device.wrapper);
    }
};

fn initDevice(arena_alloc: std.mem.Allocator, candidate: PhysicalDeviceCandidate) !void {
    var queue_create_infos = std.AutoArrayHashMap(u32, vk.DeviceQueueCreateInfo).init(arena_alloc);
    const priority: f32 = 1.0;
    try queue_create_infos.put(candidate.graphics_compute_queue_family.?, .{
        .queue_family_index = candidate.graphics_compute_queue_family.?,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    });
    try queue_create_infos.put(candidate.async_compute_queue_family.?, .{
        .queue_family_index = candidate.async_compute_queue_family.?,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    });
    try queue_create_infos.put(candidate.transfer_queue_family.?, .{
        .queue_family_index = candidate.transfer_queue_family.?,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    });
    try queue_create_infos.put(candidate.present_queue_family.?, .{
        .queue_family_index = candidate.present_queue_family.?,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priority),
    });

    const create_info = vk.DeviceCreateInfo{
        .queue_create_info_count = @intCast(queue_create_infos.count()),
        .p_queue_create_infos = queue_create_infos.values().ptr,
        .p_enabled_features = &device_features,
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = @ptrCast(&device_extensions),
        .p_next = &device_features_1_1,
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
    graphics_compute_queue = Queue.init(candidate.graphics_compute_queue_family.?);
    async_compute_queue = Queue.init(candidate.async_compute_queue_family.?);
    transfer_queue = Queue.init(candidate.transfer_queue_family.?);
    present_queue = Queue.init(candidate.present_queue_family.?);
}

fn deinitDevice() void {
    device.destroyDevice(null);
    alloc.destroy(device.wrapper);
    physical_device = .null_handle;
}
