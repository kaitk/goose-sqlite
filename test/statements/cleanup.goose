// The cleanup pattern the README shows: handles declared outside run, and
// finalized and closed after it, so a statement is finalized on the error path
// too and the connection then closes. A Stmt never prepared finalizes as a
// no-op.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    var db = sqlite::Db {};
    var s = sqlite::Stmt {};
    var never = sqlite::Stmt {};
    let failed = sqlite::run() {
        db = sqlite::open(":memory:");
        sqlite::exec(db, "CREATE TABLE t (n INTEGER NOT NULL)");
        s = sqlite::prepare(db, "INSERT INTO t (n) VALUES (?)");
        sqlite::bind_null(s, 1);
        while sqlite::step(s) {}
        never = sqlite::prepare(db, "SELECT 1");
    };
    check::errors("run", failed);
    sqlite::finalize(s);
    sqlite::finalize(never);
    check::that("closed after the error", sqlite::close(db));
}
