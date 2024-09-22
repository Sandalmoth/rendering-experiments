pub const c = @cImport({
    @cInclude("vk_mem_alloc.h");
});

const std = @import("std");

const vk = @import("vk.zig");

pub const Allocator = struct {
    backing_allocator: c.VmaAllocator,

    pub fn init(
        instance: vk.Instance,
        physical_device: vk.PhysicalDevice,
        device: vk.Device,
        get_instance_proc_addr: ?*const anyopaque,
        get_device_proc_addr: ?*const anyopaque,
    ) !Allocator {
        // reinterpret memory to transition from vulkan-zig to c binding
        // this is silly
        const pd: *const c.VkPhysicalDevice = @ptrCast(&physical_device);
        const d: *const c.VkDevice = @ptrCast(&device);
        const i: *const c.VkInstance = @ptrCast(&instance);
        const create_info = c.VmaAllocatorCreateInfo{
            .physicalDevice = pd.*,
            .device = d.*,
            .instance = i.*,
            .flags = c.VMA_ALLOCATOR_CREATE_BUFFER_DEVICE_ADDRESS_BIT,
            .pVulkanFunctions = &.{
                .vkGetInstanceProcAddr = @ptrCast(get_instance_proc_addr),
                .vkGetDeviceProcAddr = @ptrCast(get_device_proc_addr),
            },
        };
        var alloc: Allocator = undefined;
        const result = c.vmaCreateAllocator(&create_info, &alloc.backing_allocator);
        if (result != c.VK_SUCCESS) return error.vmaCreateAllocator;
        return alloc;
    }

    pub fn deinit(alloc: *Allocator) void {
        c.vmaDestroyAllocator(alloc.backing_allocator);
        alloc.* = undefined;
    }

    pub fn createImage(
        alloc: *Allocator,
        extent: vk.Extent3D,
        image_create_info: *const vk.ImageCreateInfo,
    ) !AllocatedImage {
        const create_info = c.VmaAllocationCreateInfo{
            .usage = c.VMA_MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };
        var result: AllocatedImage = undefined;
        result.extent = extent;
        const success = c.vmaCreateImage(
            alloc.backing_allocator,
            @ptrCast(image_create_info),
            &create_info,
            @ptrCast(&result.image),
            &result.allocation,
            null,
        );
        if (success != c.VK_SUCCESS) return error.AllocationFailed;
        return result;
    }

    pub fn destroyImage(alloc: *Allocator, allocated_image: AllocatedImage) void {
        const image: *const c.VkImage = @ptrCast(&allocated_image.image);
        c.vmaDestroyImage(
            alloc.backing_allocator,
            image.*,
            allocated_image.allocation,
        );
    }
};

const AllocatedImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    allocation: c.VmaAllocation,
    extent: vk.Extent3D,
    format: vk.Format,
};
