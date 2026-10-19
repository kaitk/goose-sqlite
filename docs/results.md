# Results

What goose-sqlite has measured: each machine's latest run. Each machine has a section of
its own, which starts with how the machine and its tools were set up; numbers from
different machines aren't compared. Earlier runs are in
[results-history.md](results-history.md). The package has no benchmark yet.

- [Build times](#build-times)
  - [Apple M1 Pro, macOS](#apple-m1-pro-macos)
  - [Apple M1 Pro, Linux arm64 in Docker](#apple-m1-pro-linux-arm64-in-docker)
- [Connection mutex](#connection-mutex)

## Build times

How long `goose build` takes with the package's C, SQLite 3.54.1 and the shim, built
with the options in `sqlite.build`. `goose build` compiles that C once per C compiler
and build mode and keeps it under `GOOSE_HOME`, in `build/pkg/local/`; a program at
`-O0` or `-O2` uses the same `-O2` build of it, and `--debug` builds its own at `-O0`.

Method: `goose build -o build/try/schema test/statements/schema.goose`, timed with
`/usr/bin/time -p` on macOS and `date` in the container, package at `9810d69`,
2026-10-19. A cold build first deletes `~/.goose/build/pkg/local/`, so it compiles the
package's C; the Goose runtime's object was already built. A cached build changes
nothing between runs. Other work loaded the machine: its load average was 9 to 16
during these runs, so an idle machine builds faster.

### Apple M1 Pro, macOS

- Apple M1 Pro (8 performance and 2 efficiency cores), 32 GB, macOS 26.3.1
  (Darwin 25.3.0).
- Goose `v2026.2` (`3ee3871`), with Apple clang 21.0.0 (`clang-2100.0.123.102`).

| Build | Runs (s) |
|---|---|
| Cold, `-O2` | 11.37, 14.98, 13.07, 10.74, 10.06, 10.21 |
| Cold, `--debug` (`-O0 -g`) | 1.81, 1.72, 1.70 |
| Cached | 0.27, 0.26, 0.26 |

### Apple M1 Pro, Linux arm64 in Docker

- The same machine, in Docker Desktop 29.8.2's Linux VM (kernel 7.0.14-linuxkit,
  10 CPUs, 8 GB), in a `debian:trixie-slim` container.
- Goose `v2026.2` built from its tag by `scripts/goose.sh`, since the release has no
  Linux arm64 archive, with gcc 14.2.0 (Debian 14.2.0-19).

| Build | Runs (s) |
|---|---|
| Cold, `-O2` | 22.31, 24.51, 24.05 |
| Cold, `--debug` (`-O0 -g`) | 4.11, 3.67, 5.54 |
| Cached | 0.30, 0.28, 0.27 |

## Connection mutex

What `SQLITE_OPEN_FULLMUTEX` costs a connection that one thread uses, the package's
recommended layout: each call then takes and releases the connection's mutex,
uncontended.

Method: a C program, built with `-O2` and the options in `sqlite.build`, opens
`:memory:` once with `SQLITE_OPEN_NOMUTEX` and once with `SQLITE_OPEN_FULLMUTEX`,
checks with `sqlite3_db_mutex` that only the second has a mutex, prepares `SELECT ?`,
and times 5,000,000 rounds of `sqlite3_bind_int64`, `sqlite3_step`,
`sqlite3_column_int64`, and `sqlite3_reset`: four calls, each of which takes the mutex
once. Five runs of each, alternating, on SQLite 3.54.1, 2026-10-19. The machine was
loaded, at a load average of about 5 on macOS.

| Machine | Without (ns a round) | With (ns a round) | Cost a call |
|---|---|---|---|
| Apple M1 Pro, macOS 26.3.1, Apple clang 21.0.0 | 28.3 to 28.6 | 67.7 to 68.3 | about 10 ns |
| The same, Linux arm64 in Docker (kernel 7.0.14-linuxkit), gcc 14.2.0 | 29.5 to 30.3 | 49.8 to 50.8 | about 5 ns |
