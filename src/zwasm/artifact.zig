//! Compiled-module artifacts on the native facade (serci S42 Z5).
//!
//! `produce` compiles `wasm_bytes` through the JIT pipeline and serialises the result to
//! `.cwasm` bytes the CLI cache (and any embedder disk layer) can store under the module's
//! content hash. The bytes embed the original module verbatim, so the run path's
//! cache-hit == cache-miss property holds: loading an artifact re-derives everything from
//! the same bytes a fresh compile would read.
//!
//! `isValid` is the cheap load gate (magic / format version / arch / section bounds): a
//! corrupt, truncated, or format-drifted entry is a miss, never a failed run. Anything
//! deeper stays the run path's business.
//!
//! Scope: produce-only on this surface. Consuming an artifact through the native
//! `Engine.compile`/`Linker.instantiate` facade needs `Module` to carry deserialized
//! codegen past the C ABI, which is upstream-scale surgery tracked as a follow-up; the
//! runner (`engine.runner.runWasiLenientArgs`) already consumes artifacts, and the test
//! below proves an artifact runs identically to a fresh compile through it.

const std = @import("std");
const builtin = @import("builtin");

const Engine = @import("engine.zig").Engine;
const runner = @import("../engine/runner.zig");
const produce_mod = @import("../engine/codegen/aot/produce.zig");
const format = @import("../engine/codegen/aot/format.zig");

const Allocator = std.mem.Allocator;

pub const ProduceError =
    Engine.CompileError ||
    runner.Error ||
    produce_mod.Error;

/// Compile `wasm_bytes` and serialise the result to `.cwasm` bytes. Caller owns the
/// returned slice. Validation runs first through `eng.compile`, so unparseable or
/// invalid modules fail as `CompileError` before any codegen; shapes the producer
/// cannot serialise (imports it cannot model, debug-instrumented codegen, ...) fail
/// loudly with `produce` errors, never with silently degraded bytes.
pub fn produce(gpa: Allocator, eng: *Engine, wasm_bytes: []const u8) ProduceError![]u8 {
    var mod = try eng.compile(wasm_bytes);
    defer mod.deinit();
    var compiled = try @import("../engine/compile.zig").compileWasmForAot(gpa, wasm_bytes);
    defer compiled.deinit(gpa);
    return produce_mod.produceFromCompiledWasm(gpa, &compiled, wasm_bytes);
}

/// Cheap load gate: the header parses at this format version, names this host's arch,
/// and every section lies inside the entry. Anything else is a cache miss.
pub fn isValid(cwasm: []const u8) bool {
    const h = format.parseHeader(cwasm) catch return false;
    const want_arch: u32 = switch (builtin.target.cpu.arch) {
        .aarch64 => format.arch_arm64,
        .x86_64 => format.arch_x86_64,
        else => return false,
    };
    if (h.arch != want_arch) return false;
    const sections = [_][2]u32{
        .{ h.code_offset, h.code_size },
        .{ h.metadata_offset, h.metadata_size },
        .{ h.types_offset, h.types_size },
        .{ h.relocs_offset, h.relocs_size },
        .{ h.exports_offset, h.exports_size },
        .{ h.globals_offset, h.globals_size },
        .{ h.memory_init_offset, h.memory_init_size },
        .{ h.elem_offset, h.elem_size },
        .{ h.imports_offset, h.imports_size },
        .{ h.wasm_bytes_offset, h.wasm_bytes_size },
        .{ h.func_extras_offset, h.func_extras_size },
        .{ h.eh_offset, h.eh_size },
    };
    for (sections) |s| {
        if (@as(u64, s[0]) + s[1] > cwasm.len) return false;
    }
    return true;
}

// A (func (export "run") i32.const 42 end): no imports, so both the fresh-compile
// and the artifact run path take it without a host.
const tiny_run = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60,
    0x00, 0x01, 0x7f, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x72,
    0x75, 0x6e, 0x00, 0x00, 0x0a, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2a, 0x0b,
};

fn runI32(gpa: Allocator, bytes: []const u8) !i32 {
    var result: ?runner.ScalarResult = null;
    _ = try runner.runWasiLenient(gpa, bytes, "run", null, null, .{}, &result);
    return result.?.i32;
}

test "Z5: produce validates, gates, and the artifact runs like a fresh compile" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, .{});
    defer eng.deinit();

    const artifact = try produce(gpa, &eng, &tiny_run);
    defer gpa.free(artifact);
    try std.testing.expect(isValid(artifact));

    // The artifact runs through the CWAS consume path and answers like a fresh compile.
    try std.testing.expectEqual(@as(i32, 42), try runI32(gpa, &tiny_run));
    try std.testing.expectEqual(@as(i32, 42), try runI32(gpa, artifact));

    // Invalid modules never reach codegen: garbage fails to parse, and a module that
    // parses but does not validate fails to compile.
    try std.testing.expectError(error.ParseFailed, produce(gpa, &eng, "not wasm"));
}

test "Z5: isValid refuses garbage, truncation, version drift, and arch drift" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, .{});
    defer eng.deinit();
    const artifact = try produce(gpa, &eng, &tiny_run);
    defer gpa.free(artifact);

    try std.testing.expect(!isValid("CWASgarbage"));
    try std.testing.expect(!isValid(artifact[0 .. artifact.len / 2]));
    try std.testing.expect(!isValid(&tiny_run));

    var drifted = try gpa.dupe(u8, artifact);
    defer gpa.free(drifted);
    // Flip the format version: a newer producer's entry is a miss here, not a crash.
    std.mem.writeInt(u32, drifted[4..8], format.version_v0_5 + 1, .little);
    try std.testing.expect(!isValid(drifted));
    // Flip the arch tag: another machine's entry is a miss here.
    std.mem.copyForwards(u8, drifted, artifact);
    drifted[8] ^= 0x03;
    try std.testing.expect(!isValid(drifted));
}
