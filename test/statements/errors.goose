// The errors a call leaves run with: SQLite's extended code and message, or
// the package's own for misuse, and the program's through fail. After each,
// the connection still works.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let path = check::temp_db("errors");
    check::errors("open a missing file read-only", sqlite::run() {
        sqlite::open(path, sqlite::READ_ONLY);
    });
    var db = sqlite::Db {};
    check::errors("open", sqlite::run() { db = sqlite::open(path); });
    check::errors("syntax", sqlite::run() { sqlite::prepare(db, "SELEC 1"); });
    check::errors("no table", sqlite::run() { sqlite::exec(db, "SELECT * FROM missing"); });
    check::errors("two statements", sqlite::run() { sqlite::prepare(db, "SELECT 1; SELECT 2"); });
    check::errors("no statement", sqlite::run() { sqlite::prepare(db, "  -- a comment"); });
    check::errors("empty", sqlite::run() { sqlite::prepare(db, ""); });
    check::errors("a NUL in exec", sqlite::run() { sqlite::exec(db, "SELECT 1;\0"); });
    check::errors("constraint", sqlite::run() {
        sqlite::exec(db, "CREATE TABLE t (n INTEGER NOT NULL UNIQUE)");
        sqlite::exec(db, "INSERT INTO t VALUES (1)");
        sqlite::exec(db, "INSERT INTO t VALUES (1)");
    });
    check::errors("not null, from step", sqlite::run() {
        let s = sqlite::prepare(db, "INSERT INTO t VALUES (?)");
        // A failed step leaves s to finalize: run returns past it.
        check::errors("inner", sqlite::run() {
            sqlite::bind_null(s, 1);
            sqlite::step(s);
        });
        sqlite::finalize(s);
        sqlite::fail("the program's own error");
    });
    check::errors("bind out of range", sqlite::run() {
        let s = sqlite::prepare(db, "SELECT ?");
        check::errors("inner", sqlite::run() { sqlite::bind_i64(s, 2, 0); });
        check::errors("no name", sqlite::run() { sqlite::parameter(s, ":x"); });
        sqlite::finalize(s);
    });
    check::eq("primary of 2067", sqlite::primary(2067), sqlite::CONSTRAINT);
    check::errors("still works", sqlite::run() {
        let s = sqlite::prepare(db, "SELECT count(*) FROM t");
        sqlite::step(s);
        check::eq("rows", sqlite::column_i64(s, 0), 1);
        // close fails while a statement is open, and leaves db open.
        check::that("close with a statement open fails", !sqlite::close(db));
        sqlite::finalize(s);
        check::that("closed", sqlite::close(db));
    });
    check::remove_db(path);
}
