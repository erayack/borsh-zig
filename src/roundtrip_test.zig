const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const serde = @import("./serde.zig");

// Each `id` corresponds to a specific test case, this function is supposed to import the given object, create a new object based on the `id` it receives, assert these two objects are equal,
// and export the object it created back to the caller.
extern fn roundtrip_test_case(id: u8, input: [*]const u8, input_len: usize, output: *[*]u8, output_len: *usize) void;

const Person = struct {
    name: []const u8,
    age: u128,
    prob: f64,
    data: []const i32,

    fn deinit(self: Person, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }

    fn eql(self: *const Person, other: *const Person) bool {
        return std.mem.eql(u8, self.name, other.name) and
            self.age == other.age and
            self.prob == other.prob and
            std.mem.eql(i32, self.data, other.data);
    }
};

fn test_case(id: u8, input: anytype) !void {
    const num_bytes = serde.calculate_serialized_size(@TypeOf(input), &input);

    const input_bytes = try testing.allocator.alloc(u8, @intCast(num_bytes));
    defer testing.allocator.free(input_bytes);

    try serde.serialize(@TypeOf(input), &input, input_bytes);

    var output_len: usize = 0;
    var output_ptr: [*]u8 = undefined;
    roundtrip_test_case(id, input_bytes.ptr, input_bytes.len, &output_ptr, &output_len);
    const output_bytes = output_ptr[0..output_len];
    defer std.c.free(output_bytes.ptr);

    const output = try serde.deserialize(@TypeOf(input), output_bytes, testing.allocator);
    defer output.deinit(testing.allocator);

    try testing.expect(input.eql(&output));
}

fn run_test(id: u8) !void {
    switch (id) {
        0 => {
            try test_case(id, Person{
                .name = "ccccc",
                .age = 541212312321534534,
                .prob = 0.69,
                .data = &.{ 31, 69 },
            });
        },
        1 => {
            try test_case(id, Person{
                .name = "",
                .age = 699,
                .prob = 0.01,
                .data = &.{},
            });
        },
        else => unreachable,
    }
}

test "roundtrip" {
    try run_test(0);
    try run_test(1);
}
