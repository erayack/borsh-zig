const native_endian = @import("builtin").target.cpu.arch.endian();

comptime {
    if (native_endian != .little) {
        @compileError("borsh-zig only supports little-endian architectures.");
    }
}

const tests = @import("./tests.zig");
const serde = @import("./serde.zig");

pub const serialize = serde.serialize;
pub const SerializeError = serde.SerializeError;

pub const deserialize = serde.deserialize;
pub const deserialize_stream = serde.deserialize_stream;
pub const DeserializeError = serde.DeserializeError;

test {
    _ = tests;
    _ = serde;
}
