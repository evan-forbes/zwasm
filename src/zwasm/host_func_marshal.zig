//! Comptime host-fn adapter generator per ADR-0109 §3.2 +
//! `docs/zig_api_design.md` §3.2.
//!
//! Given a Zig host-fn signature `fn(*Caller, P1, P2, ...) R`,
//! emit a `HostCall { fn_ptr, ctx }` whose `fn_ptr` is invoked
//! from the dispatch loop when the importing module's `call N`
//! reaches the import slot. The thunk pops Wasm args off the
//! interpreter's operand stack, builds the Zig args tuple
//! (including the `*Caller`), invokes the user fn, and pushes
//! results back on the stack — matching Wasm spec §4.4.6 host
//! call semantics.

const std = @import("std");

const _runtime = @import("../runtime/runtime.zig");
const _value = @import("../runtime/value.zig");
const _zir = @import("../ir/zir.zig");
const _caller = @import("caller.zig");
const _handles = @import("../api/handles.zig");
const _vec = @import("../api/vec.zig");
const _trap = @import("../api/trap_surface.zig");
const _jit_abi = @import("../engine/codegen/shared/jit_abi.zig");

pub const Caller = _caller.Caller;
const RuntimeValue = _value.Value;

pub const Error = error{
    /// The host-fn signature does not begin with `*Caller`.
    MissingCallerParam,
    /// The host-fn signature uses an unsupported Wasm type.
    UnsupportedHostFnType,
};

/// Holds the user's fn pointer typed against its concrete Sig so
/// the per-Sig thunk can `@call` it via this wrapper. Allocated by
/// `Linker.defineFunc`; lifetime tied to the Linker.
pub fn HostFnCtx(comptime Sig: type) type {
    return struct {
        user_fn: *const Sig,
        /// Opaque host context surfaced to the user fn via `Caller.data`
        /// (set by `Linker.defineFuncCtx`; null for `defineFunc`).
        host_data: ?*anyopaque = null,
        /// serci Z1c — allocator a JIT-backed `Caller` reports. The JIT
        /// block carries none, so the Linker stashes its engine allocator
        /// here at `defineFunc` time (the interp counterpart is `rt.alloc`).
        jit_alloc: std.mem.Allocator,
    };
}

/// Comptime-emitted thunk for a given host-fn signature. Returns
/// the function pointer compatible with `runtime.HostCall.fn_ptr`.
pub fn thunkFor(comptime Sig: type) *const fn (*_runtime.Runtime, *anyopaque) anyerror!void {
    const fn_info = @typeInfo(Sig).@"fn";
    if (fn_info.params.len == 0 or (fn_info.params[0].type orelse return undefined) != *Caller) {
        // Caught at comptime when defineFunc validates; this guard
        // keeps the generated thunk well-formed in any path.
        @compileError("host fn must take *Caller as its first parameter");
    }
    return struct {
        fn t(rt: *_runtime.Runtime, ctx: *anyopaque) anyerror!void {
            const wrapper: *HostFnCtx(Sig) = @ptrCast(@alignCast(ctx));

            // Pop Wasm-typed params in reverse — last pushed is on top.
            // params[0] is *Caller, supplied separately.
            const ArgsT = std.meta.ArgsTuple(Sig);
            var args: ArgsT = undefined;
            comptime var i: comptime_int = fn_info.params.len;
            inline while (i > 1) {
                i -= 1;
                const PT = fn_info.params[i].type.?;
                const v = rt.popOperand();
                args[i] = runtimeToZig(PT, v);
            }
            var caller: Caller = .{ .backing = .{ .interp = rt }, .host_data = wrapper.host_data };
            args[0] = &caller;

            const ret = @call(.auto, wrapper.user_fn, args);

            const Ret = fn_info.return_type.?;
            if (Ret == void) return;
            switch (@typeInfo(Ret)) {
                .error_union => |eu| {
                    const ok = ret catch |err| return err;
                    try pushResult(rt, eu.payload, ok);
                },
                else => try pushResult(rt, Ret, ret),
            }
        }
    }.t;
}

/// A RUNTIME-arity host fn: receives the popped operands as a `[]const Value`
/// and writes its results into `results`. Unlike the comptime `thunkFor` path
/// (one generated thunk per Zig arity), ONE `rawThunk` serves every arity — the
/// arity travels in `RawHostFnCtx`, not the Zig fn type. This collapses the
/// per-arity cross-component boundary trampolines (D-305).
pub const RawHostFn = *const fn (caller: *Caller, args: []const RuntimeValue, results: []RuntimeValue) anyerror!void;

/// Context for a `rawThunk`-dispatched host fn: the user fn, its opaque host
/// data, and the flattened core arity. Allocated by `Linker.defineFuncRaw`;
/// lifetime tied to the Linker (same contract as `HostFnCtx`).
pub const RawHostFnCtx = struct {
    user_fn: RawHostFn,
    host_data: ?*anyopaque = null,
    n_params: usize,
    n_results: usize,
    /// serci Z1c — declared result types for the JIT adapter's `Value` →
    /// `Val` step (a `Value` carries no active tag at runtime). Same
    /// lifetime contract as `params` / `results` at `defineFuncRaw`.
    result_types: []const _zir.ValType = &.{},
    /// serci Z1c — allocator a JIT-backed `Caller` reports (see `HostFnCtx`).
    jit_alloc: std.mem.Allocator,
};

/// Max flattened core words a `defineFuncRaw` host fn may take or return.
/// Cross-component boundary funcs flatten to a small number of i32 words; 32 is
/// well clear of any realistic flat-scalar arity. Asserted in `rawThunk`.
pub const raw_max_words = 32;

/// Runtime-arity thunk: pop `n_params` operands into a Value buffer (reverse —
/// last pushed is on top), invoke the user fn with the args + a results buffer,
/// push the results. The single thunk every `defineFuncRaw` host fn shares.
pub fn rawThunk(rt: *_runtime.Runtime, ctx: *anyopaque) anyerror!void {
    const wrapper: *RawHostFnCtx = @ptrCast(@alignCast(ctx));
    std.debug.assert(wrapper.n_params <= raw_max_words and wrapper.n_results <= raw_max_words);
    var args_buf: [raw_max_words]RuntimeValue = undefined;
    var results_buf: [raw_max_words]RuntimeValue = undefined;
    var i: usize = wrapper.n_params;
    while (i > 0) {
        i -= 1;
        args_buf[i] = rt.popOperand();
    }
    var caller: Caller = .{ .backing = .{ .interp = rt }, .host_data = wrapper.host_data };
    try wrapper.user_fn(&caller, args_buf[0..wrapper.n_params], results_buf[0..wrapper.n_results]);
    for (results_buf[0..wrapper.n_results]) |rv| try rt.pushOperand(rv);
}

fn pushResult(rt: *_runtime.Runtime, comptime Ret: type, ret: Ret) !void {
    if (Ret == void) return;
    switch (@typeInfo(Ret)) {
        .@"struct" => |s| {
            inline for (s.fields) |f| {
                try rt.pushOperand(zigToRuntime(f.type, @field(ret, f.name)));
            }
        },
        else => try rt.pushOperand(zigToRuntime(Ret, ret)),
    }
}

fn runtimeToZig(comptime T: type, v: RuntimeValue) T {
    return switch (T) {
        i32 => v.i32,
        u32 => v.u32,
        i64 => v.i64,
        u64 => v.u64,
        f32 => @bitCast(@as(u32, @truncate(v.bits64))),
        f64 => @bitCast(v.bits64),
        else => @compileError("host fn: unsupported param type " ++ @typeName(T)),
    };
}

fn zigToRuntime(comptime T: type, v: T) RuntimeValue {
    return switch (T) {
        i32 => .{ .i32 = v },
        u32 => .{ .u32 = v },
        i64 => .{ .i64 = v },
        u64 => .{ .u64 = v },
        f32 => .{ .bits128 = @as(u128, @as(u32, @bitCast(v))) },
        f64 => .{ .bits128 = @as(u128, @as(u64, @bitCast(v))) },
        else => @compileError("host fn: unsupported result type " ++ @typeName(T)),
    };
}

/// Comptime-derived Wasm signature for the user's Zig fn type.
/// Used by the Linker's runtime-side type-match check at
/// `instantiate` time.
pub fn signatureOf(comptime Sig: type) struct { params: []const _zir.ValType, results: []const _zir.ValType } {
    const fn_info = @typeInfo(Sig).@"fn";
    comptime var params_buf: [fn_info.params.len]_zir.ValType = undefined;
    comptime var n_params: usize = 0;
    inline for (fn_info.params, 0..) |p, idx| {
        if (idx == 0) continue; // Skip *Caller.
        const PT = p.type orelse @compileError("host fn: anytype params unsupported");
        params_buf[n_params] = zigTypeToValType(PT);
        n_params += 1;
    }
    const params_final: [n_params]_zir.ValType = params_buf[0..n_params].*;

    const Ret = fn_info.return_type orelse @compileError("host fn: must declare return type (use void)");
    const RetPayload = switch (@typeInfo(Ret)) {
        .error_union => |eu| eu.payload,
        else => Ret,
    };
    const results_final = comptime if (RetPayload == void) blk: {
        const empty: [0]_zir.ValType = .{};
        break :blk empty;
    } else switch (@typeInfo(RetPayload)) {
        .@"struct" => |s| blk: {
            var rs: [s.fields.len]_zir.ValType = undefined;
            for (s.fields, 0..) |f, idx| rs[idx] = zigTypeToValType(f.type);
            break :blk rs;
        },
        else => blk: {
            const r: [1]_zir.ValType = .{zigTypeToValType(RetPayload)};
            break :blk r;
        },
    };

    return .{
        .params = &params_final,
        .results = &results_final,
    };
}

fn zigTypeToValType(comptime T: type) _zir.ValType {
    return switch (T) {
        i32, u32 => .i32,
        i64, u64 => .i64,
        f32 => .f32,
        f64 => .f64,
        else => @compileError("host fn: type not representable in Wasm: " ++ @typeName(T)),
    };
}

/// serci Z1c — JIT-Caller adapter for a `defineFunc` / `defineFuncCtx` host
/// fn of Zig signature `Sig`.
///
/// A `HostFuncPayload.callback_jit` with the entry's `HostFnCtx(Sig)` as
/// `env`. The JIT bridge calls it INSTEAD of the ValVec-only C callbacks:
/// it builds a JIT-backed `Caller` from the calling instance's live
/// `*JitRuntime` (memory re-read per access, allocator stashed at
/// `defineFunc` time), unmarshals the bridge-marshalled `Val` args into the
/// Zig args tuple, invokes the user fn, and marshals the result back.
///
/// Reachability: only the bridge calls this, and the bridge only resolves a
/// thunk for signatures `dispatchPtrFor` covers (all-GP 0..6 or <=2 scalars
/// with FP; single {void,i32,i64,f32,f64} result). Anything else declines to
/// interp (or refuses loudly under explicit `.jit`) before this runs, so the
/// scalar-only converters below are total on reachable inputs.
///
/// A Zig `error` has no trap object to return: like the bridge's
/// `trapResult`, the adapter raises the host-originated trap directly
/// (`trap_flag = 1, trap_kind = 19`) and returns null; the JIT epilogue's
/// post-call check raises it as a guest trap and discards the sentinel.
pub fn jitAdapterFor(comptime Sig: type) _handles.WasmFuncCallbackJit {
    return &struct {
        fn f(env: ?*anyopaque, jrt: *_jit_abi.JitRuntime, args: ?*const _vec.ValVec, results: ?*const _vec.ValVec) callconv(.c) ?*_trap.Trap {
            const wrapper: *HostFnCtx(Sig) = @ptrCast(@alignCast(env.?));
            var caller: Caller = .{ .backing = .{ .jit = .{ .jrt = jrt, .alloc = wrapper.jit_alloc } }, .host_data = wrapper.host_data };

            const fn_info = @typeInfo(Sig).@"fn";
            const ArgsT = std.meta.ArgsTuple(Sig);
            var zargs: ArgsT = undefined;
            zargs[0] = &caller;
            const av = args.?;
            inline for (1..fn_info.params.len) |i| {
                const PT = fn_info.params[i].type.?;
                zargs[i] = apiValToZig(PT, av.data.?[i - 1]);
            }

            const Ret = fn_info.return_type.?;
            if (Ret == void) {
                _ = @call(.auto, wrapper.user_fn, zargs);
                return null;
            }
            switch (@typeInfo(Ret)) {
                .error_union => |eu| {
                    const ok = @call(.auto, wrapper.user_fn, zargs) catch {
                        jrt.trap_flag = 1;
                        jrt.trap_kind = 19;
                        return null;
                    };
                    if (eu.payload != void) writeApiResults(results.?, eu.payload, ok) catch {
                        jrt.trap_flag = 1;
                        jrt.trap_kind = 19;
                    };
                    return null;
                },
                else => {
                    const val = @call(.auto, wrapper.user_fn, zargs);
                    writeApiResults(results.?, Ret, val) catch {
                        jrt.trap_flag = 1;
                        jrt.trap_kind = 19;
                    };
                    return null;
                },
            }
        }
    }.f;
}

/// serci Z1c — runtime-arity twin of `jitAdapterFor` for `defineFuncRaw`
/// host fns: one shared adapter for every arity (the arity travels in
/// `RawHostFnCtx`, mirroring `rawThunk`). `Val` → `Value` is kind-driven;
/// `Value` → `Val` uses the declared `result_types` (a `Value` carries no
/// active tag at runtime). Same reachability + error protocol as above.
pub fn rawJitAdapter(env: ?*anyopaque, jrt: *_jit_abi.JitRuntime, args: ?*const _vec.ValVec, results: ?*const _vec.ValVec) callconv(.c) ?*_trap.Trap {
    const fail = struct {
        fn raise(j: *_jit_abi.JitRuntime) ?*_trap.Trap {
            j.trap_flag = 1;
            j.trap_kind = 19;
            return null;
        }
    }.raise;
    const wrapper: *RawHostFnCtx = @ptrCast(@alignCast(env.?));
    std.debug.assert(wrapper.n_params <= raw_max_words and wrapper.n_results <= raw_max_words);
    var caller: Caller = .{ .backing = .{ .jit = .{ .jrt = jrt, .alloc = wrapper.jit_alloc } }, .host_data = wrapper.host_data };
    const av = args.?;
    if (wrapper.n_params > 0 and av.data == null) return fail(jrt);
    var args_buf: [raw_max_words]RuntimeValue = undefined;
    for (0..wrapper.n_params) |i| args_buf[i] = apiValToRuntime(av.data.?[i]);
    var results_buf: [raw_max_words]RuntimeValue = undefined;
    wrapper.user_fn(&caller, args_buf[0..wrapper.n_params], results_buf[0..wrapper.n_results]) catch return fail(jrt);
    const rv = results.?;
    if (wrapper.n_results > 0 and rv.data == null) return fail(jrt);
    for (0..wrapper.n_results) |i| {
        const vt = if (i < wrapper.result_types.len) wrapper.result_types[i] else return fail(jrt);
        rv.data.?[i] = runtimeToApiVal(vt, results_buf[i]);
    }
    return null;
}

/// Marshal one bridge `Val` into the Zig param type (bridge twin of
/// `runtimeToZig`; `u32` / `u64` ride the i32 / i64 `Val` kinds).
fn apiValToZig(comptime T: type, v: _handles.Val) T {
    return switch (T) {
        i32 => v.of.i32,
        u32 => @bitCast(v.of.i32),
        i64 => v.of.i64,
        u64 => @bitCast(v.of.i64),
        f32 => v.of.f32,
        f64 => v.of.f64,
        else => @compileError("host fn (JIT): unsupported param type " ++ @typeName(T)),
    };
}

/// Marshal one Zig result into a bridge `Val` (bridge twin of `zigToRuntime`).
fn zigToApiVal(comptime T: type, v: T) _handles.Val {
    return switch (T) {
        i32 => .{ .kind = .i32, .of = .{ .i32 = v } },
        u32 => .{ .kind = .i32, .of = .{ .i32 = @bitCast(v) } },
        i64 => .{ .kind = .i64, .of = .{ .i64 = v } },
        u64 => .{ .kind = .i64, .of = .{ .i64 = @bitCast(v) } },
        f32 => .{ .kind = .f32, .of = .{ .f32 = v } },
        f64 => .{ .kind = .f64, .of = .{ .f64 = v } },
        else => @compileError("host fn (JIT): unsupported result type " ++ @typeName(T)),
    };
}

/// Write a Zig result (scalar, `void`, or single-struct mirror of
/// `pushResult`) into the bridge result vec. Errors only when the vec cannot
/// hold the declared shape (unreachable from the bridge; the caller raises).
fn writeApiResults(rv: *const _vec.ValVec, comptime T: type, v: T) error{ShapeMismatch}!void {
    if (T == void) return;
    const data = rv.data orelse return error.ShapeMismatch;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            if (rv.size < st.fields.len) return error.ShapeMismatch;
            inline for (st.fields, 0..) |fld, idx| {
                data[idx] = zigToApiVal(fld.type, @field(v, fld.name));
            }
        },
        else => {
            if (rv.size < 1) return error.ShapeMismatch;
            data[0] = zigToApiVal(T, v);
        },
    }
}

/// Marshal one bridge `Val` into an interpreter `Value` by `Val` kind
/// (ref kinds are unreachable: `dispatchPtrFor` declines them).
fn apiValToRuntime(v: _handles.Val) RuntimeValue {
    return switch (v.kind) {
        .i32 => .{ .i32 = v.of.i32 },
        .i64 => .{ .i64 = v.of.i64 },
        .f32 => .{ .f32 = v.of.f32 },
        .f64 => .{ .f64 = v.of.f64 },
        .anyref, .funcref => unreachable, // declined by dispatchPtrFor
    };
}

/// Marshal one interpreter `Value` into a bridge `Val` per the declared
/// result type (v128 / ref are unreachable: `dispatchPtrFor` declines them).
fn runtimeToApiVal(vt: _zir.ValType, v: RuntimeValue) _handles.Val {
    return switch (vt) {
        .i32 => .{ .kind = .i32, .of = .{ .i32 = v.i32 } },
        .i64 => .{ .kind = .i64, .of = .{ .i64 = v.i64 } },
        .f32 => .{ .kind = .f32, .of = .{ .f32 = v.f32 } },
        .f64 => .{ .kind = .f64, .of = .{ .f64 = v.f64 } },
        .v128, .ref => unreachable, // declined by dispatchPtrFor
    };
}
