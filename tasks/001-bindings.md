# 001: Bindings over the SQLite amalgamation

Status: in-progress (2026-10-19)

The first API: connections, prepared statements, and transactions, over the latest
SQLite release's amalgamation, built by `goose build` from the package's `.build`
sidecar. goose-rest's data-access examples (its task 035) are its first user.

## Steps

1. Settle the proposed decision: vendor the amalgamation, its version, and its
   compile-time options (`SQLITE_THREADSAFE`, `SQLITE_DQS=0`, `SQLITE_OMIT_DEPRECATED`,
   and the others SQLite recommends). Measure how long `goose build` takes with it on
   each platform.
2. The shim: open and close, prepare, bind (integer, real, text, blob, null), step,
   column reads by type, reset, finalize, and the error code and message.
3. The Goose API over it: text and blobs as `u8[:]` in and appended to a caller's
   `u8[>..]` out, errors through `return ... from`, and a transaction helper that rolls
   back on error.
4. Tests under `test/`: a schema created and queried, each bound type read back, a
   failed transaction rolled back, and two read-only WAL connections on other threads
   reading while one writes. `scripts/test.sh` runs them.
5. `docs/architecture.md`: the API, the thread rule, and the options.

## State

Steps 1 to 5 are done on macOS and Linux (2026-10-19). SQLite 3.54.1 is vendored, its
options and the reasons for them are in `docs/decisions.md`, and build times on macOS
(clang) and Linux arm64 (gcc, in Docker) are in `docs/results.md`. `scripts/test.sh`
passes on macOS arm64, on Linux arm64 in Docker, and on Linux x64 in Docker under
emulation.

What remains:

- Windows: no Windows machine was available, so neither the build time nor
  `scripts/test.sh` has run there, with MSVC or with `clang-cl`. The sidecar passes
  `/std:c11` to MSVC for the shim's `_Static_assert`; that is untested.
- goose-rest's program on a lane, in goose-rest.

## Acceptance criteria

- [ ] The amalgamation's version and options recorded in `docs/decisions.md` and
      `docs/development.md`, with build times per platform (all but Windows)
- [x] The API in `README.md` and `docs/architecture.md`
- [ ] `scripts/test.sh` passes on macOS, Linux, and Windows (all but Windows)
- [ ] A goose-rest program reads and writes through a lane (in goose-rest, its task 035)
