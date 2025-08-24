const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Allocator = std.mem.Allocator;

const serde = @import("./serde.zig");
const tests = @import("./tests.zig");

const DATA_TYPES = [_]type{
    tests.EmptyEnum,
    tests.Exists,
    tests.Person,
    tests.Hole,
};

const max_recursion_depth = 20;

fn to_fuzz(input: []const u8, base_alloc: Allocator) anyerror!void {
    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
        .backing_allocator_zeroes = false,
    }){
        .backing_allocator = base_alloc,
    };
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

const FuzzContext = struct {
    fb_alloc: *FixedBufferAllocator,
};

fn to_fuzz_wrap(ctx: FuzzContext, data: []const u8) anyerror!void {
    ctx.fb_alloc.reset();
    return to_fuzz(data, ctx.fb_alloc.allocator()) catch |e| {
        if (e == error.ShortInput) return {} else return e;
    };
}

test "fuzz" {
    var fb_alloc = FixedBufferAllocator.init(std.heap.page_allocator.alloc(u8, 1 << 20) catch unreachable);
    try std.testing.fuzz(FuzzContext{
        .fb_alloc = &fb_alloc,
    }, to_fuzz_wrap, .{});
}
