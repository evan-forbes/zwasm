# SERCI-CHANGES.md — serci fork of zwasm

Upstream: https://github.com/zwasm/zwasm (pinned release v2.7.0, `d09d924`).
Fork: https://github.com/evan-forbes/zwasm.
Governance (serci design S42): every fork change is a commit with a test here,
an entry in this file, and an upstream PR where it is not serci-specific.
Upstream-first is the default; the fork exists so review latency is not on the
critical path. Fork commits follow serci S60 (`fork(...)` type, PR link in the
body). The invariant is wasm-compatibility: RT0 (core spec `testsuite` on both
engines) and RT1 (wasmtime-vs-fork differential) stay green.

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
