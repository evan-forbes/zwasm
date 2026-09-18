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
