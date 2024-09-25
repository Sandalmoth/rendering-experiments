const std = @import("std");
const vx = @import("vulkan_context.zig");
const qoi = @import("qoi");

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

    fn isReady(handle: BundleHandle) bool {
        _ = handle;
    }

    fn wait(handle: BundleHandle) Bundle {
        _ = handle;
    }
};
const Bundle = struct {
    // maybe there should be a function to just bind all the resources or something?
    fn destroy(bundle: *Bundle) void {
        bundle.* = undefined;
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
    var models = std.StringHashMap(struct { offset: u32, len: u32 }).init(rl.alloc);
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

            var vertices = std.ArrayHashMap(Vertex, u32, VertexContext, true).init(rl.alloc);
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
                        if (vertices.get(v)) |element| {
                            try indices.append(
                                element + @as(u32, @intCast(all_vertices.items.len)),
                            );
                        } else {
                            const element: u32 = @intCast(vertices.count());
                            vertices.putNoClobber(v, element) catch unreachable;
                            try indices.append(
                                element + @as(u32, @intCast(all_vertices.items.len)),
                            );
                        }
                    }
                }
            }

            std.debug.print("n_vertices {}\n", .{vertices.count()});

            try all_vertices.appendSlice(vertices.keys());
        }
    }

    std.debug.print("n_vertices total {}\n", .{all_vertices.items.len});
    std.debug.print("n_indices  total {}\n", .{indices.items.len});

    var it_textures = textures.valueIterator();
    while (it_textures.next()) |texture| texture.deinit(rl.alloc);

    return undefined;
}
