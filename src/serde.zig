const std = @import("std");
const Allocator = std.mem.Allocator;

/// Returns true when `T` is safe to treat as raw bytes at compile time.
///
/// Integers, floats and zero-sized or `void` types have a stable,
/// byte-addressable layout in Zig, so copying them byte-for-byte is well-defined.
pub fn isRawCopySafe(comptime T: type) bool {
    if (@sizeOf(T) == 0) return true;

    return switch (@typeInfo(T)) {
        .int, .float => true,
        .bool => true,
        .void => true,
        else => false,
    };
}

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
            const total_bytes: usize = std.math.mul(usize, array_info.len, @sizeOf(array_info.child)) catch return SerializeError.BufferTooSmall;

            if (isRawCopySafe(array_info.child) and total_bytes <= output.len) {
                const source_bytes = std.mem.asBytes(val);
                std.mem.copyForwards(u8, output[0..total_bytes], source_bytes);
                return total_bytes;
            }

            var n_written: usize = 0;
            for (val) |*elem| {
                n_written += try serialize_impl(
                    array_info.child,
                    elem,
                    output[n_written..],
                    depth + 1,
                    max_depth,
                );
            }
            return n_written;
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var len_u32: u32 = @as(u32, @intCast(val.len));
                    var n_written: usize = try serialize_impl(
                        u32,
                        &len_u32,
                        output,
                        depth + 1,
                        max_depth,
                    );

                    if (ptr_info.sentinel() == null and isRawCopySafe(ptr_info.child)) {
                        const elem_bytes = std.mem.sliceAsBytes(val.*);
                        if (output.len < n_written + elem_bytes.len) {
                            return SerializeError.BufferTooSmall;
                        }
                        const dest = output[n_written .. n_written + elem_bytes.len];
                        std.mem.copyForwards(u8, dest, elem_bytes);
                        return n_written + elem_bytes.len;
                    }

                    for (val.*) |*elem| {
                        n_written += try serialize_impl(
                            ptr_info.child,
                            elem,
                            output[n_written..],
                            depth + 1,
                            max_depth,
                        );
                    }

                    return n_written;
                },
                .one => {
                    return try serialize_impl(
                        ptr_info.child,
                        val.*,
                        output,
                        depth + 1,
                        max_depth,
                    );
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
                n_written += try serialize_impl(
                    field.type,
                    &@field(val, field.name),
                    output[n_written..],
                    depth + 1,
                    max_depth,
                );
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
                    return 1 + try serialize_impl(
                        union_field.type,
                        &@field(val, union_field.name),
                        output[1..],
                        depth + 1,
                        max_depth,
                    );
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
};

inline fn validateBoolBytes(bytes: []const u8) DeserializeError!void {
    for (bytes) |byte| {
        if (byte > 1) {
            return DeserializeError.InvalidBoolean;
        }
    }
}

/// Deserialize the given type of object from given input buffer.
///
/// Errors if input is too small or too big.
///
/// Pointers and slices are allocated using the given allocator,
///     the output object doesn't borrow the input buffer in any way.
/// So the input buffer can be discarded after the deserialization is done.
pub fn deserialize(
    comptime T: type,
    input: []const u8,
    allocator: Allocator,
    max_recursion_depth: u8,
) DeserializeError!T {
    const out = try deserialize_impl(T, input, allocator, 0, max_recursion_depth);

    if (out.input.len > 0) {
        return DeserializeError.RemaniningBytes;
    }

    return out.val;
}

/// Same as `deserialize` but doesn't error if there are remaining input bytes after finishing the deserialization.
///
/// It will return of offset that it used up to when deserializing so caller can continue deserializing other data.
/// using `input[out.offset..]`
pub fn deserialize_stream(
    comptime T: type,
    input: []const u8,
    allocator: Allocator,
    max_recursion_depth: u8,
) DeserializeError!struct { val: T, offset: usize } {
    const out = try deserialize_impl(T, input, allocator, 0, max_recursion_depth);
    return .{ .val = out.val, .offset = input.len - out.input.len };
}

fn deserialize_impl(
    comptime T: type,
    input: []const u8,
    allocator: Allocator,
    depth: u8,
    max_depth: u8,
) DeserializeError!struct { input: []const u8, val: T } {
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

            if (isRawCopySafe(array_info.child)) {
                const byte_len = array_info.len * @sizeOf(array_info.child);
                if (in.len < byte_len) {
                    return DeserializeError.InputTooSmall;
                }
                const child_is_bool = comptime switch (@typeInfo(array_info.child)) {
                    .bool => true,
                    else => false,
                };
                if (child_is_bool) {
                    try validateBoolBytes(in[0..byte_len]);
                }
                if (byte_len != 0) {
                    const dest_bytes = std.mem.asBytes(&val);
                    @memcpy(dest_bytes[0..byte_len], in[0..byte_len]);
                }
                return .{ .input = in[byte_len..], .val = val };
            }

            for (0..val.len) |i| {
                const out = try deserialize_impl(
                    array_info.child,
                    in,
                    allocator,
                    depth + 1,
                    max_depth,
                );
                val[i] = out.val;
                in = out.input;
            }

            return .{ .input = in, .val = val };
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var in = input;

                    const len_out = try deserialize_impl(
                        u32,
                        in,
                        allocator,
                        depth + 1,
                        max_depth,
                    );
                    in = len_out.input;
                    const length = len_out.val;

                    const len_usize = @as(usize, @intCast(length));

                    if (ptr_info.sentinel()) |sentinel| {
                        const out = try allocator.allocSentinel(
                            ptr_info.child,
                            len_usize,
                            sentinel,
                        );
                        errdefer allocator.free(out);

                        for (0..len_usize) |i| {
                            const elem_out = try deserialize_impl(
                                ptr_info.child,
                                in,
                                allocator,
                                depth + 1,
                                max_depth,
                            );
                            in = elem_out.input;

                            if (elem_out.val == sentinel) {
                                return DeserializeError.SentinelInSlice;
                            }

                            out[i] = elem_out.val;
                        }

                        return .{ .input = in, .val = out };
                    }

                    const out = try allocator.alloc(ptr_info.child, len_usize);
                    errdefer allocator.free(out);

                    if (isRawCopySafe(ptr_info.child)) {
                        const byte_len = std.math.mul(usize, len_usize, @sizeOf(ptr_info.child)) catch return DeserializeError.InputTooSmall;
                        if (in.len < byte_len) {
                            return DeserializeError.InputTooSmall;
                        }
                        const child_is_bool = comptime switch (@typeInfo(ptr_info.child)) {
                            .bool => true,
                            else => false,
                        };
                        if (child_is_bool) {
                            try validateBoolBytes(in[0..byte_len]);
                        }
                        if (byte_len != 0) {
                            const dest_bytes = std.mem.sliceAsBytes(out);
                            @memcpy(dest_bytes[0..byte_len], in[0..byte_len]);
                        }
                        in = in[byte_len..];
                        return .{ .input = in, .val = out };
                    }

                    for (0..len_usize) |i| {
                        const elem_out = try deserialize_impl(
                            ptr_info.child,
                            in,
                            allocator,
                            depth + 1,
                            max_depth,
                        );
                        in = elem_out.input;
                        out[i] = elem_out.val;
                    }

                    return .{ .input = in, .val = out };
                },
                .one => {
                    const out = try deserialize_impl(
                        ptr_info.child,
                        input,
                        allocator,
                        depth + 1,
                        max_depth,
                    );

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
                const o = try deserialize_impl(
                    field.type,
                    in,
                    allocator,
                    depth + 1,
                    max_depth,
                );
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
                    const out = try deserialize_impl(
                        union_field.type,
                        input[1..],
                        allocator,
                        depth + 1,
                        max_depth,
                    );
                    return .{ .input = out.input, .val = @unionInit(T, union_field.name, out.val) };
                }
            }

            return DeserializeError.InvalidEnumTag;
        },
        .optional => |opt_info| {
            const is_valid_out = try deserialize_impl(bool, input, allocator, depth + 1, max_depth);

            if (is_valid_out.val) {
                const out = try deserialize_impl(
                    opt_info.child,
                    is_valid_out.input,
                    allocator,
                    depth + 1,
                    max_depth,
                );
                return .{ .input = out.input, .val = out.val };
            } else {
                return .{ .input = is_valid_out.input, .val = null };
            }
        },
        else => @compileError("unsupported type"),
    }
}
