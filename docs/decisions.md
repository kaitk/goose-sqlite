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
    0 forbids. 2 compiles SQLite's mutexes in and leaves each connection's off by
    default; the shim's open turns it on for every connection (next decision).
  - `SQLITE_MAX_EXPR_DEPTH` keeps its default of 1000, not 0: the depth check turns an
    expression nested too deep into an error rather than a stack overflow, and a
    Goose worker thread runs on the platform's default native stack, 512 KB on macOS
    and 1 MB on Windows.

  The additions: `SQLITE_OMIT_LOAD_EXTENSION`, since a program loads no SQLite
  extension at run time and so needs no `dlopen`; and `SQLITE_MAX_WORKER_THREADS=0`,
  since the package starts no threads, and SQLite's sorter would otherwise be allowed
  to. `SQLITE_DEFAULT_FOREIGN_KEYS=1` is a later decision's.
- **Every connection is serialized: its mutex is on.** The shim opens each connection
  with `SQLITE_OPEN_FULLMUTEX`, so it takes its mutex on each call, and two threads
  that use one `Db` or its statements at once wait for each other rather than corrupt
  SQLite's memory. A `Db` is a flat handle that crosses `thread_spawn` and queues, so
  nothing stops a program from using it on two threads, and the compiler can't check
  the one-thread rule. `SQLITE_THREADSAFE=2` stays: SQLite's `openDatabase` takes
  `SQLITE_OPEN_FULLMUTEX` whenever the mutexes are compiled in, which 2 does, so the flag
  alone gives each connection what `SQLITE_THREADSAFE=1` would make the default. One
  connection per thread stays the recommended layout: the mutex makes sharing safe, not
  fast, since the threads then take turns. The cost is an uncontended mutex per call:
  about 10 ns a call on an M1 Pro under macOS and 5 ns under Linux in Docker, against
  about 7 ns for a call without it ([results](results.md#connection-mutex)), and nothing
  next to a query that reads a page. This replaces the multi-thread mode of
  `SQLITE_THREADSAFE=2`'s entry of 2026-10-19, where a connection had no mutex and two
  threads using it at once corrupted it (2026-10-19).
- **Foreign keys are enforced by default, and a connection can turn them off.**
  `sqlite.build` passes `SQLITE_DEFAULT_FOREIGN_KEYS=1`, as rusqlite's `bundled` build,
  which snowtime-native uses, does, so a schema's `REFERENCES` hold without a pragma
  on each connection. `sqlite::open(path, flags, false)` turns them off for that
  connection, with `PRAGMA foreign_keys = OFF`, for a bulk load or a migration that
  rebuilds a table. SQLite's own default is off, so SQL written for other SQLite
  builds may fail here where it passed there (2026-10-19). This replaces the open
  question of 2026-10-19.
- **Every connection is defensive and distrusts the schema.** The shim's open sets
  `SQLITE_DBCONFIG_DEFENSIVE` on and `SQLITE_DBCONFIG_TRUSTED_SCHEMA` off, as
  [SQLite's security advice](https://sqlite.org/security.html) recommends for a
  database file that may come from elsewhere: SQL can't corrupt the file on purpose
  (`PRAGMA writable_schema = ON` and `schema_version = N` are ignored, and
  `sqlite_schema` can't be written), and the schema's views and triggers can't call
  functions with side effects. Both are set with `sqlite3_db_config` at open rather
  than `SQLITE_TRUSTED_SCHEMA=0` in `sqlite.build`: defensive mode has no compile-time
  option, so open sets it anyway, and the two then sit together in one place. A program
  can turn `trusted_schema` back on with its pragma; defensive mode has no pragma
  (2026-10-19).
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
- **Handles are flat, and name a slot in the shim's table.** `Db` and `Stmt` each hold
  an `i64`, so they cross `thread_spawn` and queues, and C keeps no pointer into Goose
  memory: SQLite copies bound text and blobs (`SQLITE_TRANSIENT`), and column values
  are appended to the caller's `u8[>..]`. The `i64` is a slot index and that slot's
  generation, not SQLite's address: `close` and `finalize` free the slot and bump the
  generation, and every call looks its handle up first. Goose copies a struct freely,
  so a copy of a `Stmt` finalized through another, or of a `Db` closed through
  another, used to reach freed memory; now it is stale, and a call that can fail
  fails with `MISUSE`, while the rest read as nothing or do nothing. One table serves
  every thread, under SQLite's static application mutex (`SQLITE_MUTEX_STATIC_APP1`),
  rather than a table per thread, since a handle crosses threads when a program hands
  a connection over. The cost is that mutex on each call, uncontended in the
  one-connection-per-thread layout but shared by all threads: about 8 ns a call on an
  M1 Pro under macOS ([results](results.md#handle-lookups)). The table guards
  lookups, not a call in progress: closing a connection on one thread while another
  is inside a call on it is still a race (2026-10-19). This replaces "Handles are
  flat" of 2026-10-19, where a handle was the object's address.
- **The program finalizes its statements.** Goose has no destructors, so a statement
  left open when an error leaves `run` stays open until the program finalizes it, and
  `close` returns `false`, leaving the connection open, while one is. `finalize`,
  `reset`, `clear_bindings`, and `close` never fail, so they run anywhere, for
  cleanup (2026-10-19).
- **The transaction helper is deferred.** `sqlite::transaction` runs `BEGIN`, the
  block, and `COMMIT`, and rolls back when the block or the `COMMIT` fails. A deferred
  `BEGIN` suits one writer per database, the layout above; with several writers,
  `BEGIN IMMEDIATE` avoids a deadlock that ends in `BUSY` (2026-10-19).
- **A transaction inside another is a savepoint.** When the connection is already in a
  transaction, whether `transaction` or `exec(db, "BEGIN")` began it, `transaction`
  runs `SAVEPOINT goose_sqlite`, the block, and `RELEASE goose_sqlite`. When the block
  or the `RELEASE` fails, it runs `ROLLBACK TO goose_sqlite` and `RELEASE goose_sqlite`,
  which undo only the inner block's changes, and returns the error; the outer
  transaction goes on, and its own failure undoes the inner block's released changes
  too. This is what Drizzle and other ORMs do, so a function that opens a transaction
  can be called from inside another. goose-postgres's task 004 takes the same rule,
  where a second `BEGIN` would only warn and go on inside the first transaction, so a
  program's transactions behave the same on either database.

  One name serves every depth: SQLite's `ROLLBACK TO` and `RELEASE` take the most
  recent savepoint of a name, which is the innermost transaction's. Numbering by
  depth, as Drizzle does, would need a counter per connection, and `Db` is a flat
  handle with none. A program's own savepoint named `goose_sqlite` would meet the
  package's.

  After an error for which SQLite ends the whole transaction, such as an
  `OR ROLLBACK` conflict or a full disk, the savepoint is gone with it, and the inner
  `transaction` fails the enclosing block with the error rather than return it. Were
  the outer block to go on, each later statement would run outside any transaction
  and commit on its own: the partial commit a transaction exists to prevent. ORMs
  avoid it because the error throws through the outer block too. The trade-off:
  `transaction` can now fail its caller, so it compiles only inside a `run` or another
  transaction, where before it also compiled outside one. Most programs already have
  one there, since `open` needs it too; a thread handed a `Db` wraps its transaction
  in a `run` (2026-10-19). This replaces "The transaction helper is
  deferred, and doesn't nest" of 2026-10-19, where the inner `BEGIN` failed.

## Proposed

None.

## Open

- How long `goose build` takes on Windows, with MSVC and with `clang-cl`.
