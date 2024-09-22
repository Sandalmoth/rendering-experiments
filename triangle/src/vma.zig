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
        c.vmaDestroyAllocator(alloc);
    }
};
