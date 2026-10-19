# 002: Turso as a second engine behind the same API

Status: todo (2026-10-19)

Turso ([tursodatabase/turso](https://github.com/tursodatabase/turso)) is an in-process
rewrite of SQLite in Rust that reads and writes SQLite's file format. It isn't libSQL
or Turso's cloud service. It offers what SQLite lacks: concurrent writers through MVCC
(`BEGIN CONCURRENT`), asynchronous I/O on io_uring, and vector search. This task finds
out whether a Goose program can choose it in place of SQLite, through the API task 001
built, and what that gains. It follows task 001.

## Steps

1. Check the facts, from Turso's repository and docs at a named release, before
   building anything:
   - Whether it exposes SQLite's C API, and which of the calls the shim uses it has
     (`sqlite3_open_v2`, `prepare_v3`, the binds, `step`, the column reads,
     `errmsg`, `extended_errcode`, `busy_timeout`, `changes64`, and the rest).
   - How a Goose package would build or link it. `goose build` compiles C from a
     `.build` sidecar or builds a CMake target; neither runs Cargo. Find whether a
     program can build it with no Rust toolchain, such as from a prebuilt static
     library per platform, and if it can't, what requiring Rust costs a user.
   - Its own maturity statement (it calls itself beta), and what it says isn't
     supported yet.
   - File compatibility both ways: a database SQLite wrote, opened and written by
     Turso, and the reverse, in WAL mode and with MVCC on.
   Record what's found, with sources and dates, in this task, and the decision to go on
   or stop in `docs/decisions.md`.
2. If it goes on: a way to choose the engine at build time, with the same Goose API,
   and the tests under `test/` run against each, with any difference recorded.
3. A benchmark of SQLite against Turso, on the same machine and file system, for one
   writer and many read-only readers (task 001's layout), and for several writers at
   once (`BEGIN CONCURRENT` against SQLite's single writer). The method and results go
   in `docs/results.md`.

## Acceptance criteria

- [ ] The facts in step 1 recorded with their sources, and the decision to go on or
      stop in `docs/decisions.md`
- [ ] If it goes on: `scripts/test.sh` passes with each engine
- [ ] If it goes on: the benchmark for both patterns in `docs/results.md`, with how it
      was measured
