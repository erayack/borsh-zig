const native_endian = @import("builtin").target.cpu.arch.endian();

comptime {
    if (native_endian != .little) {
        @compileError("borsh-zig only supports little-endian architectures.");
    }
}

const tests = @import("./tests.zig");
pub const serde = @import("./serde.zig");

test {
    _ = tests;
    _ = serde;
}
