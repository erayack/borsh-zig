const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const serde = @import("./serde.zig");
const tests = @import("./tests.zig");

const DATA_TYPES = [_]type{
    tests.EmptyEnum,
    tests.Exists,
    tests.Person,
    tests.Hole,
};

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

    inline for (DATA_TYPES) |dt| {
        var arena = ArenaAllocator.init(gpa);
        defer arena.deinit();
        const alloc = arena.allocator();

        _ = serde.deserialize(dt, input, alloc) catch {};
        _ = serde.deserialize([]dt, input, alloc) catch {};
        _ = serde.deserialize(*dt, input, alloc) catch {};
    }
}

test "fuzz" {
    try std.testing.fuzz({}, to_fuzz, .{});
}
