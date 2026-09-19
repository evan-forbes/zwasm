# SERCI-CHANGES.md — serci fork of zwasm

Upstream: https://github.com/zwasm/zwasm (pinned release v2.7.0, `d09d924`).
Fork: https://github.com/evan-forbes/zwasm.
Governance (serci design S42): every fork change is a commit with a test here,
an entry in this file, and an upstream PR where it is not serci-specific.
Upstream-first is the default; the fork exists so review latency is not on the
critical path. Fork commits follow serci S60 (`fork(...)` type, PR link in the
body). The invariant is wasm-compatibility: RT0 (core spec `testsuite` on both
engines) and RT1 (wasmtime-vs-fork differential) stay green.

## Z5 — compiled-module artifacts on the native facade: produce + load gate

- Status: landed on `fork/z5-artifact-cache`; upstream PR:
  https://github.com/zwasm/zwasm/pull/473.
- What: the fork could produce `.cwasm` only through the CLI (`compile`/`run --cache`);
  embedders had no serialize API and no cheap validity gate (serci S42 Z5). New
  `src/zwasm/artifact.zig`: `Artifact.produce(gpa, eng, wasm_bytes)` validates through
  `Engine.compile`, runs the JIT pipeline (`compileWasmForAot`), and returns owned
  `.cwasm` bytes; `Artifact.isValid` is the cheap load gate (magic / format version /
  this host's arch / every section inside the entry).
- Scope: produce-only on this surface. Consuming an artifact through
  `Engine.compile`/`Linker.instantiate` needs `Module` to carry deserialized codegen
  past the C ABI — upstream-scale surgery tracked as the follow-up; the runner
  (`runWasiLenientArgs`) already consumes artifacts, and the tests prove an artifact
  runs identically to a fresh compile through it.
- Tests: produce → valid → same `run` answer (42) via the CWAS path as via fresh
  compile; invalid input never reaches codegen (`ParseFailed`); gate refuses garbage,
  truncation, version drift, and arch drift. Full suite: 3373 passed, 12 skipped.
- Compatibility: pure addition (one re-export + one test-loader line). RT0/RT1 unaffected.

## Z4 — instance checkpoint/restore: linear pages + globals + tables to bytes and back

- Status: landed on `fork/z4-checkpoint-restore`; upstream PR:
  https://github.com/zwasm/zwasm/pull/472.
- What: the fork had no snapshot API (only live `Memory` views), so a kernel's
  namespace could not survive a process restart or a child fork without language
  support (serci S42 Z4). New `src/zwasm/checkpoint.zig`: `checkpoint(gpa,
  inst, wasm_bytes)` serialises linear-memory pages, globals (raw 16-byte
  cells, valtype-agnostic), tables (funcref as function-space indices resolved
  through the instance's own entity array, externref as raw u64 handles),
  data/elem dropped flags, and remaining fuel into versioned bytes
  (`ZCHKPT01`, blake3 module identity); `restoreInto(inst, wasm_bytes, bytes)`
  grows a fresh same-module/same-engine instance up to the recorded sizes and
  overwrites every cell, including the JIT funcptr/typeidx mirrors.
- Scope refusals (loud, never silent divergence): imported memories/globals/
  tables (alias another instance), multi-memory modules, non-funcref/externref
  table types. Externref restores are same-process only (documented).
- Tests: 11 rows in `src/zwasm/checkpoint.zig` — memory+global continuation,
  funcref `call_indirect` targets (incl. JIT mirrors), externref round-trip,
  import scan, and engine/module/truncation/trailing refusals — on `.interp`
  and `.jit`. Full suite: 121/121.
- Compatibility: pure addition (one `pub` on `Instance.jitHandle`, one
  re-export, one test-loader line). RT0/RT1 unaffected.

## Z2 — `proc_exit` from a command guest returns `error.ProcExit`, not a panic

- Status: landed on `fork/z2-proc-exit-trap`; upstream PR:
  https://github.com/zwasm/zwasm/pull/467.
- What: the native facade's interp `invoke` mapped `dispatch.run` errors back
  to `InvokeError` with `else => @panic`. A WASI `proc_exit` unwinds the loop
  with the thunk's `error.WasiExit` (`src/api/wasi.zig::thunkProcExit`), which
  is not in `runtime.Trap`, so any command guest (`_start` calling
  `proc_exit`) aborted the embedder at `src/zwasm/instance.zig:673`
  ("dispatch returned non-Trap error variant"). The JIT arm already returned
  `error.ProcExit` via `jitTrapToError(.wasi_exit)`.
- Change: `mapDispatchErr` maps `error.WasiExit => error.ProcExit`; the exit
  code stays readable out-of-band on the Linker's WASI host via the new
  `Linker.wasiExitCode() ?u32` / `Linker.clearWasiExitCode()` (native-facade
  counterpart of the C surface's `activeWasiHost`; Zig errors carry no
  payload). `emitInvokeTrap` already reports `ProcExit` as `.wasi_exit`.
- Test: `Linker proc_exit(3)` row in `src/zwasm/linker.zig`: `invoke`
  returns `error.ProcExit`, `wasiExitCode()` is `3`, and a second instance
  through the same linker exits the same way (B2: host intact). JIT-arm
  coverage stays with the `runWasm: proc_exit_42` rows in `src/cli/run.zig`.
- Compatibility: pure addition of a mapped error arm; every previous panic
  input now returns `error.ProcExit`. RT0/RT1 unaffected (no semantic change
  to any passing module).

## Z1a — JIT host-import bridge covers all-GP arities 5..6 (serci Z1, first increment)

- Status: landed on `fork/z1-jit-host-arity`; upstream PR:
  https://github.com/zwasm/zwasm/pull/468.
- What: the JIT host-func bridge (`src/api/jit_host_bridge.zig`) covered only
  all-GP arities 0..4 (plus ≤2 args with FP), so any module importing a host
  function with 5+ integer params — including serci's S16.3 `host_request`
  (5×i32→i32) — declined the JIT and silently fell back to `.interp`
  (F14: 200k-iteration cell ~35× slower than the JIT on x86_64).
- Change: `t5`/`t6` thunk generators plus `MAX_ARITY` 4→6; the call-site
  codegen already marshals overflow args (x86_64 SysV carries 5 user GPRs;
  arm64 carries 7), so 5..6 stay all-register on SysV/arm64 and `callconv(.c)`
  stays correct where Win64 spills to the stack. `dispatchPtrFor` still
  returns null past 6, for FP past arity 2, and for v128/ref (→ `.interp`).
- Tests: bridge unit row (5..6 resolve, 7 and out-of-range slots decline,
  distinct slots distinct thunks) and a C-API end-to-end row (5-arg host
  import instantiates `.jit` with `i.jit != null` and computes 1+2+3+4+5=15;
  pre-fix it fails with `JitDeclined`). Full suite: 3353 passed, 12 skipped.
- Follow-ups (Z1b, not this change): native `Linker.instantiate` is
  interp-pinned (engine selection there is upstream's noted follow-up slice),
  so the serci `defineFuncCtx` path still lands on `.interp` until Z1b routes
  it through `instantiateJit`; arities past 6 and FP past 2 still decline.
- Compatibility: strictly widens JIT acceptance; every module that compiled
  before compiles identically, and declines remain declines.

## Z1b — `Linker.instantiate` honors `opts.engine` (serci Z1, second increment)

- Status: on `fork/z1b-linker-engine`; upstream PR: https://github.com/zwasm/zwasm/pull/469.
- What: the native `Linker.instantiate` hardcoded `.interp` when calling
  `instantiateInternal`, ignoring `opts.engine` (the interp pin). Explicit
  `.jit` / `.interp` are now honored; `.auto` keeps the interp default.
- Scope deliberately narrow (ADR-0200 / D-496): `.auto` does NOT try the JIT
  on the Linker path yet. Two Linker shapes would not decline but silently
  run wrong under a JIT attempt — a WASI-importing module (the JIT plants
  WASI dispatch from the STORE host, null → stub syscalls per D-451, while
  the Linker owns its host) and the in-tree callers that unwrap
  `instance.handle.runtime` (interp-only, e.g. the 10.G-foundation
  `gc_heap` row, which crashed on the first unpin attempt). So `.auto`
  forces WASI-importing modules (`wasi_snapshot_preview1` + `wasi_unstable`,
  mirroring `jit_dispatch.lookup`) to interp, and explicit `.jit` on such a
  module refuses LOUDLY (`error.InstantiateFailed`) instead of stub-running.
  Routing Linker host funcs (native marshal thunks, not JIT-bridge payloads)
  and the Linker-owned WASI host into the JIT needs a JIT-backed `Caller` +
  the store-plant slice — the next Z1 increment, not this one.
- Tests: four `Linker engine select` rows in `src/zwasm/linker.zig` —
  `.auto` stays interp, explicit `.jit` on an import-free module reports
  `jit` and computes, explicit `.interp` pins, and a `defineFunc` host
  import declines to interp under `.auto` (computes) while `.jit` requires
  the JIT and fails loud. Full suite: 3357 passed, 12 skipped (`zig build test`); `test-all` green.
- Compatibility: default (`.auto`) behavior is byte-identical to pre-Z1b;
  only an explicit `.jit` can observe the new path.

## Z1c — Linker host funcs run on the JIT with a JIT-backed `Caller` (serci Z1, third increment)

- Status: on `fork/z1c-linker-host-jit`; upstream PR: (to be opened as the
  next increment on #468 / #469).
- What: Z1b routed explicit-`.jit` Linker instantiations to the JIT but left
  `defineFunc` host imports refusing loudly — the native marshal thunks were
  not JIT-bridge payloads, and a JIT-backed `Caller` did not exist. Now an
  explicit-`.jit` `Linker.instantiate` plants `{ hostFuncThunk,
  jit_payload }` for each host-func import (`.auto` / `.interp` keep the
  marshal-thunk bindings, byte-identical), and the native-facade JIT path
  serves them through the existing `dispatchPtrFor` bridge like C host funcs.
- How: each `defineFunc` / `defineFuncCtx` / `defineFuncRaw` entry owns a
  `HostFuncPayload` with a `callback_jit` adapter (per-`Sig` generated, or the
  shared runtime-arity one) and the entry ctx as `env`. The bridge prefers
  `callback_jit` over the ValVec-only C callbacks; the adapter builds a
  JIT-backed `Caller` from the calling instance's live `*JitRuntime`
  (`Caller.Backing.jit`, `Memory.Backing.jit_rt` — memory re-read per access,
  `grow` via the block's own grow callout, allocator stashed at `defineFunc`
  time) and marshals `Val` args / results per the Zig signature. A Zig
  `error` raises the host-originated trap directly (`trap_flag = 1`,
  `trap_kind = 19`, the bridge `trapResult` code) since there is no trap
  object to return. Coverage is the bridge's standing rule — all-GP 0..6 or
  <=2 scalars with FP, single scalar/void result: 7+ args, FP past 2,
  v128 / ref, and multi-result still decline (`.auto` → interp; explicit
  `.jit` refuses loudly), and WASI-importing modules still refuse loudly
  under `.jit` (the store-plant slice is not this change).
- Drive-by fix: `zigToRuntime`'s `f32` / `f64` arms mistook a widening `@as`
  for a `@bitCast` (latent — no in-tree float-returning host fn ever
  instantiated them; the new FP row is the first). Both arms corrected.
- Tests: six `Linker host func on JIT` rows in `src/zwasm/linker.zig` (id on
  `.jit` computes + reports `jit`; `Caller` live-memory read/write;
  `defineFuncRaw`; FP-arg shape; 7-arg decline/refuse; Zig error →
  `error.HostTrap`) plus a bridge decline row (FP past 2, v128 / ref,
  multi-result). Full suite: `zig build test` green; `test-all` green
  (diff_runner 57/57 vs wasmtime on both engines; fuzz_exec 0 mismatched).
- Compatibility: `.auto` / `.interp` paths untouched; only explicit `.jit`
  with a host-func import observes the new path (previously a loud
  `InstantiateFailed`, now a computing JIT instance).
