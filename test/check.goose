// What the tests under test/ share. Each check prints what it checked, for the
// test's golden file in test/expected/, then asserts it, so a failure shows
// in the output as well as in the exit code.
namespace check;

import std;
import os;
import sqlite from "../";

// Prints "label: ok", or "label: FAILED".
fn that(label: const u8[:], ok: bool) {
    print(label, if ok { ": ok" } else { ": FAILED" });
    assert(ok);
}

// Prints the value, and what was expected if it differs.
fn eq(label: const u8[:], got: i64, want: i64) {
    if got == want { print(label, ": ", got); }
    else { print(label, ": ", got, ", expected ", want, ": FAILED"); }
    assert(got == want);
}

// Prints the text, and what was expected if it differs.
fn text(label: const u8[:], got: const u8[:], want: const u8[:]) {
    let ok = got == want;
    if ok { print(label, ": ", got); }
    else { print(label, ": \"", got, "\", expected \"", want, "\": FAILED"); }
    assert(ok);
}

// Prints each error that a run or transaction returned, as "label: code
// message", or "label: no error".
fn errors(label: const u8[:], failed: const sqlite::Error[:]) {
    if failed.len == 0 { print(label, ": no error"); }
    for e in failed { print(label, ": ", e.code, " ", e.message); }
}

// A database file for one test run, in the system's temporary directory: a
// name of its own, so runs of the same test at -O0 and -O2 can't meet.
fn temp_db(name: const u8[:]) -> u8[>..] {
    var dir: u8[>..] = [];
    if !env("TMPDIR", dir) && !env("TEMP", dir) {
        dir.append(if is_dir("/tmp") { "/tmp" } else { "." });
    }
    var r = rng { random_seed() };
    return str(dir, "/goose-sqlite-", name, "-", r.rand_int(1000000000), ".db");
}

// Deletes the database file at path and the journal, WAL, and shared-memory
// files SQLite keeps beside it.
fn remove_db(path: const u8[:]) {
    delete_file(path);
    for suffix in ["-journal", "-wal", "-shm"] { delete_file(str(path, suffix)); }
}
