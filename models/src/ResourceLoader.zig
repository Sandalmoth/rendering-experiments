const std = @import("std");
const qoi = @import("qoi");
const vk = @import("vk");
const vx = @import("vulkan_context.zig");

const Vertex = @import("renderer.zig").Vertex;

const ResourceLoader = @This();

alloc: std.mem.Allocator,

pub fn init(_alloc: std.mem.Allocator) !ResourceLoader {
    return .{
        .alloc = _alloc,
    };
}

pub fn deinit(rl: *ResourceLoader) void {
    rl.* = undefined;
}

const BundleHandle = struct {
    bundle: *Bundle,

    pub fn isReady(handle: BundleHandle) bool {
        _ = handle;
    }

    pub fn wait(handle: BundleHandle) *Bundle {
        // TODO wait for upload
        return handle.bundle;
    }
};
const Bundle = struct {
    const Models =
        std.StringHashMap(struct {
        vertex_offset: u32,
        vertex_count: u32,
        index_offset: u32,
        index_count: u32,
    });

    alloc: std.mem.Allocator,
    memory: vk.DeviceMemory,
    vertex_buffer: vk.Buffer,
    index_buffer: vk.Buffer,
    models: Models,

    fn initPtr(
        alloc: std.mem.Allocator,
        memory: vk.DeviceMemory,
        vertex_buffer: vk.Buffer,
        index_buffer: vk.Buffer,
    ) !*Bundle {
        var bundle = try alloc.create(Bundle);
        bundle.alloc = alloc;
        bundle.memory = memory;
        // TODO these should be gpu only, but are currently cpu visible
        bundle.vertex_buffer = vertex_buffer;
        bundle.index_buffer = index_buffer;
        bundle.models = Models.init(alloc);
        return bundle;
    }

    // maybe there should be a function to just bind all the resources or something?
    pub fn deinit(bundle: *Bundle) void {
        vx.device.destroyBuffer(bundle.vertex_buffer, null);
        vx.device.destroyBuffer(bundle.index_buffer, null);
        vx.device.freeMemory(bundle.memory, null);
        bundle.models.deinit();
        bundle.alloc.destroy(bundle);
    }
};

const VertexContext = struct {
    pub fn hash(_: VertexContext, a: Vertex) u32 {
        return std.hash.XxHash32.hash(1337, std.mem.asBytes(&a));
    }
    pub fn eql(_: VertexContext, a: Vertex, b: Vertex, b_index: usize) bool {
        _ = b_index;
        return std.meta.eql(a, b);
    }
};
pub fn load(rl: *ResourceLoader, filenames: []const []const u8) !BundleHandle {
    // load some list of models and textures into gpu memory
    // fuses all models into two shared vertex/index buffers
    // only performs a single vulkan allocation for all the data and bump-allocates into that
    // returns vertex/index buffer offsets and a descriptor set for all the data

    var all_vertices = std.ArrayList(Vertex).init(rl.alloc);
    defer all_vertices.deinit();
    var indices = std.ArrayList(u32).init(rl.alloc);
    defer indices.deinit();

    var textures = std.StringHashMap(qoi.Image).init(rl.alloc);
    defer textures.deinit();
    var models = std.StringHashMap(struct {
        vertex_offset: u32,
        vertex_count: u32,
        index_offset: u32,
        index_count: u32,
    }).init(rl.alloc);
    defer models.deinit();

    // MAJOR_IMPROVEMENT: we shouldn't really load any data here
    // instead we should read some header in the (our) file format
    // to get the necessary info to figure out the texture dims and buffer lengths
    // and then, we should load the files and upload to the gpu on a separate thread
    // instead of letting just the gpu upload be async
    // IMPROVEMENT: maintain an arena that we load into
    // or possibly even load directly into mapped memory (seems like extra trouble though...)?
    // IMPROVEMENT: don't use obj, and write a good loader

    for (filenames) |filename| {
        std.debug.print("{s}\n", .{filename});

        if (std.mem.eql(u8, "qoi", filename[filename.len - 3 ..])) {
            const bytes = try std.fs.cwd().readFileAlloc(rl.alloc, filename, 16 * 1024 * 1024);
            defer rl.alloc.free(bytes);
            const texture = try qoi.decodeBuffer(rl.alloc, bytes);
            try textures.put(filename, texture);
            std.debug.print("qoi: {} {} {}\n", .{ texture.width, texture.height, texture.colorspace });
        } else if (std.mem.eql(u8, "obj", filename[filename.len - 3 ..])) {
            const vertex_offset: u32 = @intCast(all_vertices.items.len);
            const index_offset: u32 = @intCast(indices.items.len);
            // very crappy obj decoder
            std.debug.print("obj\n", .{});
            const bytes = try std.fs.cwd().readFileAlloc(rl.alloc, filename, 16 * 1024 * 1024);
            defer rl.alloc.free(bytes);

            var positions = std.ArrayList(@Vector(3, f32)).init(rl.alloc);
            var normals = std.ArrayList(@Vector(3, f32)).init(rl.alloc);
            var uvs = std.ArrayList(@Vector(2, f32)).init(rl.alloc);
            defer positions.deinit();
            defer normals.deinit();
            defer uvs.deinit();

            // var vertices = std.ArrayHashMap(Vertex, u32, VertexContext, true).init(rl.alloc);
            var vertices = std.ArrayList(Vertex).init(rl.alloc);
            defer vertices.deinit();

            var it = std.mem.splitSequence(u8, bytes, "\n");
            while (it.next()) |line| {
                if (line.len < 2) continue;
                // std.debug.print("{s}\n", .{line});
                if (std.mem.eql(u8, "vn", line[0..2])) {
                    var x: @Vector(3, f32) = undefined;
                    var it2 = std.mem.splitSequence(u8, line[3..], " ");
                    var i: usize = 0;
                    while (it2.next()) |num| {
                        x[i] = std.fmt.parseFloat(f32, num) catch unreachable;
                        i += 1;
                    }
                    std.debug.assert(i == 3);
                    try normals.append(x);
                } else if (std.mem.eql(u8, "vt", line[0..2])) {
                    var x: @Vector(2, f32) = undefined;
                    var it2 = std.mem.splitSequence(u8, line[3..], " ");
                    var i: usize = 0;
                    while (it2.next()) |num| {
                        x[i] = std.fmt.parseFloat(f32, num) catch unreachable;
                        i += 1;
                    }
                    std.debug.assert(i == 2);
                    try uvs.append(x);
                } else if (std.mem.eql(u8, "v", line[0..1])) {
                    var x: @Vector(3, f32) = undefined;
                    var it2 = std.mem.splitSequence(u8, line[2..], " ");
                    var i: usize = 0;
                    while (it2.next()) |num| {
                        x[i] = std.fmt.parseFloat(f32, num) catch unreachable;
                        i += 1;
                    }
                    std.debug.assert(i == 3);
                    try positions.append(x);
                } else if (std.mem.eql(u8, "f", line[0..1])) {
                    // std.debug.print("n_pos {}\n", .{positions.items.len});
                    // std.debug.print("n_nrm {}\n", .{normals.items.len});
                    // std.debug.print("n_uvs {}\n", .{uvs.items.len});
                    var it2 = std.mem.splitSequence(u8, line[2..], " ");
                    while (it2.next()) |face| {
                        var v: Vertex = undefined;
                        var it3 = std.mem.splitSequence(u8, face, "/");
                        var j: usize = 0;
                        while (it3.next()) |num| {
                            const i = try std.fmt.parseInt(u32, num, 10);
                            // std.debug.print("{s} {}\n", .{ num, i });
                            switch (j) {
                                0 => v.position = positions.items[i - 1],
                                2 => v.normal = normals.items[i - 1],
                                1 => v.uv = uvs.items[i - 1],
                                else => unreachable,
                            }
                            j += 1;
                        }
                        // std.debug.print("{}\n", .{v});
                        // if (vertices.get(v)) |element| {
                        //     try indices.append(element);
                        // } else {
                        //     const element: u32 = @intCast(vertices.count());
                        //     vertices.putNoClobber(v, element) catch unreachable;
                        //     try indices.append(element);
                        // }
                        const element: u32 = @intCast(vertices.items.len);
                        try vertices.append(v);
                        try indices.append(element);
                    }
                }
            }

            // std.debug.print("n_vertices {}\n", .{vertices.count()});

            // try all_vertices.appendSlice(vertices.keys());
            try all_vertices.appendSlice(vertices.items);
            try models.put(filename, .{
                .vertex_offset = vertex_offset,
                .vertex_count = @as(u32, @intCast(all_vertices.items.len)) - vertex_offset,
                .index_offset = index_offset,
                .index_count = @as(u32, @intCast(indices.items.len)) - index_offset,
            });
        }
    }

    var it_models = models.iterator();
    while (it_models.next()) |model| {
        std.debug.print("{s}\t{}\n", .{ model.key_ptr.*, model.value_ptr.* });
    }

    std.debug.print("n_vertices total {}\n", .{all_vertices.items.len});
    std.debug.print("n_indices  total {}\n", .{indices.items.len});

    var cursor: usize = 0; // compute the total size required

    const vertex_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(Vertex) * all_vertices.items.len,
        .usage = .{ .transfer_dst_bit = true, .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const vertex_buffer = try vx.device.createBuffer(&vertex_buffer_info, null);
    errdefer vx.device.destroyBuffer(vertex_buffer, null);
    const vertex_buffer_memreq = vx.device.getBufferMemoryRequirements(vertex_buffer);
    std.debug.print("{}\n", .{vertex_buffer_memreq});
    cursor = std.mem.alignForward(usize, cursor, vertex_buffer_memreq.alignment);
    cursor += vertex_buffer_memreq.size;

    const index_buffer_info = vk.BufferCreateInfo{
        .size = @sizeOf(u32) * indices.items.len,
        .usage = .{ .transfer_dst_bit = true, .index_buffer_bit = true },
        .sharing_mode = .exclusive,
    };
    const index_buffer = try vx.device.createBuffer(&index_buffer_info, null);
    errdefer vx.device.destroyBuffer(index_buffer, null);
    const index_buffer_memreq = vx.device.getBufferMemoryRequirements(index_buffer);
    std.debug.print("{}\n", .{index_buffer_memreq});
    cursor = std.mem.alignForward(usize, cursor, index_buffer_memreq.alignment);
    cursor += index_buffer_memreq.size;

    // TODO textures
    // const images = rl.alloc.alloc(vk.Image, textures.count());
    var it_textures = textures.valueIterator();
    // while (it_textures.next()) |texture| {
    //     const image_info = vk.ImageCreateInfo{
    //         .image_type = .@"2d",
    //         .format = .r8g8b8a8_srgb,
    //         .extent = .{ .width = texture.width, .height = texture.height, .depth = 1 },
    //         .mip_levels = 1,
    //         .array_layers = 1,
    //         .samples = .{ .@"32_bit" = true }, // what is this?
    //         .tiling = .linear,
    //         .usage = .{ .transfer_src_bit = true },
    //         .sharing_mode = .exclusive,
    //         .initial_layout = .undefined,
    //     };
    // }

    // cursor now holds total memory required for everything, respecting alignment
    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = cursor,
        .memory_type_index = try vx.findMemoryType(
            vertex_buffer_memreq.memory_type_bits & index_buffer_memreq.memory_type_bits,
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        ),
    };
    std.debug.print("{}\n", .{alloc_info});
    const memory = try vx.device.allocateMemory(&alloc_info, null);
    errdefer vx.device.freeMemory(memory, null);

    // for (all_vertices.items, 0..) |vertex, i| std.debug.print("{}\t{}\n", .{ i, vertex });
    // for (indices.items, 0..) |index, i| std.debug.print("{}\t{}\n", .{ i, index });

    cursor = 0;
    cursor = std.mem.alignForward(usize, cursor, vertex_buffer_memreq.alignment);
    try vx.device.bindBufferMemory(vertex_buffer, memory, cursor);
    const _vd = try vx.device.mapMemory(
        memory,
        cursor,
        @sizeOf(Vertex) * all_vertices.items.len,
        .{},
    );
    @memcpy(@as([*]Vertex, @alignCast(@ptrCast(_vd))), all_vertices.items);
    vx.device.unmapMemory(memory);
    cursor += vertex_buffer_memreq.size;

    cursor = std.mem.alignForward(usize, cursor, index_buffer_memreq.alignment);
    try vx.device.bindBufferMemory(index_buffer, memory, cursor);
    const _id = try vx.device.mapMemory(memory, cursor, @sizeOf(u32) * indices.items.len, .{});
    @memcpy(@as([*]u32, @alignCast(@ptrCast(_id))), indices.items);
    vx.device.unmapMemory(memory);
    cursor += index_buffer_memreq.size;

    var bundle = try Bundle.initPtr(rl.alloc, memory, vertex_buffer, index_buffer);
    // errdefer gets hard here, since if we errdefer bundle deinit, we get double frees
    it_models = models.iterator();
    while (it_models.next()) |model| {
        try bundle.models.put(model.key_ptr.*, .{
            .vertex_offset = model.value_ptr.vertex_offset,
            .vertex_count = model.value_ptr.vertex_count,
            .index_offset = model.value_ptr.index_offset,
            .index_count = model.value_ptr.index_count,
        });
    }

    it_textures = textures.valueIterator();
    while (it_textures.next()) |texture| texture.deinit(rl.alloc);

    return .{
        .bundle = bundle,
    };
}
