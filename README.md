# goose-sqlite

SQLite for [Goose](https://github.com/aardappel/goose): a Goose API over SQLite's C
library, built from the SQLite amalgamation that this repository carries, so a program
needs no system SQLite ([architecture](docs/architecture.md)). Its first user is
[Plod](https://github.com/kaitk/plod), whose programs run the database on lanes,
threads of their own.

Calls block until SQLite is done, and a connection belongs to one thread. A call that
fails leaves through `return ... from sqlite::run` with SQLite's error, and the compiler
checks that every such call runs inside `run` or a transaction.

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Feature | Notes |
|---|---|---|
| 🟢 | Connections | Open a file read-write or read-only, or in memory; pragmas such as `journal_mode = WAL` through `exec`. |
| 🟢 | Statements | Prepare, bind integers, reals, text, blobs, and NULL by number or name, step, read columns by type, reset, and finalize. |
| 🟢 | Errors | SQLite's extended result code and message, through `sqlite::run`. |
| 🟢 | Transactions | `sqlite::transaction`, which commits, or rolls back and returns the error. |
| 🟢 | Savepoints | A transaction inside another is a savepoint: its failure undoes only its own changes. |
| 🟢 | Threads | One writer and read-only WAL readers, each a thread with its own connection. |
| 🟡 | Platforms | Tested on macOS (arm64) and Linux (arm64, and x64 under emulation); not yet on Windows. |
| 🔴 | Migrations | Numbered SQL files applied in order, once each. |
| 🔴 | Extensions | FTS5, R*Tree, and the math functions aren't built in. |

## Quick start

```goose
import std;
import sqlite from "github.com/kaitk/goose-sqlite@v0.0.3";

fn main() {
    let failed = sqlite::run() {
        let db = sqlite::open("app.db");
        sqlite::exec(db, "PRAGMA journal_mode = WAL");
        sqlite::exec(db, "CREATE TABLE IF NOT EXISTS note (id INTEGER PRIMARY KEY, text TEXT)");
        let errs = sqlite::transaction(db) {
            let ins = sqlite::prepare(db, "INSERT INTO note (text) VALUES (?)");
            sqlite::bind_text(ins, 1, "hello");
            sqlite::step(ins);
            sqlite::finalize(ins);
        };
        for e in errs { print("rolled back: ", e.message); }
        let q = sqlite::prepare(db, "SELECT id, text FROM note");
        while sqlite::step(q) {
            var text: u8[>..] = [];
            sqlite::column_text(q, 1, text);
            print(sqlite::column_i64(q, 0), " ", text);
        }
        sqlite::finalize(q);
        sqlite::close(db);
    };
    for e in failed { print("error ", e.code, ": ", e.message); }
}
```

```sh
goose build notes.goose
```

The first build compiles SQLite, which takes 10 s or more; later builds reuse it. The
tag `v0.0.3` has everything marked 🟢 above. The package needs a C compiler, which
`goose build` finds, and no other package.

## Rules for safe use

- **Bind values; don't build SQL from them.** `exec` takes no parameters, so text a
  user or another system supplied never goes into its SQL. Prepare a statement with
  `?` or `:name` and bind the value, which SQLite never reads as SQL.
- **Never `return` out of a `transaction` block.** A `return` in the block returns from
  the enclosing function past both `COMMIT` and `ROLLBACK`, and leaves the connection
  in the transaction, where every later `transaction` is a savepoint that never
  commits. Let the block end, or call `fail` to roll back.
- **Step a statement until `step` returns `false`.** Some errors, such as a deferred
  foreign key, come only as the statement finishes, and `reset` and `finalize` report
  none. Resetting an `INSERT ... RETURNING` after its first row can undo the insert
  without a word.
- **Finalize statements on the error path too.** Declare the handles outside `run`,
  and finalize and close after it, whether it failed or not; a `Stmt {}` never
  prepared finalizes as a no-op:

  ```goose
  var db = sqlite::Db {};
  var s = sqlite::Stmt {};
  let failed = sqlite::run() {
      db = sqlite::open("app.db");
      s = sqlite::prepare(db, "INSERT INTO note (text) VALUES (?)");
      sqlite::bind_text(s, 1, text);
      while sqlite::step(s) {}
  };
  sqlite::finalize(s);
  sqlite::close(db);
  for e in failed { print("error ", e.code, ": ", e.message); }
  ```

- **One connection per thread.** A connection's mutex keeps a shared one sound, but
  its threads then take turns.

## API

All in namespace `sqlite`. Text and blobs go in as `u8[:]` and come out appended to a
`u8[>..]` the caller owns. [Architecture](docs/architecture.md) has the details.

- **`run() { ... }`** runs the block and returns an empty `Error[]`, or the error that
  a call in it failed with. `Error` is `{ code: i32, message: u8[] }`: SQLite's
  extended result code and message. `primary(code)` gives the primary code, such as
  `CONSTRAINT`. `fail(message)` or `fail(code, message)` ends the block with an error
  of the program's own.
- **`transaction(db) { ... }`** runs the block between `BEGIN` and `COMMIT`, and rolls
  back and returns the error when it fails. Inside a transaction already, it runs the
  block in a savepoint, whose failure undoes only the block's changes and leaves the
  outer transaction going. It runs inside `run` or another transaction.
- **Connections**: `open(path, flags = READ_WRITE | CREATE, foreign_keys = true)`,
  or `READ_ONLY`, gives a `Db`. Foreign keys are enforced, as in rusqlite's `bundled`
  build, unless `foreign_keys` is false; SQLite's defensive mode is on and
  `trusted_schema` off. `exec(db, sql)` runs statements and discards rows. `close(db)`
  returns `false` while a statement on it isn't finalized. Also `busy_timeout`,
  `changes`, `last_insert_rowid`, `in_transaction`, and `version`.
- **Statements**: `prepare(db, sql)` gives a `Stmt`. `bind_i64`, `bind_f64`,
  `bind_text`, `bind_blob`, and `bind_null` bind parameter `i`, from 1;
  `parameter(s, ":name")` and `parameter_count(s)`. `step(s)` returns `true` at a row
  and `false` when done. `reset`, `clear_bindings`, and `finalize`. Once `finalize` or
  `close` frees a handle, every copy of it is stale, and a call through one fails with
  `MISUSE`.
- **Columns**, from 0: `column_count`, `column_name`, `column_type`, `is_null`,
  `column_i64`, `column_f64`, `column_text(s, i, out)`, and `column_blob(s, i, out)`.
- **Threads**: each thread opens its own connection, and keeps its statements. Every
  connection is opened with its mutex on, so one used by two threads at once stays
  sound. The package starts no threads.

## Build times

`goose build` compiles SQLite once per C compiler and keeps it. On an M1 Pro under
load, the first build took 10 to 15 s with clang under macOS, and 22 to 25 s with gcc
in a Linux arm64 VM; later builds took under half a second. The machine, method, and
each run are in [docs/results.md](docs/results.md).

## Credits

[SQLite](https://sqlite.org/) is in the public domain; `vendor/sqlite/` carries its
amalgamation unchanged. Building it inside the package follows rusqlite's `bundled`
feature. [docs/credits.md](docs/credits.md) names what the package takes from each.

## Layout

```text
sqlite.goose     the package: connections, statements, columns, errors, transactions
sqlite.build     the sidecar: the C sources and SQLite's compile-time options
shim/            the C between sqlite.goose and SQLite
vendor/sqlite/   SQLite's amalgamation, sqlite3.c and sqlite3.h
test/            tests by area, their golden output, and the runner
scripts/         the Goose pin and the test script
docs/            architecture, decisions, development setup, results, Goose findings,
                 credits
tasks/           task tracking (tasks/README.md)
```

## Pins

| What | Pin | Why |
|---|---|---|
| Goose compiler | `aardappel/goose` release `v2026.3` (`8511ae3`), which the scripts fetch ([setup](docs/development.md#set-up-the-goose-compiler)) | An official release builds the same on every platform; a commit is pinned only for a fix not yet released |
| SQLite | 3.54.1, the amalgamation in `vendor/sqlite/` ([checksums](docs/development.md#sqlite)) | The latest release; every platform builds the same version with the same options |

Move a pin in its own commit, with the tests that still hold
([Goose](docs/development.md#move-the-pin),
[SQLite](docs/development.md#move-the-sqlite-pin)).
