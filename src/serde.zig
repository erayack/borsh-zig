const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SerializeError = error{
    /// Buffer isn't big enough to hold the output
    BufferTooSmall,
    MaxRecursionDepthReached,
};

pub fn serialize(comptime T: type, val: *const T, buffer: []u8, max_recursion_depth: u8) SerializeError!usize {
    return try serialize_impl(T, val, buffer, 0, max_recursion_depth);
}

fn serialize_impl(comptime T: type, val: *const T, output: []u8, depth: u8, max_depth: u8) SerializeError!usize {
    if (depth >= max_depth) return SerializeError.MaxRecursionDepthReached;

    switch (@typeInfo(T)) {
        .int => |int_info| {
            if (int_info.bits % 8 != 0) {
                @compileError("unsupported integer type");
            }
            const num_bytes = int_info.bits / 8;
            if (output.len < num_bytes) {
                return SerializeError.BufferTooSmall;
            }

            const bytes = @as([num_bytes]u8, @bitCast(val.*));
            inline for (0..bytes.len) |i| {
                output[i] = bytes[i];
            }
            return num_bytes;
        },
        .float => |float_info| {
            if (float_info.bits != 16 and float_info.bits != 32 and float_info.bits != 64) {
                @compileError("unsupported float type");
            }
            const num_bytes = float_info.bits / 8;
            if (output.len < num_bytes) {
                return SerializeError.BufferTooSmall;
            }

            const bytes = @as([num_bytes]u8, @bitCast(val.*));
            inline for (0..bytes.len) |i| {
                output[i] = bytes[i];
            }
            return num_bytes;
        },
        .void => return 0,
        .bool => {
            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }
            output[0] = @intFromBool(val.*);
            return 1;
        },
        .array => |array_info| {
            var n_written: usize = 0;
            for (val) |*elem| {
                n_written += try serialize_impl(array_info.child, elem, output[n_written..], depth + 1, max_depth);
            }
            return n_written;
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var n_written: usize = try serialize_impl(u32, &@intCast(val.len), output, depth + 1, max_depth);

                    for (val.*) |*elem| {
                        n_written += try serialize_impl(ptr_info.child, elem, output[n_written..], depth + 1, max_depth);
                    }

                    if (ptr_info.sentinel()) |sentinel| {
                        n_written += try serialize_impl(ptr_info.child, &sentinel, output[n_written..], depth + 1, max_depth);
                    }

                    return n_written;
                },
                .one => {
                    return try serialize_impl(ptr_info.child, val.*, output, depth + 1, max_depth);
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("tuple isn't supported");
            }
            var n_written: usize = 0;
            inline for (struct_info.fields) |field| {
                n_written += try serialize_impl(field.type, &@field(val, field.name), output[n_written..], depth + 1, max_depth);
            }
            return n_written;
        },
        .@"enum" => |enum_info| {
            if (enum_info.fields.len >= 256) {
                @compileError("enum is too big to be represented by u8");
            }

            const tag = @intFromEnum(val.*);

            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }

            inline for (enum_info.fields, 0..) |enum_field, i| {
                if (enum_field.value == tag) {
                    output[0] = i;
                    return 1;
                }
            }

            unreachable;
        },
        .@"union" => |union_info| {
            const tag_t = union_info.tag_type orelse @compileError("non tagged unions are not supported");
            const tag_info = @typeInfo(tag_t).@"enum";

            if (tag_info.fields.len >= 256) {
                @compileError("tag enum is too big to be represented by u8");
            }

            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }

            const tag = @intFromEnum(val.*);
            inline for (tag_info.fields, union_info.fields, 0..) |tag_field, union_field, i| {
                if (tag_field.value == tag) {
                    output[0] = i;
                    return 1 + try serialize_impl(union_field.type, &@field(val, union_field.name), output[1..], depth + 1, max_depth);
                }
            }

            unreachable;
        },
        .optional => |opt_info| {
            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }

            if (val.*) |*v| {
                output[0] = 1;
                return 1 + try serialize_impl(opt_info.child, v, output[1..], depth + 1, max_depth);
            } else {
                output[0] = 0;
                return 1;
            }
        },
        else => @compileError("unsupported type"),
    }
}

pub const DeserializeError = error{
    OutOfMemory,
    MaxRecursionDepthReached,
    /// There are remaining input data after finishing deserialisation
    RemaniningBytes,
    /// Input is smaller than expected
    InputTooSmall,
    /// Encountered an invalid enum tag
    InvalidEnumTag,
    /// Encountered an invalid boolean value. Booleans have to be 1 or 0.
    InvalidBoolean,
    /// Found the sentinel in slice elements
    SentinelInSlice,
    /// The sentinel in input doesn't match the sentinel in type
    WrongSentinel,
};

/// Deserialize the given type of object from given input buffer.
///
/// Errors if input is too small or too big.
///
/// Pointers and slices are allocated using the given allocator, the output object doesn't borrow the input buffer in any way.
/// So the input buffer can be discarded after the deserialization is done.
pub fn deserialize(comptime T: type, input: []const u8, allocator: Allocator, max_recursion_depth: u8) DeserializeError!T {
    const out = try deserialize_impl(T, input, allocator, 0, max_recursion_depth);

    if (out.input.len > 0) {
        return DeserializeError.RemaniningBytes;
    }

    return out.val;
}

fn deserialize_impl(comptime T: type, input: []const u8, allocator: Allocator, depth: u8, max_depth: u8) DeserializeError!struct { input: []const u8, val: T } {
    if (depth >= max_depth) return DeserializeError.MaxRecursionDepthReached;

    switch (@typeInfo(T)) {
        .int => |int_info| {
            if (int_info.bits % 8 != 0) {
                @compileError("unsupported integer type");
            }
            const num_bytes = int_info.bits / 8;

            if (input.len < num_bytes) {
                return DeserializeError.InputTooSmall;
            }

            var bytes: [num_bytes]u8 = undefined;
            inline for (0..num_bytes) |i| {
                bytes[i] = input[i];
            }

            return .{ .input = input[num_bytes..], .val = @as(T, @bitCast(bytes)) };
        },
        .float => |float_info| {
            if (float_info.bits != 16 and float_info.bits != 32 and float_info.bits != 64) {
                @compileError("unsupported float type");
            }
            const num_bytes = float_info.bits / 8;

            if (input.len < num_bytes) {
                return DeserializeError.InputTooSmall;
            }

            var bytes: [num_bytes]u8 = undefined;
            inline for (0..num_bytes) |i| {
                bytes[i] = input[i];
            }

            return .{ .input = input[num_bytes..], .val = @as(T, @bitCast(bytes)) };
        },
        .void => return .{ .input = input, .val = void{} },
        .bool => {
            if (input.len == 0) {
                return DeserializeError.InputTooSmall;
            }

            if (input[0] > 1) {
                return DeserializeError.InvalidBoolean;
            }

            return .{ .input = input[1..], .val = input[0] == 1 };
        },
        .array => |array_info| {
            var in = input;

            var val: [array_info.len]array_info.child = undefined;

            for (0..val.len) |i| {
                const out = try deserialize_impl(array_info.child, in, allocator, depth + 1, max_depth);
                val[i] = out.val;
                in = out.input;
            }

            return .{ .input = in, .val = val };
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var in = input;

                    const len_out = try deserialize_impl(u32, in, allocator, depth + 1, max_depth);
                    in = len_out.input;
                    const length = len_out.val;

                    if (ptr_info.sentinel()) |sentinel| {
                        const out = try allocator.allocSentinel(ptr_info.child, length, sentinel);
                        errdefer allocator.free(out);

                        for (0..length) |i| {
                            const elem_out = try deserialize_impl(ptr_info.child, in, allocator, depth + 1, max_depth);
                            in = elem_out.input;

                            if (elem_out.val == sentinel) {
                                return DeserializeError.SentinelInSlice;
                            }

                            out[i] = elem_out.val;
                        }

                        const sentinel_out = try deserialize_impl(ptr_info.child, in, allocator, depth + 1, max_depth);
                        in = sentinel_out.input;
                        if (sentinel_out.val != sentinel) {
                            return DeserializeError.WrongSentinel;
                        }

                        return .{ .input = in, .val = out };
                    } else {
                        const out = try allocator.alloc(ptr_info.child, length);
                        errdefer allocator.free(out);

                        for (0..length) |i| {
                            const elem_out = try deserialize_impl(ptr_info.child, in, allocator, depth + 1, max_depth);
                            in = elem_out.input;
                            out[i] = elem_out.val;
                        }

                        return .{ .input = in, .val = out };
                    }
                },
                .one => {
                    const out = try deserialize_impl(ptr_info.child, input, allocator, depth + 1, max_depth);

                    const ptr = try allocator.create(ptr_info.child);

                    ptr.* = out.val;

                    return .{ .input = out.input, .val = ptr };
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("tuple isn't supported");
            }
            var out: T = undefined;

            var in = input;

            inline for (struct_info.fields) |field| {
                const o = try deserialize_impl(field.type, in, allocator, depth + 1, max_depth);
                in = o.input;
                @field(out, field.name) = o.val;
            }

            return .{ .input = in, .val = out };
        },
        .@"enum" => |enum_info| {
            if (enum_info.fields.len >= 256) {
                @compileError("enum is too big to be represented by u8");
            }

            if (input.len == 0) {
                return DeserializeError.InputTooSmall;
            }

            const index = input[0];

            inline for (enum_info.fields, 0..) |enum_field, i| {
                if (index == i) {
                    return .{ .input = input[1..], .val = @enumFromInt(enum_field.value) };
                }
            }

            return DeserializeError.InvalidEnumTag;
        },
        .@"union" => |union_info| {
            const tag_t = union_info.tag_type orelse @compileError("non tagged unions are not supported");
            const tag_info = @typeInfo(tag_t).@"enum";

            if (tag_info.fields.len >= 256) {
                @compileError("tag enum is too big to be represented by u8");
            }

            if (input.len == 0) {
                return DeserializeError.InputTooSmall;
            }

            const index = input[0];

            inline for (union_info.fields, 0..) |union_field, i| {
                if (index == i) {
                    const out = try deserialize_impl(union_field.type, input[1..], allocator, depth + 1, max_depth);
                    return .{ .input = out.input, .val = @unionInit(T, union_field.name, out.val) };
                }
            }

            return DeserializeError.InvalidEnumTag;
        },
        .optional => |opt_info| {
            const is_valid_out = try deserialize_impl(bool, input, allocator, depth + 1, max_depth);

            if (is_valid_out.val) {
                const out = try deserialize_impl(opt_info.child, is_valid_out.input, allocator, depth + 1, max_depth);
                return .{ .input = out.input, .val = out.val };
            } else {
                return .{ .input = is_valid_out.input, .val = null };
            }
        },
        else => @compileError("unsupported type"),
    }
}
