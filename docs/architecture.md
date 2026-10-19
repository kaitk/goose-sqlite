# Architecture

How goose-sqlite works, for its users. The decisions behind it, each with its reason and
what was weighed against it, are in [decisions](decisions.md); measurements are in
[results](results.md).

## Three layers

A program imports `sqlite`, the Goose API in `sqlite.goose`. Its `extern fn`s call the
shim in `shim/sqlite.c`, which adapts SQLite's C interface to what crosses Goose's
foreign-function boundary: handles as integers, text and blobs as `u8[:]` slices in
and appended to a `u8[>..]` out, and SQLite's result codes. Under the shim is SQLite
itself, the amalgamation in `vendor/sqlite/`.

`goose build` compiles the shim and the amalgamation from the package's sidecar,
`sqlite.build`, with SQLite's compile-time options, and links them into the program. A
program needs no system SQLite and no C of its own. The first build with a C compiler
compiles SQLite, which takes 10 s or more; `goose build` keeps it under `GOOSE_HOME`, and
later builds reuse it ([results](results.md#build-times)).

## Errors

A call that can fail runs inside `sqlite::run` or `sqlite::transaction`. When SQLite
returns an error, the call leaves through `return ... from run`, skipping the rest of
the block, and `run` returns it as a one-element `sqlite::Error[]`; when the block
finishes, `run` returns an empty array:

```goose
let failed = sqlite::run() {
    let db = sqlite::open(path);
    sqlite::exec(db, "CREATE TABLE IF NOT EXISTS t (n INTEGER)");
};
for e in failed { print(e.code, ": ", e.message); }
```

An `Error` holds SQLite's extended result code, such as 2067 for
`SQLITE_CONSTRAINT_UNIQUE`, and a message: the connection's (`sqlite3_errmsg`), or
SQLite's text for the code where the connection has none. `sqlite::primary(code)` gives
the primary code, `sqlite::CONSTRAINT` for 2067. The package's own misuse errors, such
as two statements passed to `prepare`, use `sqlite::MISUSE` or `sqlite::RANGE`, and
`sqlite::fail(message)` ends a block with the program's own error, `sqlite::FAILED`.

The compiler checks the rule: a call that can fail, made outside `run` or
`transaction`, doesn't compile. The innermost `run` catches. `finalize`, `reset`,
`clear_bindings`, `close`, and the reads that can't fail run anywhere, so cleanup after
an error needs no `run`.

Goose has no destructors, so a statement that is open when an error leaves `run` stays
open until the program finalizes it, and `close` returns `false`, leaving the
connection open, until every statement on it is finalized.

## Connections and statements

- `sqlite::open(path, flags, foreign_keys)` opens a database file, or `":memory:"`,
  with `sqlite::READ_WRITE | sqlite::CREATE` by default, or `sqlite::READ_ONLY`.
  Extended result codes are on. Foreign keys are enforced, as in rusqlite's `bundled`
  build, unlike SQLite's own default; `foreign_keys` false turns them off for that
  connection. Pragmas such as `journal_mode = WAL` are set with `exec`; SQLite's
  defaults apply otherwise.
- `sqlite::exec(db, sql)` runs every statement in `sql` and discards rows: a schema,
  or pragmas.
- `sqlite::prepare(db, sql)` prepares one statement, a `sqlite::Stmt`. Trailing spaces
  and comments are allowed; a second statement is a `MISUSE` error.
- `bind_i64`, `bind_f64`, `bind_text`, `bind_blob`, and `bind_null` bind parameter
  `i`, counting from 1; `sqlite::parameter(s, ":name")` gives a named parameter's
  index. SQLite copies text and blobs, so the slice can change after the call.
- `sqlite::step(s)` runs to the next row and returns `true` there, or `false` when the
  statement is done. `reset` makes it ready to run again, keeping its bindings, and
  `clear_bindings` sets them to NULL.
- Column `i` of the current row, counting from 0: `column_type` (`INTEGER`, `FLOAT`,
  `TEXT`, `BLOB`, or `NULL`), `is_null`, `column_i64`, `column_f64`, and `column_text`
  and `column_blob`, which append the bytes to a `u8[>..]` the caller owns. A value of
  another type is converted as SQLite converts it; NULL reads as 0 and as no bytes.
- `changes`, `last_insert_rowid`, `in_transaction`, `busy_timeout`, and `version` are
  SQLite's calls of those names.

## Transactions

`sqlite::transaction(db) { ... }` runs `BEGIN`, the block, and `COMMIT`. When a call in
the block fails, the block calls `fail`, or the `COMMIT` fails, it rolls back and
returns the error; otherwise it returns an empty array. It must be called inside a
`run` or another transaction, as the calls in its block are: nested, it can fail the
enclosing block (below).

`BEGIN` is deferred: the first read takes the snapshot, and the first write the write
lock. That suits one writer per database. Where several connections write, a
transaction that reads and then writes can fail with `BUSY` when it tries to take the
lock; `busy_timeout` makes a connection wait for a lock rather than fail at once.

A transaction inside another, whether `transaction` or `exec(db, "BEGIN")` began the
outer one, is a savepoint: `SAVEPOINT goose_sqlite`, the block, and
`RELEASE goose_sqlite`, which keeps the inner block's changes for the outer `COMMIT`.
When the inner block or its `RELEASE` fails, `ROLLBACK TO goose_sqlite` undoes only
the inner block's changes, the inner `transaction` returns the error, and the outer
transaction goes on. When the outer one then fails, it undoes the inner changes too.
Transactions nest to any depth, each undoing only its own. Don't name a savepoint of
your own `goose_sqlite`.

Some errors make SQLite end the whole transaction, savepoints and all: an `OR ROLLBACK`
conflict clause, a full disk, or an I/O error. After one inside a nested transaction,
the inner `transaction` doesn't return the error: it fails the enclosing block with it,
as a call that fails does, so the outer block stops at the inner call rather than go
on outside any transaction, where each later statement would commit on its own. The
outer `transaction` returns the error, with nothing left to roll back. The error goes
to the innermost `run` around the inner call, which is the outer transaction's unless
the program wraps the inner call in a `run` of its own.

## Threads

SQLite's calls block until SQLite is done, and the package starts no threads. A program
runs it on a thread of its own: in goose-rest, a lane, never a worker that serves
requests.

A connection, and the statements prepared on it, belong to one thread at a time. SQLite
is built in multi-thread mode (`SQLITE_THREADSAFE=2`), which leaves out the mutex each
connection would otherwise take on every call, so two threads that use one connection
at once corrupt it. `Db` and `Stmt` hold the address of SQLite's object as an `i64`, so
a handle can cross `thread_spawn` or a queue, to hand a connection over; it mustn't be
used on the old thread after.

The layout the package is built for is one writer and several readers on a database
in WAL mode, each a thread with a connection of its own: the writer opens the file
read-write and sets `journal_mode = WAL`, and each reader opens it with
`sqlite::READ_ONLY`. A reader's transaction reads one snapshot from its first read to
its end, and the writer commits without waiting for readers.

## SQLite's build

The amalgamation is SQLite 3.54.1, unchanged ([development](development.md#sqlite)).
`sqlite.build` builds it with SQLite's recommended options, except where
[decisions](decisions.md) says why not:

| Option | Effect |
|---|---|
| `SQLITE_THREADSAFE=2` | Connections on several threads, each used by one at a time |
| `SQLITE_DQS=0` | A double-quoted string is an identifier only, never a string literal |
| `SQLITE_DEFAULT_MEMSTATUS=0` | No memory statistics, for faster allocation |
| `SQLITE_DEFAULT_WAL_SYNCHRONOUS=1` | `synchronous = NORMAL` in WAL mode: a power loss can lose the last commits, never the database |
| `SQLITE_LIKE_DOESNT_MATCH_BLOBS` | `LIKE` and `GLOB` are false for a blob |
| `SQLITE_OMIT_DECLTYPE` | No declared column types on result columns |
| `SQLITE_OMIT_DEPRECATED` | No deprecated interfaces |
| `SQLITE_OMIT_PROGRESS_CALLBACK` | No progress handler |
| `SQLITE_OMIT_SHARED_CACHE` | No shared-cache mode |
| `SQLITE_OMIT_AUTOINIT` | The shim initializes SQLite before each open |
| `SQLITE_STRICT_SUBTYPE=1` | An error for a function that sets a subtype it didn't declare |
| `SQLITE_OMIT_LOAD_EXTENSION` | No extensions loaded at run time |
| `SQLITE_MAX_WORKER_THREADS=0` | SQLite starts no threads of its own |
| `SQLITE_DEFAULT_FOREIGN_KEYS=1` | Foreign keys enforced unless `open` turns them off |

No optional extension is built in: no FTS5, R*Tree, math functions, or session
extension. The JSON functions are part of SQLite's core.
