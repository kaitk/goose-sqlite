// SQLite, over the amalgamation in vendor/sqlite/ and the shim in
// shim/sqlite.c. Every call blocks until SQLite is done, and the package
// starts no threads: a program runs it on a thread of its own, such as a
// Plod lane. A connection, and the statements prepared on it, belong to
// one thread at a time (docs/architecture.md).
//
//   let failed = sqlite::run() {
//       let db = sqlite::open("app.db");
//       sqlite::exec(db, "CREATE TABLE IF NOT EXISTS t (n INTEGER)");
//       let s = sqlite::prepare(db, "SELECT n FROM t WHERE n > ?");
//       sqlite::bind_i64(s, 1, 10);
//       while sqlite::step(s) { print(sqlite::column_i64(s, 0)); }
//       sqlite::finalize(s);
//       sqlite::close(db);
//   };
//   for e in failed { print(e.code, ": ", e.message); }
//
// A call that fails leaves through `return ... from sqlite::run`, so each
// one runs inside run or transaction, or the program doesn't compile.
// finalize, reset, clear_bindings, and close never fail, and so run
// anywhere, for cleanup after an error.
//
// Each function that can fail has an untyped parameter, so it is checked only
// where a program calls it: `goose check` of this file alone checks a fully
// typed function as a caller of fail outside run, and rejects it.
namespace sqlite;

import std;

// A connection: a handle to SQLite's sqlite3 in the shim's table, freed only
// by close. Flat, so it crosses thread_spawn and queues; best used by one
// thread at a time. Once it is closed, every copy of it is stale: a call that
// can fail fails with MISUSE, and the rest read as nothing.
struct Db { id: i64 = 0 }

// A prepared statement on a connection: a handle to a sqlite3_stmt, freed
// only by finalize, after which every copy is stale, as a Db's.
struct Stmt { id: i64 = 0 }

// Why a call failed: SQLite's extended result code, or FAILED for fail, and
// a message (sqlite3_errmsg, or sqlite3_errstr where SQLite set none).
struct Error { code: i32, message: u8[] }

// open's flags, SQLite's SQLITE_OPEN_* values. Pass READ_ONLY, READ_WRITE,
// or READ_WRITE | CREATE.
let READ_ONLY: i32 = 1;
let READ_WRITE: i32 = 2;
let CREATE: i32 = 4;

// column_type's answers, SQLite's fundamental datatypes.
let INTEGER: i32 = 1;
let FLOAT: i32 = 2;
let TEXT: i32 = 3;
let BLOB: i32 = 4;
let NULL: i32 = 5;

// Result codes an Error may hold, as primary(code) gives them; the full list
// is SQLite's (sqlite.org/rescode.html).
let OK: i32 = 0;
let ERROR: i32 = 1;
let BUSY: i32 = 5;
let LOCKED: i32 = 6;
let READONLY: i32 = 8;
let CONSTRAINT: i32 = 19;
let MISUSE: i32 = 21;
let RANGE: i32 = 25;
let ROW: i32 = 100;
let DONE: i32 = 101;
// fail's code: the program's own error, not SQLite's.
let FAILED: i32 = -1;

extern "sq_open" fn open_c(path: const u8[:], flags: i32, db: i64&) -> i32;
extern "sq_close" fn close_c(db: i64) -> i32;
extern "sq_errcode" fn errcode_c(db: i64) -> i32;
extern "sq_errmsg" fn errmsg_c(db: i64, out: u8[>..]&);
extern "sq_errstr" fn errstr_c(rc: i32, out: u8[>..]&);
extern "sq_exec" fn exec_c(db: i64, sql: const u8[:]) -> i32;
extern "sq_prepare" fn prepare_c(db: i64, sql: const u8[:], stmt: i64&, used: i64&) -> i32;
extern "sq_finalize" fn finalize_c(stmt: i64) -> i32;
extern "sq_reset" fn reset_c(stmt: i64) -> i32;
extern "sq_clear_bindings" fn clear_bindings_c(stmt: i64) -> i32;
extern "sq_db_of" fn db_of_c(stmt: i64) -> i64;
// Each index and ms crosses as an i64, and the shim checks its range before
// converting it to SQLite's int.
extern "sq_bind_int64" fn bind_int64_c(stmt: i64, i: i64, v: i64) -> i32;
extern "sq_bind_double" fn bind_double_c(stmt: i64, i: i64, v: f64) -> i32;
extern "sq_bind_text" fn bind_text_c(stmt: i64, i: i64, v: const u8[:]) -> i32;
extern "sq_bind_blob" fn bind_blob_c(stmt: i64, i: i64, v: const u8[:]) -> i32;
extern "sq_bind_null" fn bind_null_c(stmt: i64, i: i64) -> i32;
extern "sq_bind_index" fn bind_index_c(stmt: i64, name: const u8[:]) -> i32;
extern "sq_bind_count" fn bind_count_c(stmt: i64) -> i32;
extern "sq_step" fn step_c(stmt: i64) -> i32;
extern "sq_column_count" fn column_count_c(stmt: i64) -> i32;
extern "sq_column_type" fn column_type_c(stmt: i64, i: i64) -> i32;
extern "sq_column_int64" fn column_int64_c(stmt: i64, i: i64) -> i64;
extern "sq_column_double" fn column_double_c(stmt: i64, i: i64) -> f64;
extern "sq_column_text" fn column_text_c(stmt: i64, i: i64, out: u8[>..]&) -> i32;
extern "sq_column_blob" fn column_blob_c(stmt: i64, i: i64, out: u8[>..]&) -> i32;
extern "sq_column_name" fn column_name_c(stmt: i64, i: i64, out: u8[>..]&);
extern "sq_changes" fn changes_c(db: i64) -> i64;
extern "sq_last_insert_rowid" fn last_insert_rowid_c(db: i64) -> i64;
extern "sq_busy_timeout" fn busy_timeout_c(db: i64, ms: i64) -> i32;
extern "sq_autocommit" fn autocommit_c(db: i64) -> bool;
extern "sq_version" fn version_c(out: u8[>..]&);

// Runs F, and returns an empty array when it returned, or the error that a
// call inside it failed with. F's results are discarded; it writes what it
// reads into variables of the caller's. The innermost run catches.
fn run<F>() -> Error[] {
    F();
    return [];
}

// Runs F in a transaction on db: BEGIN, then F, then COMMIT. When F, or the
// COMMIT, fails, rolls back and returns the error; else returns an empty
// array. BEGIN is deferred: a read takes the snapshot, and the first write
// takes the write lock. Inside a transaction already, F runs in a savepoint
// instead: RELEASE keeps its changes for the outer COMMIT, and a failure rolls
// back only F's changes and leaves the outer transaction going. When SQLite
// has ended the whole transaction after the failure, the error fails the
// enclosing run instead, so the outer block goes no further. F must not
// return out of its block: that skips COMMIT and ROLLBACK both, and leaves db
// in the transaction (docs/architecture.md, "Transactions").
fn transaction<F>(db: Db) -> Error[] {
    let nested = !autocommit_c(db.id);
    // One name serves every depth: ROLLBACK TO and RELEASE take the most
    // recent savepoint of the name, which is the innermost transaction's.
    let failed = run() {
        exec(db, if nested { "SAVEPOINT goose_sqlite" } else { "BEGIN" });
        for e in run(F) {
            rollback(db, nested);
            fail(e.code, e.message);
        }
        let rc = exec_c(db.id, if nested { "RELEASE goose_sqlite" } else { "COMMIT" });
        if rc != OK {
            var msg: u8[>..] = [];
            message(db.id, rc, msg);
            rollback(db, nested);
            fail(rc, msg);
        }
    };
    // Going on would run the outer block's later statements outside any
    // transaction, each committing on its own.
    if nested && autocommit_c(db.id) {
        for e in failed { fail(e.code, e.message); }
    }
    return failed;
}

// Leaves the innermost run, or a transaction, which rolls back, with an
// Error of code and message.
fn fail(code: i32, message: const u8[:]) {
    return [Error { code: code, message: str(message) }] from run;
}

// Leaves the innermost run with an Error of FAILED and message.
fn fail(message) { fail(FAILED, message); }

// The primary result code of an extended one: CONSTRAINT for a
// SQLITE_CONSTRAINT_UNIQUE, say.
fn primary(code: i32) -> i32 { code & 255 }

// SQLite's version, such as "3.54.1".
fn version() -> u8[>..] {
    var v: u8[>..] = [];
    version_c(v);
    return v;
}

// Opens the database file at path, a UTF-8 path or ":memory:", with flags:
// READ_WRITE | CREATE by default. Extended result codes are on, and so is
// foreign key enforcement, unless foreign_keys is false.
fn open(path, flags: i32 = READ_WRITE | CREATE, foreign_keys: bool = true) -> Db {
    var id: i64 = 0;
    let rc = open_c(path, flags, id);
    if rc != OK {
        var msg: u8[>..] = [];
        message(id, rc, msg);
        close_c(id);
        fail(rc, msg);
    }
    // SQLITE_DEFAULT_FOREIGN_KEYS=1 in sqlite.build turns enforcement on.
    if !foreign_keys {
        let off = exec_c(id, "PRAGMA foreign_keys = OFF");
        if off != OK {
            var msg: u8[>..] = [];
            message(id, off, msg);
            close_c(id);
            fail(off, msg);
        }
    }
    return Db { id: id };
}

// Closes db and returns true, or returns false and leaves it open while a
// statement prepared on it isn't finalized. False too when db is closed
// already.
fn close(db: Db) -> bool { close_c(db.id) == OK }

// Runs every statement in sql, discarding any rows: a schema, pragmas, or
// BEGIN and COMMIT.
fn exec(db: Db, sql) { check(db.id, exec_c(db.id, sql)); }

// Wait up to ms milliseconds for a lock another connection holds before a
// call fails with BUSY; 0 fails at once, the default. ms is clamped to 0
// through 2147483647, about 24.8 days, the most SQLite takes.
fn busy_timeout(db: Db, ms: i64) { busy_timeout_c(db.id, ms); }

// The rows the last INSERT, UPDATE, or DELETE on db changed.
fn changes(db: Db) -> i64 { changes_c(db.id) }

// The rowid of the last row inserted on db, or 0.
fn last_insert_rowid(db: Db) -> i64 { last_insert_rowid_c(db.id) }

// Whether db is inside a transaction.
fn in_transaction(db: Db) -> bool { !autocommit_c(db.id) }

// Prepares sql, one statement, which may end in spaces after its semicolon.
// Fails with MISUSE for more than one, or none.
fn prepare(db: Db, sql) -> Stmt {
    var id: i64 = 0;
    var used: i64 = 0;
    check(db.id, prepare_c(db.id, sql, id, used));
    if id == 0 { fail(MISUSE, "prepare: no statement"); }
    if trim(sql[used..]).len > 0 {
        finalize_c(id);
        fail(MISUSE, "prepare: more than one statement; exec runs several");
    }
    return Stmt { id: id };
}

// Frees s. Every copy of s is stale after; finalizing one again does nothing.
fn finalize(s: Stmt) { finalize_c(s.id); }

// Makes s ready to step from its first row again, keeping its bindings.
fn reset(s: Stmt) { reset_c(s.id); }

// Sets every parameter of s to NULL.
fn clear_bindings(s: Stmt) { clear_bindings_c(s.id); }

// Binds parameter i of s, counting from 1, to a value; fails with RANGE when s
// has no parameter i. Text must be UTF-8; SQLite copies text and blobs.
fn bind_i64(s: Stmt, i, v: i64) { check_stmt(s, bind_int64_c(s.id, i, v)); }
fn bind_f64(s: Stmt, i, v: f64) { check_stmt(s, bind_double_c(s.id, i, v)); }
fn bind_text(s: Stmt, i, v: const u8[:]) { check_stmt(s, bind_text_c(s.id, i, v)); }
fn bind_blob(s: Stmt, i, v: const u8[:]) { check_stmt(s, bind_blob_c(s.id, i, v)); }
fn bind_null(s: Stmt, i) { check_stmt(s, bind_null_c(s.id, i)); }

// The index of the parameter named name in s, such as ":id"; fails with
// RANGE when s has none of that name.
fn parameter(s: Stmt, name) -> i64 {
    let i = bind_index_c(s.id, name);
    if i < 0 { fail(MISUSE, NO_STMT); }
    if i == 0 { fail(RANGE, str("no parameter ", name)); }
    return i;
}

// The number of s's parameters: the largest index, when any are numbered.
fn parameter_count(s: Stmt) -> i64 { bind_count_c(s.id) }

// Runs s to its next row: true at a row, false when it is done. Step until
// it is done: some errors come only then, and reset reports none.
fn step(s) -> bool {
    let rc = step_c(s.id);
    if rc == ROW { return true; }
    if rc == DONE { return false; }
    check_stmt(s, rc);
    return false;
}

// The number of columns in s's rows.
fn column_count(s: Stmt) -> i64 { column_count_c(s.id) }

// Column i of the current row, counting from 0: its type (INTEGER, FLOAT,
// TEXT, BLOB, or NULL), or its value, converted as SQLite converts.
// column_text and column_blob append the bytes to out. A column s doesn't
// have reads as NULL.
fn column_type(s: Stmt, i: i64) -> i32 { column_type_c(s.id, i) }
fn is_null(s: Stmt, i: i64) -> bool { column_type(s, i) == NULL }
fn column_i64(s: Stmt, i: i64) -> i64 { column_int64_c(s.id, i) }
fn column_f64(s: Stmt, i: i64) -> f64 { column_double_c(s.id, i) }
fn column_text(s: Stmt, i, out: u8[>..]&) { check_stmt(s, column_text_c(s.id, i, out)); }
fn column_blob(s: Stmt, i, out: u8[>..]&) { check_stmt(s, column_blob_c(s.id, i, out)); }

// Appends the name of s's column i to out, or nothing for a column s doesn't
// have.
fn column_name(s: Stmt, i: i64, out: u8[>..]&) { column_name_c(s.id, i, out); }

// Appends rc's message to out: the connection's when its last error is rc,
// SQLite's text for the code otherwise.
fn message(db: i64, rc: i32, out: u8[>..]&) {
    if errcode_c(db) == rc { errmsg_c(db, out); } else { errstr_c(rc, out); }
}

fn check(db, rc: i32) {
    if rc == OK { return; }
    var msg: u8[>..] = [];
    message(db, rc, msg);
    fail(rc, msg);
}

let NO_STMT = "no prepared statement: finalized, or never prepared";

fn check_stmt(s, rc: i32) {
    if rc == OK { return; }
    let db = db_of_c(s.id);
    if db == 0 { fail(rc, NO_STMT); }
    check(db, rc);
}

// Rolls back what db's transaction holds, or with savepoint what the innermost
// savepoint holds, and removes the savepoint. Does nothing outside a
// transaction: SQLite has already rolled back the whole of it after some
// errors.
fn rollback(db: Db, savepoint: bool) {
    if autocommit_c(db.id) { return; }
    if savepoint {
        exec_c(db.id, "ROLLBACK TO goose_sqlite");
        exec_c(db.id, "RELEASE goose_sqlite");
    } else {
        exec_c(db.id, "ROLLBACK");
    }
}
