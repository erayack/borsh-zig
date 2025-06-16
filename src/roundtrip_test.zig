const std = @import("std");
const testing = std.testing;

// Each `id` corresponds to a specific arrow array, this function is supposed to import the given array, create a new array based on the `id` it receives, assert these two arrays are equal,
// and export the array it created back to the caller.
extern fn roundtrip_test_case(id: u8, input: *const u8, input_len: usize, output: **const u8, output_len: *usize) void;

test "roundtrip" {}
