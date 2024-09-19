pub const c = @cImport({
    @cInclude("vk_mem_alloc.h");
});

const std = @import("std");

const vk = @import("vk.zig");
