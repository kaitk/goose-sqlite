# Decisions

The record of goose-sqlite's design decisions, for contributors and agents: each dated,
with its reason and the trade-off that matters. How the package works, for its users, is
[architecture](architecture.md).

## Settled

- **Bindings, not SQLite in Goose.** SQLite is about 250,000 lines of C, and its file
  format and query planner are not what measuring Goose is about (2026-10-19).
- **SQLite before Postgres.** It needs no network code, so it waits on nothing in
  goose-http, and goose-rest needs a database for its examples and best practices
  (goose-rest's task 035). snowtime-native, which a Goose port would replace, already
  runs on SQLite (2026-10-19).
- **Synchronous, one connection per thread.** SQLite's calls block, so a goose-rest
  program runs them on a lane, never on a worker. snowtime-native's layout fits that: one
  writer thread, and read-only WAL connections each owned by one reader thread
  (`crates/server/src/connections.rs`) (2026-10-19).
- **The amalgamation in the repository, built from the `.build` sidecar.** Every
  platform then builds the same SQLite version with the same compile-time options, with
  no system library: macOS's is old, Windows has none, and Linux needs a `-dev` package.
  rusqlite's `bundled` feature, which snowtime-native uses, does the same.
  `vendor/sqlite/` holds `sqlite3.c` and `sqlite3.h` from SQLite's amalgamation zip,
  unchanged; [development](development.md#sqlite) names the version and its checksum.
  The cost is one 9.6 MB C file, which `goose build` compiles once per C compiler and
  keeps under `GOOSE_HOME`: 10 to 15 s at `-O2` on a loaded M1 Pro with clang, and 22
  to 25 s on the same machine's Linux arm64 VM with gcc
  ([results](results.md#build-times)). Later builds take under half a second
  (2026-10-19).
- **SQLite 3.54.1, the latest release.** The pin moves to each new release, in its own
  commit, with the tests ([development](development.md#move-the-sqlite-pin))
  (2026-10-19).
- **SQLite's recommended compile-time options, with two departures and two
  additions.** `sqlite.build` passes them to `sqlite3.c` and the shim. From SQLite's
  [recommended set](https://sqlite.org/compile.html#rcmd), which SQLite tests as one
  configuration: `SQLITE_DQS=0`, `SQLITE_DEFAULT_MEMSTATUS=0`,
  `SQLITE_DEFAULT_WAL_SYNCHRONOUS=1`, `SQLITE_LIKE_DOESNT_MATCH_BLOBS`,
  `SQLITE_OMIT_DECLTYPE`, `SQLITE_OMIT_DEPRECATED`, `SQLITE_OMIT_PROGRESS_CALLBACK`,
  `SQLITE_OMIT_SHARED_CACHE`, `SQLITE_OMIT_AUTOINIT`, and `SQLITE_STRICT_SUBTYPE=1`.
  Together SQLite measures them as about 5 percent fewer CPU cycles. The shim calls
  `sqlite3_initialize` before each open, as `SQLITE_OMIT_AUTOINIT` requires. The
  departures (2026-10-19):
  - `SQLITE_THREADSAFE=2`, not 0: a program opens connections on several threads, which
    0 forbids. 2, multi-thread mode, drops the mutex on each connection that 1 keeps,
    which is safe while each connection belongs to one thread at a time, this
    package's rule.
  - `SQLITE_MAX_EXPR_DEPTH` keeps its default of 1000, not 0: the depth check turns an
    expression nested too deep into an error rather than a stack overflow, and a
    Goose worker thread runs on the platform's default native stack, 512 KB on macOS
    and 1 MB on Windows.

  The additions: `SQLITE_OMIT_LOAD_EXTENSION`, since a program loads no SQLite
  extension at run time and so needs no `dlopen`; and `SQLITE_MAX_WORKER_THREADS=0`,
  since the package starts no threads, and SQLite's sorter would otherwise be allowed
  to. `SQLITE_DEFAULT_FOREIGN_KEYS=1` is the next decision's.
- **Foreign keys are enforced by default, and a connection can turn them off.**
  `sqlite.build` passes `SQLITE_DEFAULT_FOREIGN_KEYS=1`, as rusqlite's `bundled` build,
  which snowtime-native uses, does, so a schema's `REFERENCES` hold without a pragma
  on each connection. `sqlite::open(path, flags, false)` turns them off for that
  connection, with `PRAGMA foreign_keys = OFF`, for a bulk load or a migration that
  rebuilds a table. SQLite's own default is off, so SQL written for other SQLite
  builds may fail here where it passed there (2026-10-19). This replaces the open
  question of 2026-10-19.
- **No optional SQLite extensions yet.** FTS5, R*Tree, the math functions, and the
  session extension stay out until a program needs one; the JSON functions are built
  in. Each adds compile time and code to every program that imports the package
  (2026-10-19).
- **The package's own catcher, `sqlite::run`, rather than the stdlib's `exception`.**
  A call that fails leaves through `return ... from run`, carrying a `sqlite::Error`
  of SQLite's extended result code and message. The compiler then checks that each
  call that can fail runs inside a `run` or a `transaction`. With `exception::throw`, a
  sqlite error inside a program's own `exception::try<u8[]>` would be a type error, so
  the package's errors stay apart from the program's. The trade-off: a program that
  wants one handler for both wraps one in the other (2026-10-19).
- **Handles are flat.** `Db` and `Stmt` each hold the address of SQLite's object as
  an `i64`, so they cross `thread_spawn` and queues, and C keeps no pointer into Goose
  memory: SQLite copies bound text and blobs (`SQLITE_TRANSIENT`), and column values
  are appended to the caller's `u8[>..]` (2026-10-19).
- **The program finalizes its statements.** Goose has no destructors, so a statement
  left open when an error leaves `run` stays open until the program finalizes it, and
  `close` returns `false`, leaving the connection open, while one is. `finalize`,
  `reset`, `clear_bindings`, and `close` never fail, so they run anywhere, for
  cleanup (2026-10-19).
- **The transaction helper is deferred, and doesn't nest.** `sqlite::transaction`
  runs `BEGIN`, the block, and `COMMIT`, and rolls back when the block or the `COMMIT`
  fails. A deferred `BEGIN` suits one writer per database, the layout above; with
  several writers, `BEGIN IMMEDIATE` avoids a deadlock that ends in `BUSY`. A
  transaction inside another fails at its `BEGIN` and leaves the outer one going.
  Savepoints wait for a program that needs them (2026-10-19).

## Proposed

None.

## Open

- How long `goose build` takes on Windows, with MSVC and with `clang-cl`.
