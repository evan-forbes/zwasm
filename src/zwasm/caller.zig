//! `Caller` — host-fn execution context per ADR-0109 §3.2.
//!
//! Passed as the first parameter of every host function registered
//! via `Linker.defineFunc`. Provides access to the *importing*
//! instance's runtime state (linear memory, allocator) so the host
//! fn can read / write through it without smuggling a back-pointer
//! out-of-band.
//!
//! serci Z1c — the backing is a union: `interp` wraps the interpreter
//! `*Runtime` as before; `jit` carries the calling JIT instance's live
//! `*JitRuntime` (its `vm_base` / `mem_limit` pair, re-read on every
//! access so a `memory.grow` inside the host call stays visible) plus
//! the allocator the `Linker` stashed at `defineFunc` time. A host fn
//! written against `memory()` / `allocator()` / `data()` runs
//! unchanged on either engine.

const std = @import("std");

const _runtime = @import("../runtime/runtime.zig");
const _jit_abi = @import("../engine/codegen/shared/jit_abi.zig");
const _memory = @import("memory.zig");

pub const Caller = struct {
    backing: Backing,
    /// Host context registered with the import via `Linker.defineFuncCtx`
    /// (wasmtime's `Caller::data`). Null for `defineFunc`-registered host fns
    /// that need no external state. Recover the typed pointer via `data`.
    host_data: ?*anyopaque = null,

    pub const Backing = union(enum) {
        interp: *_runtime.Runtime,
        jit: Jit,
    };

    /// JIT backing: the calling instance's live runtime block plus the
    /// allocator the Linker captured at `defineFunc` time (the JIT block
    /// carries no allocator; the engine allocator is the interp-`rt.alloc`
    /// counterpart). Both are stable for the host call's duration.
    pub const Jit = struct {
        jrt: *_jit_abi.JitRuntime,
        alloc: std.mem.Allocator,
    };

    pub fn memory(self: Caller) ?_memory.Memory {
        return switch (self.backing) {
            .interp => |rt| {
                if (rt.memory.len == 0) return null;
                // Interp arm (ADR-0200): wrap the runtime.
                return .{ .backing = .{ .interp = rt } };
            },
            .jit => |jb| {
                if (jb.jrt.mem_limit == 0) return null;
                return .{ .backing = .{ .jit_rt = jb.jrt } };
            },
        };
    }

    pub fn allocator(self: Caller) std.mem.Allocator {
        return switch (self.backing) {
            .interp => |rt| rt.alloc,
            .jit => |jb| jb.alloc,
        };
    }

    /// Recover the typed host context registered via `Linker.defineFuncCtx`.
    /// Asserts a ctx was registered (calling this from a `defineFunc` host fn,
    /// which registers none, is a programmer error).
    pub fn data(self: Caller, comptime T: type) *T {
        return @ptrCast(@alignCast(self.host_data.?));
    }
};
