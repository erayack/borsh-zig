const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const serde = @import("./serde.zig");

const Person = struct {
    name: []const u8,
    age: u128,
    prob: f64,
    data: []const i32,

    fn eql(self: *const Person, other: *const Person) bool {
        return std.mem.eql(u8, self.name, other.name) and
            self.age == other.age and
            self.prob == other.prob and
            std.mem.eql(i32, self.data, other.data);
    }
};

const Hole = struct {
    age: u32,
    id: [2]i16,
    inner: ?*const Hole,

    fn eql(self: *const Hole, other: *const Hole) bool {
        if (self.age != other.age) {
            return false;
        }

        if (self.inner) |si| {
            if (other.inner) |oi| {
                return si.eql(oi);
            } else {
                return false;
            }
        } else {
            return other.inner == null;
        }
    }
};

const EmptyEnum = enum {
    one,
    two,
    three,

    fn eql(self: *const EmptyEnum, other: *const EmptyEnum) bool {
        return self.* == other.*;
    }
};

const Exists = union(enum) {
    no,
    yes: struct { a: void, b: bool },

    fn eql(self: *const Exists, other: *const Exists) bool {
        switch (self.*) {
            .no => return other.* == .no,
            .yes => |si| {
                switch (other.*) {
                    .no => return false,
                    .yes => |oi| {
                        return si.b == oi.b;
                    },
                }
            },
        }
    }
};

fn test_case(input: anytype) !void {
    const T = @TypeOf(input);

    const num_bytes = serde.calculate_serialized_size(T, &input);

    const input_bytes = try testing.allocator.alloc(u8, @intCast(num_bytes));
    defer testing.allocator.free(input_bytes);

    try serde.serialize(T, &input, input_bytes);

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const output = try serde.deserialize(T, input_bytes, alloc);

    try testing.expect(input.eql(&output));
}

test "serde" {
    try test_case(Person{
        .name = "ccccc",
        .age = 541212312321534534,
        .prob = 0.69,
        .data = &.{ 31, 69 },
    });
    try test_case(Person{
        .name = "",
        .age = 699,
        .prob = 0.01,
        .data = &.{},
    });
    try test_case(Hole{
        .age = 69,
        .id = .{ 3, 9 },
        .inner = null,
    });
    try test_case(Hole{
        .age = 1131,
        .id = .{ 3, 10 },
        .inner = &Hole{
            .age = 1333,
            .id = .{ 6, 9 },
            .inner = null,
        },
    });
    try test_case(EmptyEnum.two);
    try test_case(Exists{ .no = void{} });
    try test_case(Exists{ .yes = .{ .a = void{}, .b = true } });
}
