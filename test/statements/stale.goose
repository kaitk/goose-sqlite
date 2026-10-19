// A copy of a Stmt finalized through another copy, and a copy of a Db closed
// through another, are stale: a call that can fail fails with MISUSE, the
// rest read as nothing or do nothing, and none reaches freed memory.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let failed = sqlite::run() {
        let db = sqlite::open(":memory:");
        sqlite::exec(db, "CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (7)");
        let s = sqlite::prepare(db, "SELECT n FROM t");
        let copy = s;
        sqlite::finalize(s);
        check::errors("step a finalized statement's copy", sqlite::run() { sqlite::step(copy); });
        check::errors("bind it", sqlite::run() { sqlite::bind_i64(copy, 1, 1); });
        check::errors("name a parameter of it", sqlite::run() { sqlite::parameter(copy, ":n"); });
        var text: u8[>..] = [];
        check::errors("read its text", sqlite::run() { sqlite::column_text(copy, 0, text); });
        check::eq("its column 0", sqlite::column_i64(copy, 0), 0);
        check::that("its column 0 is NULL", sqlite::is_null(copy, 0));
        check::eq("its column count", sqlite::column_count(copy), 0);
        // Cleanup on a stale statement does nothing.
        sqlite::reset(copy);
        sqlite::clear_bindings(copy);
        sqlite::finalize(copy);
        sqlite::finalize(s);
        check::errors("a Stmt never prepared", sqlite::run() { sqlite::step(sqlite::Stmt {}); });

        // A new statement may take the freed slot; the old handle still
        // doesn't reach it.
        let again = sqlite::prepare(db, "SELECT n + 1 FROM t");
        check::errors("step the old copy beside a new statement", sqlite::run() {
            sqlite::step(copy);
        });
        check::that("the new statement's row", sqlite::step(again));
        check::eq("its value", sqlite::column_i64(again, 0), 8);
        sqlite::finalize(again);

        let other = db;
        check::that("closed", sqlite::close(db));
        check::errors("exec through a closed Db's copy", sqlite::run() {
            sqlite::exec(other, "SELECT 1");
        });
        check::errors("prepare on it", sqlite::run() { sqlite::prepare(other, "SELECT 1"); });
        check::errors("a transaction on it", sqlite::run() {
            check::errors("inner", sqlite::transaction(other) { });
        });
        check::that("not in a transaction", !sqlite::in_transaction(other));
        check::eq("its changes", sqlite::changes(other), 0);
        sqlite::busy_timeout(other, 10);
        check::that("closing it again returns false", !sqlite::close(other));
        check::errors("a Db never opened", sqlite::run() { sqlite::exec(sqlite::Db {}, "SELECT 1"); });
    };
    check::errors("run", failed);
}
