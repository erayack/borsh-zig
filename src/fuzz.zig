const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

const serde = @import("./serde.zig");
const tests = @import("./tests.zig");

const DATA_TYPES = [_]type{
    tests.EmptyEnum,
    tests.Exists,
    tests.Person,
    tests.Hole,
};

const max_recursion_depth = 20;

fn to_fuzz(_: void, input: []const u8) anyerror!void {
    var general_purpose_allocator: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = general_purpose_allocator.allocator();
    defer {
        switch (general_purpose_allocator.deinit()) {
            .ok => {},
            .leak => |l| {
                std.debug.panic("LEAK: {any}", .{l});
            },
        }
    }

    const deserialize_buf = try gpa.alloc(u8, 1 << 14);
    defer gpa.free(deserialize_buf);

    var fb_alloc = FixedBufferAllocator.init(deserialize_buf);
    const alloc = fb_alloc.allocator();

    inline for (DATA_TYPES) |dt| {
        _ = serde.deserialize(dt, input, alloc, max_recursion_depth) catch {};
        fb_alloc.reset();

        _ = serde.deserialize([]dt, input, alloc, max_recursion_depth) catch {};
        fb_alloc.reset();

        _ = serde.deserialize(*dt, input, alloc, max_recursion_depth) catch {};
        fb_alloc.reset();
    }
}

test "fuzz" {
    try std.testing.fuzz({}, to_fuzz, .{});
}
