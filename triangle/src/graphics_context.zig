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
        },
        .device_commands = .{},
    },
    // vk.features.version_1_0,
};

const api_version = vk.API_VERSION_1_3;

const instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
};

const device_extensions = [_][*:0]const u8{
    "VK_KHR_surface", // this should fail i think
    "VK_KHR_swapchain",
};

const layers = [_][*:0]const u8{};
const validation_layers = [_][*:0]const u8{
    "VK_LAYER_KHRONOS_validation",
};
const enable_validation = @import("builtin").mode == .Debug;
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

var alloc: std.mem.Allocator = undefined;
var frame_arena: std.heap.ArenaAllocator = undefined;
var frame_alloc: std.mem.Allocator = undefined;

var vkb: BaseDispatch = undefined;
var instance: Instance = undefined;
var device: Device = undefined;

pub fn init(_alloc: std.mem.Allocator, app_name: [*:0]const u8) !void {
    alloc = _alloc;
    frame_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer frame_arena.deinit();
    frame_alloc = frame_arena.allocator();
    vkb = try BaseDispatch.load(glfwGetInstanceProcAddress);

    try initInstance(app_name);
    errdefer deinitInstance();

    _ = frame_arena.reset(.retain_capacity);
}

pub fn deinit() void {
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
    for (all_extensions.items) |ext| std.debug.print("{s}\n", .{std.mem.sliceTo(ext, 0)});
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
    defer frame_alloc.free(available_exts);

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
    defer frame_alloc.free(available_layers);

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
