// A plain return out of a transaction's block leaves its function past both
// COMMIT and ROLLBACK, so the connection stays in the transaction. Every
// later transaction on it is then a savepoint inside that one, and nothing
// commits: another connection sees none of the rows. Never return out of the
// block; set a variable and let the block end, or call fail.
import std;
import sqlite from "../../";
import check from "../";

// Adds n, returning out of the block: the mistake this test shows.
fn add_and_return(db: sqlite::Db, n: i64) -> bool {
    let errs = sqlite::transaction(db) {
        sqlite::exec(db, str("INSERT INTO t VALUES (", n, ")"));
        return true;
    };
    return errs.len == 0;
}

fn count(db: sqlite::Db) -> i64 {
    let s = sqlite::prepare(db, "SELECT count(*) FROM t");
    sqlite::step(s);
    let n = sqlite::column_i64(s, 0);
    sqlite::finalize(s);
    return n;
}

fn main() {
    let path = check::temp_db("return_out");
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        let other = sqlite::open(path);
        sqlite::exec(db, "CREATE TABLE t (n INTEGER)");
        add_and_return(db, 1);
        check::that("still in a transaction after the return", sqlite::in_transaction(db));
        let errs = sqlite::transaction(db) { sqlite::exec(db, "INSERT INTO t VALUES (2)"); };
        check::errors("the next transaction, a savepoint", errs);
        check::that("still in a transaction after it", sqlite::in_transaction(db));
        check::eq("rows this connection sees", count(db), 2);
        check::eq("rows another connection sees", count(other), 0);
        // The way out: end the open transaction, which here throws away both.
        sqlite::exec(db, "ROLLBACK");
        check::that("out of the transaction", !sqlite::in_transaction(db));
        check::that("closed", sqlite::close(db));
        check::that("other closed", sqlite::close(other));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
