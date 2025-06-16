const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();
const Allocator = std.mem.Allocator;

/// Swap bytes of integer if target is big endian
fn maybe_byte_swap(val: anytype) @TypeOf(val) {
    return switch (native_endian) {
        .big => @byteSwap(val),
        .little => val,
    };
}

/// Calculate the borsh serialized size of the given value, to be
///  used to allocate an output buffer to be passed to `serialize` function
pub fn calculate_serialized_size(comptime T: type, val: *const T) u64 {
    switch (T) {
        u8 => return 1,
        u16 => return 2,
        u32 => return 4,
        u64 => return 8,
        u128 => return 16,
        i8 => return 1,
        i16 => return 2,
        i32 => return 4,
        i64 => return 8,
        i128 => return 16,
        f32 => return 4,
        f64 => return 8,
        void => return 0,
        bool => return 1,
        else => {},
    }

    switch (@typeInfo(T)) {
        .array => |array_info| {
            var size: u64 = 0;

            for (val) |*elem| {
                size += calculate_serialized_size(array_info.child, elem);
            }

            return size;
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var size: u64 = 4;

                    for (val.*) |*elem| {
                        size += calculate_serialized_size(ptr_info.child, elem);
                    }

                    return size;
                },
                .one => {
                    return calculate_serialized_size(ptr_info.child, val.*);
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            var size: u64 = 0;

            inline for (struct_info.fields) |field| {
                size += calculate_serialized_size(field.type, &@field(val, field.name));
            }

            return size;
        },
        .@"enum" => |enum_info| {
            if (enum_info.fields.len >= 256) {
                @compileError("enum is too big to be represented by u8");
            }

            return 1;
        },
        .@"union" => |union_info| {
            const tag_t = union_info.tag_type orelse @compileError("non tagged unions are not supported");
            const tag_info = @typeInfo(tag_t).@"enum";

            if (tag_info.fields.len >= 256) {
                @compileError("tag enum is too big to be represented by u8");
            }

            const tag = @intFromEnum(val);
            inline for (union_info.fields, tag_info.fields) |field, tag_field| {
                if (tag_field.value == tag) {
                    return 1 + calculate_serialized_size(field.type, &@field(val, field.name));
                }
            }
        },
        .optional => |opt_info| {
            if (val.*) |*v| {
                return 1 + calculate_serialized_size(opt_info.child, v);
            } else {
                return 1;
            }
        },
        else => @compileError("unsupported type"),
    }
}

pub const SerializeError = error{
    /// There is remaining capacity in the output buffer after finishing serialization
    BufferTooBig,
};

// Serialize given object to borsh format. Returns error if the given output buffer is larger than needed.
//
// Invokes safety checked illegal behavior (out of bounds array access) when output buffer is not large enough to
//  fit the given object in borsh format.
pub fn serialize(comptime T: type, val: *const T, buffer: []u8) SerializeError!void {
    const out = serialize_impl(T, val, buffer);

    if (out.len > 0) {
        return SerializeError.BufferTooBig;
    }
}

fn serialize_impl(comptime T: type, val: *const T, output: []u8) []u8 {
    var out = output;

    switch (@typeInfo(T)) {
        .int => |int_info| {
            if (int_info.bits % 8 != 0) {
                @compileError("unsupported integer type");
            }
            const num_bytes = int_info.bits / 8;
            const bytes = @as([num_bytes]u8, @bitCast(maybe_byte_swap(val.*)));
            inline for (0..bytes.len) |i| {
                out[i] = bytes[i];
            }
            out = out[num_bytes..];
        },
        .float => |float_info| {
            if (float_info.bits != 32 and float_info.bits != 64) {
                @compileError("unsupported float type");
            }
            const int_t = std.meta.Int(.unsigned, float_info.bits);
            const int_ptr: *const int_t = @ptrCast(val);

            out = serialize_impl(int_t, int_ptr, out);
        },
        .void => {},
        .bool => {
            out[0] = val.*;
            out = out[1..];
        },
        .array => |array_info| {
            for (val) |*elem| {
                out = serialize_impl(array_info.child, elem, out);
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    out = serialize_impl(u32, &@intCast(val.len), out);

                    for (val.*) |*elem| {
                        out = serialize_impl(ptr_info.child, elem, out);
                    }
                },
                .one => {
                    out = serialize_impl(ptr_info.child, val.*, out);
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                out = serialize_impl(field.type, &@field(val, field.name), out);
            }
        },
        .@"enum" => |enum_info| {
            if (enum_info.fields.len >= 256) {
                @compileError("enum is too big to be represented by u8");
            }

            const tag = @intFromEnum(val);

            inline for (enum_info.fields, 0..) |enum_field, i| {
                if (enum_field.value == tag) {
                    out[0] = i;
                    out = out[1..];
                    break;
                }
            }
        },
        .@"union" => |union_info| {
            const tag_t = union_info.tag_type orelse @compileError("non tagged unions are not supported");
            const tag_info = @typeInfo(tag_t).@"enum";

            if (tag_info.fields.len >= 256) {
                @compileError("tag enum is too big to be represented by u8");
            }

            const tag = @intFromEnum(val);
            inline for (tag_info.fields, 0..) |tag_field, i| {
                if (tag_field.value == tag) {
                    out[0] = i;
                    out = out[1..];
                    break;
                }
            }
        },
        .optional => |opt_info| {
            if (val.*) |*v| {
                out[0] = 1;
                out = out[1..];

                out = serialize_impl(opt_info.child, v, out);
            } else {
                out[0] = 0;
                out = out[1..];
            }
        },
        else => @compileError("unsupported type"),
    }

    return out;
}

pub const DeserializeError = error{
    OutOfMemory,
    /// Input is smaller than expected
    InputTooSmall,
    /// There were remanining bytes after deserializing the object from given input
    InputTooBig,
    /// Encountered an invalid enum tag
    InvalidEnumTag,
    /// Encountered an invalid boolean value. Booleans have to be 1 or 0.
    InvalidBoolean,
};

/// Deserialize the given type of object from given input buffer.
///
/// Errors if input is too small or too big.
///
/// Pointers and slices are allocated using the given allocator, the output object doesn't borrow the input buffer in any way.
/// So the input buffer can be discarded after the deserialization is done.
pub fn deserialize(comptime T: type, input: []const u8, allocator: Allocator) DeserializeError!T {
    const out = try deserialize_impl(T, input, allocator);

    if (out.input.len > 0) {
        return DeserializeError.InputTooBig;
    }

    return out.val;
}

fn deserialize_impl(comptime T: type, input: []const u8, allocator: Allocator) DeserializeError!struct { input: []const u8, val: T } {
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

            return .{ .input = input[num_bytes..], .val = maybe_byte_swap(@as(T, @bitCast(bytes))) };
        },
        .float => |float_info| {
            if (float_info.bits != 32 and float_info.bits != 64) {
                @compileError("unsupported float type");
            }
            const int_t = std.meta.Int(.unsigned, float_info.bits);

            const out = try deserialize_impl(comptime int_t, input, allocator);

            return .{ .input = out.input, .val = @bitCast(out.val) };
        },
        .void => return .{ .input = input, .val = .{} },
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
                const out = try deserialize_impl(array_info.child, in);
                val[i] = out.val;
                in = out.input;
            }

            return .{ .input = in, .val = val };
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var in = input;

                    const len_out = try deserialize_impl(u32, in, allocator);
                    in = len_out.input;
                    const length = len_out.val;

                    const out = try allocator.alloc(ptr_info.child, length);
                    errdefer allocator.free(out);

                    for (0..length) |i| {
                        const elem_out = try deserialize_impl(ptr_info.child, in, allocator);
                        in = elem_out.input;
                        out[i] = elem_out.val;
                    }

                    return .{ .input = in, .val = out };
                },
                .one => {
                    const out = try deserialize_impl(ptr_info.child, input, allocator);

                    const ptr = try allocator.create(ptr_info.child);

                    ptr.* = out.val;

                    return .{ .input = out.input, .val = ptr };
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            var out: T = undefined;

            var in = input;

            inline for (struct_info.fields) |field| {
                const o = try deserialize_impl(field.type, in, allocator);
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
                    const out = try deserialize_impl(union_field.type, input[1..], allocator);
                    return .{ .input = out.input, .val = @unionInit(T, union_field.name, out.val) };
                }
            }

            return DeserializeError.InvalidEnumTag;
        },
        .optional => |opt_info| {
            const is_valid_out = try deserialize_impl(bool, input, allocator);

            if (is_valid_out.val) {
                const out = try deserialize_impl(opt_info.child, is_valid_out.input, allocator);
                return .{ .input = out.input, .val = out.val };
            } else {
                return .{ .input = is_valid_out.input, .val = null };
            }
        },
        else => @compileError("unsupported type"),
    }
}
