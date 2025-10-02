const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArenaAllocator = std.heap.ArenaAllocator;
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

fn fuzz_de(input: []const u8, gpa: Allocator) anyerror!void {
    inline for (DATA_TYPES) |dt| {
        var arena = ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        _ = serde.deserialize(dt, input, alloc, max_recursion_depth) catch {};
        _ = serde.deserialize([]dt, input, alloc, max_recursion_depth) catch {};
        _ = serde.deserialize(*dt, input, alloc, max_recursion_depth) catch {};
    }
}

test "fuzz deserialize" {
    try FuzzWrap(fuzz_de, 1 << 15).run();
}

fn FuzzWrap(comptime fuzz_one: fn (data: []const u8, gpa: Allocator) anyerror!void, comptime alloc_size: comptime_int) type {
    const FuzzContext = struct {
        fb_alloc: *FixedBufferAllocator,
    };

    return struct {
        fn run_one(ctx: FuzzContext, data: []const u8) anyerror!void {
            ctx.fb_alloc.reset();

            var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{
                .backing_allocator_zeroes = false,
            }){
                .backing_allocator = ctx.fb_alloc.allocator(),
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

            fuzz_one(data, gpa) catch |e| {
                if (e == error.ShortInput) return {} else return e;
            };
        }

        fn run() !void {
            var fb_alloc = FixedBufferAllocator.init(std.heap.page_allocator.alloc(u8, alloc_size) catch unreachable);
            try std.testing.fuzz(FuzzContext{
                .fb_alloc = &fb_alloc,
            }, run_one, .{});
        }
    };
}
