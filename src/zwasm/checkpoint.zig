//! Z4 instance checkpoint/restore (serci S42).
//!
//! `checkpoint` serialises an instance's mutable state — linear-memory pages,
//! globals, tables, data/elem dropped flags, and remaining fuel — into
//! versioned bytes; `restoreInto` applies those bytes to a FRESH instance of
//! the same module (same engine), so `restore(checkpoint(A))` then `exec`
//! equals `exec` on A (K2 extended). The fresh instance is created through the
//! normal path (linker/host imports wired by the caller), which is what makes
//! imports work: host funcs carry no per-instance state, so only the defined
//! memories/globals/tables are recorded.
//!
//! Scope refusals (explicit errors, never silent divergence):
//! - imported memories/globals/tables alias another instance's storage; a
//!   module importing any is refused (`ImportedEntitiesUnsupported`). Func and
//!   tag imports are fine (no mutable instance state).
//! - multi-memory modules are refused (`MultiMemoryUnsupported`).
//! - tables whose element type is neither funcref nor externref are refused
//!   (`UnsupportedTableType`); GC reference types need their heap on restore.
//! - externref cells round-trip as raw u64 handles: restore is same-process
//!   only when externref tables are non-empty (documented, not detected).
//! - restore refuses engine, module (blake3), and shape mismatches loudly.
//!
//! Format (all integers little-endian, every read bounds-checked on restore):
//!   magic "ZCHKPT01" (8) | engine u8 (0 interp, 1 jit) |
//!   fuel_flag u8 | fuel u64 | module_hash [32]blake3(wasm_bytes) |
//!   mem_pages u32 | mem bytes |
//!   nglobals u32 | nglobals * 16 raw bytes |
//!   ntables u32 | per table: is_funcref u8 | len u64 | cells |
//!     funcref cell: tag u8 (0 null | 1 funcidx u32)
//!     externref cell: tag u8 (0 null | 1 raw u64) |
//!   ndata u32 | dropped bytes | nelem u32 | dropped bytes
//! Trailing bytes after the last section are `BadCheckpoint`.

const std = @import("std");
const _instance = @import("instance.zig");
const _runtime = @import("../runtime/runtime.zig");
const _value = @import("../runtime/value.zig");
const _func = @import("../runtime/instance/func.zig");
const _runner = @import("../engine/runner.zig");
const _entry = @import("../engine/codegen/shared/entry.zig");
const _sections = @import("../parse/sections.zig");
const _leb128 = @import("../support/leb128.zig");
const _zir = @import("../ir/zir.zig");

const Allocator = std.mem.Allocator;

pub const magic = "ZCHKPT01";
pub const engine_interp: u8 = 0;
pub const engine_jit: u8 = 1;

/// 64 KiB pages (Wasm spec section 4.4.7).
pub const page_bytes: usize = 65536;

comptime {
    if (@sizeOf(_value.Value) != 16) @compileError("checkpoint assumes 16-byte runtime Values");
}

pub const CheckpointError = error{
    OutOfMemory,
    NoEngine,
    ImportedEntitiesUnsupported,
    MultiMemoryUnsupported,
    UnsupportedTableType,
};

pub const RestoreError = error{
    OutOfMemory,
    BadCheckpoint,
    EngineMismatch,
    ModuleMismatch,
    StateMismatch,
    GrowFailed,
    TableMirrorUnavailable,
    UnsupportedTableSize,
};

/// Refuse a module whose imports carry mutable instance state (S42 Z4 scope).
/// Func and tag imports are stateless and pass; table/memory/global imports
/// alias another instance's storage, so they fail loudly. Pure over the bytes.
pub fn scanImports(gpa: Allocator, wasm_bytes: []const u8) CheckpointError!void {
    const body = findSection(wasm_bytes, 2) orelse return;
    var imports = _sections.decodeImports(gpa, body) catch return error.ImportedEntitiesUnsupported;
    defer imports.deinit();
    for (imports.items) |imp| {
        switch (imp.kind) {
            .func, .tag => {},
            .table, .memory, .global => return error.ImportedEntitiesUnsupported,
        }
    }
}

/// First section body with the given id, or null when absent/malformed.
fn findSection(wasm_bytes: []const u8, id: u32) ?[]const u8 {
    if (wasm_bytes.len < 8) return null;
    var pos: usize = 8;
    while (pos < wasm_bytes.len) {
        const sid = _leb128.readUleb128(u32, wasm_bytes, &pos) catch return null;
        const size = _leb128.readUleb128(u32, wasm_bytes, &pos) catch return null;
        if (size > wasm_bytes.len - pos) return null;
        const body = wasm_bytes[pos .. pos + size];
        if (sid == id) return body;
        pos += size;
    }
    return null;
}

fn isFuncref(elem_type: _zir.ValType) bool {
    if (elem_type != .ref) return false;
    switch (elem_type.ref.heap_type) {
        .abstract => |a| return a == .func,
        .concrete => return false,
    }
}

fn isExternref(elem_type: _zir.ValType) bool {
    if (elem_type != .ref) return false;
    switch (elem_type.ref.heap_type) {
        .abstract => |a| return a == .extern_,
        .concrete => return false,
    }
}

const Writer = struct {
    out: std.ArrayList(u8) = .empty,

    fn bytes(self: *Writer, gpa: Allocator, data: []const u8) Allocator.Error!void {
        try self.out.appendSlice(gpa, data);
    }

    fn u8v(self: *Writer, gpa: Allocator, v: u8) Allocator.Error!void {
        try self.out.append(gpa, v);
    }

    fn u32v(self: *Writer, gpa: Allocator, v: u32) Allocator.Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try self.out.appendSlice(gpa, &buf);
    }

    fn u64v(self: *Writer, gpa: Allocator, v: u64) Allocator.Error!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        try self.out.appendSlice(gpa, &buf);
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) RestoreError![]const u8 {
        if (n > self.bytes.len - self.pos) return error.BadCheckpoint;
        const slice = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn ru8(self: *Reader) RestoreError!u8 {
        return (try self.take(1))[0];
    }

    fn ru32(self: *Reader) RestoreError!u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    fn ru64(self: *Reader) RestoreError!u64 {
        const b = try self.take(8);
        return std.mem.readInt(u64, b[0..8], .little);
    }
};

/// Serialise `inst`'s mutable state. `wasm_bytes` is the module the instance
/// was built from (identity hash + import scan). Caller owns the result.
pub fn checkpoint(gpa: Allocator, inst: *_instance.Instance, wasm_bytes: []const u8) (CheckpointError || Allocator.Error)![]u8 {
    try scanImports(gpa, wasm_bytes);
    var w = Writer{};
    errdefer w.out.deinit(gpa);
    try w.bytes(gpa, magic);
    if (inst.handle.runtime) |rt| {
        try w.u8v(gpa, engine_interp);
        try writeFuel(gpa, &w, rt.fuel);
        try writeModuleHash(gpa, &w, wasm_bytes);
        try writeMemory(gpa, &w, rt.memory);
        try writeGlobals(gpa, &w, rt);
        try writeTablesInterp(gpa, &w, rt);
        try writeDropped(gpa, &w, rt.data_dropped, rt.elem_dropped);
    } else if (inst.jitHandle()) |jit| {
        try w.u8v(gpa, engine_jit);
        try writeFuel(gpa, &w, jit.fuelRemaining());
        try writeModuleHash(gpa, &w, wasm_bytes);
        try writeMemory(gpa, &w, jit.owned.rt.vm_base[0..jit.owned.rt.mem_limit]);
        try writeGlobalsJit(gpa, &w, jit);
        try writeTablesJit(gpa, &w, jit);
        try writeDroppedJit(gpa, &w, jit);
    } else {
        return error.NoEngine;
    }
    return w.out.toOwnedSlice(gpa);
}

/// Apply checkpoint `bytes` to a fresh instance of the same module + engine.
/// `wasm_bytes` must be the module bytes (identity check). Grows memories and
/// tables up to the recorded sizes, then overwrites every recorded cell.
pub fn restoreInto(inst: *_instance.Instance, wasm_bytes: []const u8, bytes: []const u8) RestoreError!void {
    var r = Reader{ .bytes = bytes };
    const got_magic = try r.take(8);
    if (!std.mem.eql(u8, got_magic, magic)) return error.BadCheckpoint;
    const engine = try r.ru8();
    const fuel_flag = try r.ru8();
    const fuel = try r.ru64();
    const want_hash = try r.take(32);
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(wasm_bytes, &digest, .{});
    if (!std.mem.eql(u8, want_hash, &digest)) return error.ModuleMismatch;

    if (inst.handle.runtime) |rt| {
        if (engine != engine_interp) return error.EngineMismatch;
        try readMemory(&r, inst, rt.memory.len);
        try readGlobals(&r, rt);
        try readTablesInterp(&r, rt);
        try readDropped(&r, rt);
        inst.setFuel(if (fuel_flag == 0) null else fuel);
    } else if (inst.jitHandle()) |jit| {
        if (engine != engine_jit) return error.EngineMismatch;
        try readMemory(&r, inst, @intCast(jit.owned.rt.mem_limit));
        try readGlobalsJit(&r, jit);
        try readTablesJit(&r, jit);
        try readDroppedJit(&r, jit);
        inst.setFuel(if (fuel_flag == 0) null else fuel);
    } else {
        return error.BadCheckpoint;
    }
    if (r.pos != r.bytes.len) return error.BadCheckpoint;
}

fn writeFuel(gpa: Allocator, w: *Writer, fuel: ?u64) Allocator.Error!void {
    if (fuel) |f| {
        try w.u8v(gpa, 1);
        try w.u64v(gpa, f);
    } else {
        try w.u8v(gpa, 0);
        try w.u64v(gpa, 0);
    }
}

fn writeModuleHash(gpa: Allocator, w: *Writer, wasm_bytes: []const u8) Allocator.Error!void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(wasm_bytes, &digest, .{});
    try w.bytes(gpa, &digest);
}

fn writeMemory(gpa: Allocator, w: *Writer, mem: []const u8) (CheckpointError || Allocator.Error)!void {
    if (mem.len % page_bytes != 0) return error.MultiMemoryUnsupported;
    const pages = mem.len / page_bytes;
    if (pages > std.math.maxInt(u32)) return error.MultiMemoryUnsupported;
    try w.u32v(gpa, @intCast(pages));
    try w.bytes(gpa, mem);
}

fn writeGlobals(gpa: Allocator, w: *Writer, rt: *_runtime.Runtime) (CheckpointError || Allocator.Error)!void {
    // No global imports (scanImports refused them), so every slot is defined.
    if (rt.globals.len != rt.globals_storage.len) return error.ImportedEntitiesUnsupported;
    if (rt.globals.len > std.math.maxInt(u32)) return error.MultiMemoryUnsupported;
    try w.u32v(gpa, @intCast(rt.globals.len));
    for (rt.globals) |slot| {
        try w.bytes(gpa, std.mem.asBytes(slot));
    }
}

fn writeGlobalsJit(gpa: Allocator, w: *Writer, jit: *_runner.JitInstance) Allocator.Error!void {
    const n = jit.owned.rt.globals_count;
    try w.u32v(gpa, n);
    for (0..n) |i| {
        try w.bytes(gpa, std.mem.asBytes(&jit.owned.rt.globals_base[i]));
    }
}

fn writeTablesInterp(gpa: Allocator, w: *Writer, rt: *_runtime.Runtime) (CheckpointError || Allocator.Error)!void {
    if (rt.tables.len > std.math.maxInt(u32)) return error.MultiMemoryUnsupported;
    try w.u32v(gpa, @intCast(rt.tables.len));
    for (rt.tables) |tab| {
        if (isFuncref(tab.elem_type)) {
            try w.u8v(gpa, 1);
            try writeLen(gpa, w, tab.refs.len);
            for (tab.refs) |cell| {
                const ref = cell.ref;
                if (ref == _value.Value.null_ref) {
                    try w.u8v(gpa, 0);
                } else {
                    const idx = funcIdxOf(rt.func_entities, ref) orelse return error.MultiMemoryUnsupported;
                    try w.u8v(gpa, 1);
                    try w.u32v(gpa, idx);
                }
            }
        } else if (isExternref(tab.elem_type)) {
            try w.u8v(gpa, 0);
            try writeLen(gpa, w, tab.refs.len);
            for (tab.refs) |cell| {
                if (cell.ref == _value.Value.null_ref) {
                    try w.u8v(gpa, 0);
                } else {
                    try w.u8v(gpa, 1);
                    try w.u64v(gpa, cell.ref);
                }
            }
        } else {
            return error.UnsupportedTableType;
        }
    }
}

fn writeTablesJit(gpa: Allocator, w: *Writer, jit: *_runner.JitInstance) (CheckpointError || Allocator.Error)!void {
    const n = jit.owned.rt.tables_count;
    try w.u32v(gpa, n);
    for (0..n) |t| {
        const ts = jit.owned.rt.tables_ptr[t];
        const elem_type = jitTableElemType(gpa, jit, @intCast(t)) orelse return error.UnsupportedTableType;
        if (isFuncref(elem_type)) {
            try w.u8v(gpa, 1);
            try writeLen(gpa, w, @intCast(ts.len));
            for (0..@intCast(ts.len)) |i| {
                const ref = ts.refs[i];
                if (ref == _value.Value.null_ref) {
                    try w.u8v(gpa, 0);
                } else {
                    const idx = funcIdxOf(jit.owned.func_entities, ref) orelse return error.MultiMemoryUnsupported;
                    try w.u8v(gpa, 1);
                    try w.u32v(gpa, idx);
                }
            }
        } else if (isExternref(elem_type)) {
            try w.u8v(gpa, 0);
            try writeLen(gpa, w, @intCast(ts.len));
            for (0..@intCast(ts.len)) |i| {
                if (ts.refs[i] == _value.Value.null_ref) {
                    try w.u8v(gpa, 0);
                } else {
                    try w.u8v(gpa, 1);
                    try w.u64v(gpa, ts.refs[i]);
                }
            }
        } else {
            return error.UnsupportedTableType;
        }
    }
}

/// Element type of a JIT table from the module's table section (full space is
/// defined-only: table imports are refused). Null when the section is missing
/// or a non-funcref/externref type appears (the caller refuses those).
fn jitTableElemType(gpa: Allocator, jit: *_runner.JitInstance, table_idx: u32) ?_zir.ValType {
    const body = findSection(jit.wasm_bytes, 4) orelse return null;
    var tables = _sections.decodeTables(gpa, body) catch return null;
    defer tables.deinit();
    if (table_idx >= tables.items.len) return null;
    const vt = tables.items[table_idx].elem_type;
    if (isFuncref(vt) or isExternref(vt)) return vt;
    return null;
}

fn writeLen(gpa: Allocator, w: *Writer, len: usize) Allocator.Error!void {
    if (len > std.math.maxInt(u64)) return error.OutOfMemory;
    try w.u64v(gpa, @intCast(len));
}

/// funcref pointer to function-space index via the instance's own entity
/// array (interp `Runtime.func_entities`, JIT `RuntimeOwned.func_entities`).
fn funcIdxOf(entities: []_func.FuncEntity, ref: u64) ?u32 {
    if (entities.len == 0) return null;
    const base: usize = @intFromPtr(entities.ptr);
    const want: usize = @intCast(ref);
    if (want < base) return null;
    const off = want - base;
    const stride = @sizeOf(_func.FuncEntity);
    if (off % stride != 0) return null;
    const idx = off / stride;
    if (idx >= entities.len) return null;
    if (@intFromPtr(&entities[idx]) != want) return null;
    if (idx > std.math.maxInt(u32)) return null;
    return @intCast(idx);
}

fn writeDropped(gpa: Allocator, w: *Writer, data: []const bool, elem: []const bool) Allocator.Error!void {
    try w.u32v(gpa, @intCast(@min(data.len, std.math.maxInt(u32))));
    for (data) |d| try w.u8v(gpa, if (d) 1 else 0);
    try w.u32v(gpa, @intCast(@min(elem.len, std.math.maxInt(u32))));
    for (elem) |d| try w.u8v(gpa, if (d) 1 else 0);
}

fn writeDroppedJit(gpa: Allocator, w: *Writer, jit: *_runner.JitInstance) Allocator.Error!void {
    try w.u32v(gpa, @intCast(@min(jit.owned.data_dropped.len, std.math.maxInt(u32))));
    for (jit.owned.data_dropped) |d| try w.u8v(gpa, d);
    try w.u32v(gpa, @intCast(@min(jit.owned.elem_dropped.len, std.math.maxInt(u32))));
    for (jit.owned.elem_dropped) |d| try w.u8v(gpa, d);
}

fn readMemory(r: *Reader, inst: *_instance.Instance, current_len: usize) RestoreError!void {
    const pages = try r.ru32();
    const want_len: usize = @as(usize, pages) * page_bytes;
    if (current_len % page_bytes != 0) return error.StateMismatch;
    if (want_len < current_len) return error.StateMismatch;
    const image = try r.take(want_len);
    if (want_len == 0) {
        if (current_len != 0) return error.StateMismatch;
        return;
    }
    if (want_len > current_len) {
        const delta_pages = (want_len - current_len) / page_bytes;
        if (delta_pages > std.math.maxInt(u32)) return error.UnsupportedTableSize;
        const mem_g = inst.memory() orelse return error.StateMismatch;
        if (mem_g.grow(@intCast(delta_pages)) == null) return error.GrowFailed;
    }
    const mem = inst.memory() orelse return error.StateMismatch;
    const live = mem.slice();
    if (live.len < want_len) return error.StateMismatch;
    @memcpy(live[0..want_len], image);
}

fn readGlobals(r: *Reader, rt: *_runtime.Runtime) RestoreError!void {
    const n = try r.ru32();
    if (n != rt.globals.len) return error.StateMismatch;
    for (rt.globals) |slot| {
        const image = try r.take(16);
        @memcpy(std.mem.asBytes(slot), image);
    }
}

fn readGlobalsJit(r: *Reader, jit: *_runner.JitInstance) RestoreError!void {
    const n = try r.ru32();
    if (n != jit.owned.rt.globals_count) return error.StateMismatch;
    for (0..n) |i| {
        const image = try r.take(16);
        @memcpy(std.mem.asBytes(&jit.owned.rt.globals_base[i]), image);
    }
}

fn readTablesInterp(r: *Reader, rt: *_runtime.Runtime) RestoreError!void {
    const n = try r.ru32();
    if (n != rt.tables.len) return error.StateMismatch;
    for (rt.tables) |*tab| {
        const is_funcref = try r.ru8();
        const len = try r.ru64();
        if (len > std.math.maxInt(u32)) return error.UnsupportedTableSize;
        if (len < tab.refs.len) return error.StateMismatch;
        if (len > tab.refs.len) {
            if (tab.max) |m| {
                if (len > m) return error.GrowFailed;
            }
            if (rt.store_table_elements_max) |cap| {
                if (len > cap) return error.GrowFailed;
            }
            const grown = rt.alloc.realloc(tab.refs, @intCast(len)) catch return error.GrowFailed;
            for (grown[tab.refs.len..]) |*slot| slot.* = _value.Value.zero;
            tab.refs = grown;
        }
        const want_funcref = isFuncref(tab.elem_type);
        if ((is_funcref == 1) != want_funcref) return error.StateMismatch;
        for (tab.refs) |*slot| {
            const tag = try r.ru8();
            if (is_funcref == 1) {
                if (tag == 0) {
                    slot.* = _value.Value.zero;
                } else if (tag == 1) {
                    const idx = try r.ru32();
                    if (idx >= rt.func_entities.len) return error.StateMismatch;
                    slot.* = .{ .ref = @intFromPtr(&rt.func_entities[idx]) };
                } else {
                    return error.BadCheckpoint;
                }
            } else {
                if (tag == 0) {
                    slot.* = _value.Value.zero;
                } else if (tag == 1) {
                    slot.* = .{ .ref = try r.ru64() };
                } else {
                    return error.BadCheckpoint;
                }
            }
        }
    }
}

fn readTablesJit(r: *Reader, jit: *_runner.JitInstance) RestoreError!void {
    const n = try r.ru32();
    if (n != jit.owned.rt.tables_count) return error.StateMismatch;
    for (0..n) |t| {
        const is_funcref = try r.ru8();
        const len = try r.ru64();
        if (len > std.math.maxInt(u32)) return error.UnsupportedTableSize;
        const descs: [*]_entry.TableSlice = @constCast(jit.owned.rt.tables_ptr);
        const ts = &descs[t];
        if (len < ts.len) return error.StateMismatch;
        if (len > ts.len) {
            const grown = jit.growTable(@intCast(t), _value.Value.null_ref, @intCast(len - ts.len)) orelse return error.GrowFailed;
            _ = grown;
        }
        var fb: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fb);
        const elem_type = jitTableElemType(fba.allocator(), jit, @intCast(t)) orelse return error.StateMismatch;
        const want_funcref = isFuncref(elem_type);
        if ((is_funcref == 1) != want_funcref) return error.StateMismatch;
        const has_mirror = @intFromPtr(ts.funcptrs) != 0;
        if (want_funcref != has_mirror) return error.StateMismatch;
        var typeidx_base: ?[*]u32 = null;
        if (want_funcref) {
            if (t >= jit.owned.rt.tables_jit_ci_count) return error.TableMirrorUnavailable;
            const ci = jit.owned.rt.tables_jit_ci_ptr[t];
            if (@intFromPtr(ci.typeidx_base) == 0) return error.TableMirrorUnavailable;
            typeidx_base = @constCast(ci.typeidx_base);
        }
        for (0..@intCast(ts.len)) |i| {
            const tag = try r.ru8();
            if (want_funcref) {
                if (tag == 0) {
                    ts.refs[i] = _value.Value.null_ref;
                    ts.funcptrs[i] = 0;
                    typeidx_base.?[i] = std.math.maxInt(u32);
                } else if (tag == 1) {
                    const idx = try r.ru32();
                    if (idx >= jit.owned.func_entities.len) return error.StateMismatch;
                    const fe = &jit.owned.func_entities[idx];
                    ts.refs[i] = @intFromPtr(fe);
                    ts.funcptrs[i] = @intCast(fe.funcptr);
                    typeidx_base.?[i] = fe.typeidx;
                } else {
                    return error.BadCheckpoint;
                }
            } else {
                if (tag == 0) {
                    ts.refs[i] = _value.Value.null_ref;
                } else if (tag == 1) {
                    ts.refs[i] = try r.ru64();
                } else {
                    return error.BadCheckpoint;
                }
            }
        }
    }
}

fn readDropped(r: *Reader, rt: *_runtime.Runtime) RestoreError!void {
    const nd = try r.ru32();
    if (nd != rt.data_dropped.len) return error.StateMismatch;
    for (rt.data_dropped) |*d| {
        const v = try r.ru8();
        if (v > 1) return error.BadCheckpoint;
        d.* = v == 1;
    }
    const ne = try r.ru32();
    if (ne != rt.elem_dropped.len) return error.StateMismatch;
    for (rt.elem_dropped) |*d| {
        const v = try r.ru8();
        if (v > 1) return error.BadCheckpoint;
        d.* = v == 1;
    }
}

fn readDroppedJit(r: *Reader, jit: *_runner.JitInstance) RestoreError!void {
    const nd = try r.ru32();
    if (nd != jit.owned.data_dropped.len) return error.StateMismatch;
    for (jit.owned.data_dropped) |*d| {
        const v = try r.ru8();
        if (v > 1) return error.BadCheckpoint;
        d.* = v;
    }
    const ne = try r.ru32();
    if (ne != jit.owned.elem_dropped.len) return error.StateMismatch;
    for (jit.owned.elem_dropped) |*d| {
        const v = try r.ru8();
        if (v > 1) return error.BadCheckpoint;
        d.* = v;
    }
}

// ============================================================
// Z4 tests: restore(checkpoint(A)) + exec == exec on A.
// ============================================================

const _zwasm_test = @import("../zwasm.zig");
const _engine_test = @import("engine.zig");
const _module_test = @import("module.zig");

/// Guest A: 1-page memory + one mutable i32 global. `run` bumps the global,
/// stores it at mem[0], and returns it.
const guest_a = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, // type () -> i32
    0x03, 0x02, 0x01, 0x00, // func type 0
    0x05, 0x03, 0x01, 0x00, 0x01, // memory min 1
    0x06, 0x06, 0x01, 0x7f, 0x01, 0x41, 0x00, 0x0b, // global mut i32 = 0
    0x07, 0x07, 0x01, 0x03, 'r',  'u',  'n',  0x00, 0x00, // export "run"
    0x0a, 0x14, 0x01, 0x12, 0x00, 0x23, 0x00, 0x41, 0x01,
    0x6a, 0x24, 0x00, 0x41, 0x00, 0x23, 0x00, 0x36, 0x02,
    0x00, 0x23, 0x00, 0x0b,
};

fn runGuestA(inst: *_instance.Instance) !i32 {
    var results = [_]_zwasm_test.Value{.{ .i32 = 0 }};
    try inst.invoke("run", &.{}, &results);
    return results[0].i32;
}

fn checkpointRoundTrip(engine_tag: _module_test.Module.InstantiateOpts) !void {
    var eng = try _engine_test.Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&guest_a);
    defer mod.deinit();
    var a = try mod.instantiate(engine_tag);
    defer a.deinit();
    try std.testing.expectEqual(@as(i32, 1), try runGuestA(&a));
    try std.testing.expectEqual(@as(i32, 2), try runGuestA(&a));

    const bytes = try checkpoint(std.testing.allocator, &a, &guest_a);
    defer std.testing.allocator.free(bytes);

    var b = try mod.instantiate(engine_tag);
    defer b.deinit();
    try restoreInto(&b, &guest_a, bytes);
    // Execution continues where A left off: global, memory, and results agree.
    try std.testing.expectEqual(@as(i32, 3), try runGuestA(&b));
    const mem = b.memory().?;
    const cell = try mem.sliceAt(0, 4);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, cell[0..4], .little));
}

test "Z4: memory+global checkpoint/restore continues execution (interp)" {
    try checkpointRoundTrip(.{ .engine = .interp });
}

test "Z4: memory+global checkpoint/restore continues execution (jit)" {
    try checkpointRoundTrip(.{ .engine = .jit });
}

/// Guest B: funcref table [f0, f1] + `call(i)` through call_indirect.
/// All three funcs share the single type (i32) -> i32; `call` passes const 7
/// as the callee arg and its param as the table index.
const guest_b = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x06, 0x01, 0x60,
    0x01, 0x7f, 0x01, 0x7f, 0x03, 0x04, 0x03, 0x00, 0x00, 0x00, 0x04, 0x05,
    0x01, 0x70, 0x01, 0x02, 0x02, 0x05, 0x03, 0x01, 0x00, 0x01, 0x07, 0x08,
    0x01, 0x04, 0x63, 0x61, 0x6c, 0x6c, 0x00, 0x02, 0x09, 0x08, 0x01, 0x00,
    0x41, 0x00, 0x0b, 0x02, 0x00, 0x01, 0x0a, 0x1b, 0x03, 0x07, 0x00, 0x20,
    0x00, 0x1a, 0x41, 0x0a, 0x0b, 0x07, 0x00, 0x20, 0x00, 0x1a, 0x41, 0x14,
    0x0b, 0x09, 0x00, 0x41, 0x07, 0x20, 0x00, 0x11, 0x00, 0x00, 0x0b,
};

fn callGuestB(inst: *_instance.Instance, idx: i32) !i32 {
    var results = [_]_zwasm_test.Value{.{ .i32 = 0 }};
    try inst.invoke("call", &[_]_zwasm_test.Value{.{ .i32 = idx }}, &results);
    return results[0].i32;
}

fn tableRoundTrip(engine_tag: _module_test.Module.InstantiateOpts) !void {
    var eng = try _engine_test.Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&guest_b);
    defer mod.deinit();
    var a = try mod.instantiate(engine_tag);
    defer a.deinit();
    try std.testing.expectEqual(@as(i32, 10), try callGuestB(&a, 0));
    try std.testing.expectEqual(@as(i32, 20), try callGuestB(&a, 1));

    const bytes = try checkpoint(std.testing.allocator, &a, &guest_b);
    defer std.testing.allocator.free(bytes);

    var b = try mod.instantiate(engine_tag);
    defer b.deinit();
    try restoreInto(&b, &guest_b, bytes);
    // Indirect calls resolve through the restored table (incl. the JIT
    // funcptr/typeidx mirrors): same targets, same sig checks.
    try std.testing.expectEqual(@as(i32, 10), try callGuestB(&b, 0));
    try std.testing.expectEqual(@as(i32, 20), try callGuestB(&b, 1));
}

test "Z4: funcref table checkpoint/restore keeps call_indirect targets (interp)" {
    try tableRoundTrip(.{ .engine = .interp });
}

test "Z4: funcref table checkpoint/restore keeps call_indirect targets (jit)" {
    try tableRoundTrip(.{ .engine = .jit });
}

/// Guest C: exported externref table + a dummy func.
const guest_c = [_]u8{
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x03,
    0x02, 0x01, 0x00,
    0x04, 0x05, 0x01, 0x6f, 0x01, 0x02, 0x02, // table externref min 2 max 2
    0x07, 0x09, 0x02, 0x01, 't',  0x01, 0x00,
    0x01, 'f',  0x00, 0x00, 0x0a, 0x06, 0x01,
    0x04, 0x00, 0x41, 0x00, 0x0b,
};

fn externRoundTrip(engine_tag: _module_test.Module.InstantiateOpts) !void {
    var eng = try _engine_test.Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod = try eng.compile(&guest_c);
    defer mod.deinit();
    var a = try mod.instantiate(engine_tag);
    defer a.deinit();
    var ta = a.table("t").?;
    try ta.set(1, .{ .externref = 0x1234 });
    const bytes = try checkpoint(std.testing.allocator, &a, &guest_c);
    defer std.testing.allocator.free(bytes);

    var b = try mod.instantiate(engine_tag);
    defer b.deinit();
    try restoreInto(&b, &guest_c, bytes);
    var tb = b.table("t").?;
    try std.testing.expectEqual(@as(?u64, null), (try tb.get(0)).externref);
    try std.testing.expectEqual(@as(?u64, 0x1234), (try tb.get(1)).externref);
}

test "Z4: externref cells round-trip as opaque handles (interp)" {
    try externRoundTrip(.{ .engine = .interp });
}

test "Z4: externref cells round-trip as opaque handles (jit)" {
    try externRoundTrip(.{ .engine = .jit });
}

test "Z4: import scan passes func-only and refuses global imports" {
    const func_import = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x02,
        0x07, 0x01, 0x01, 'h',  0x01, 'f',  0x00, 0x00,
    };
    try scanImports(std.testing.allocator, &func_import);
    const global_import = [_]u8{
        0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7f, 0x02,
        0x08, 0x01, 0x01, 'h',  0x01, 'f',  0x03, 0x7f,
        0x00,
    };
    try std.testing.expectError(error.ImportedEntitiesUnsupported, scanImports(std.testing.allocator, &global_import));
}

test "Z4: restore refuses engine, module, truncation, and trailing bytes" {
    var eng = try _engine_test.Engine.init(std.testing.allocator, .{});
    defer eng.deinit();
    var mod_a = try eng.compile(&guest_a);
    defer mod_a.deinit();
    var a = try mod_a.instantiate(.{ .engine = .interp });
    defer a.deinit();
    const bytes = try checkpoint(std.testing.allocator, &a, &guest_a);
    defer std.testing.allocator.free(bytes);

    // Wrong engine.
    var j = try mod_a.instantiate(.{ .engine = .jit });
    defer j.deinit();
    try std.testing.expectError(error.EngineMismatch, restoreInto(&j, &guest_a, bytes));
    // Wrong module.
    var mod_c = try eng.compile(&guest_c);
    defer mod_c.deinit();
    var c = try mod_c.instantiate(.{ .engine = .interp });
    defer c.deinit();
    try std.testing.expectError(error.ModuleMismatch, restoreInto(&c, &guest_c, bytes));
    try std.testing.expectError(error.ModuleMismatch, restoreInto(&a, &guest_c, bytes));
    // Truncated image.
    var b = try mod_a.instantiate(.{ .engine = .interp });
    defer b.deinit();
    try std.testing.expectError(error.BadCheckpoint, restoreInto(&b, &guest_a, bytes[0 .. bytes.len - 5]));
    // Trailing bytes.
    var long = try std.testing.allocator.alloc(u8, bytes.len + 2);
    defer std.testing.allocator.free(long);
    @memcpy(long[0..bytes.len], bytes);
    long[bytes.len] = 0x7a;
    long[bytes.len + 1] = 0x7a;
    try std.testing.expectError(error.BadCheckpoint, restoreInto(&b, &guest_a, long));
}
