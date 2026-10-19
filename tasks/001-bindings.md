# 001: Bindings over the SQLite amalgamation

Status: todo (2026-10-19)

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

## Acceptance criteria

- [ ] The amalgamation's version and options recorded in `docs/decisions.md` and
      `docs/development.md`, with build times per platform
- [ ] The API in `README.md` and `docs/architecture.md`
- [ ] `scripts/test.sh` passes on macOS, Linux, and Windows
- [ ] A goose-rest program reads and writes through a lane (in goose-rest, its task 035)
