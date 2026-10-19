// The transaction helper: a block that returns commits; one where a call
// fails, or that calls fail, rolls back and returns the error; and a
// transaction inside another, a savepoint that commits with the outer one
// (test/transactions/savepoint.goose has the rest of nesting).
import std;
import sqlite from "../../";
import check from "../";

fn count(db: sqlite::Db) -> i64 {
    let s = sqlite::prepare(db, "SELECT count(*) FROM t");
    sqlite::step(s);
    let n = sqlite::column_i64(s, 0);
    sqlite::finalize(s);
    return n;
}

fn main() {
    let path = check::temp_db("transaction");
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        sqlite::exec(db, "PRAGMA journal_mode = WAL; CREATE TABLE t (n INTEGER UNIQUE)");
        check::errors("commits", sqlite::transaction(db) {
            check::that("inside, in a transaction", sqlite::in_transaction(db));
            sqlite::exec(db, "INSERT INTO t VALUES (1), (2)");
        });
        check::eq("rows", count(db), 2);
        check::errors("a constraint fails", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (3)");
            sqlite::exec(db, "INSERT INTO t VALUES (1)");
        });
        check::that("after, not in a transaction", !sqlite::in_transaction(db));
        check::eq("rows, 3 rolled back", count(db), 2);
        check::errors("the block fails", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (4)");
            check::eq("rows inside", count(db), 3);
            sqlite::fail("changed my mind");
        });
        check::eq("rows, 4 rolled back", count(db), 2);
        check::errors("a transaction inside another", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (5)");
            check::errors("inner", sqlite::transaction(db) {
                sqlite::exec(db, "INSERT INTO t VALUES (6)");
            });
            check::that("the outer one goes on", sqlite::in_transaction(db));
        });
        check::eq("rows, 5 and 6 committed", count(db), 4);
        // A statement on the connection outlives the transaction's ROLLBACK.
        let s = sqlite::prepare(db, "SELECT n FROM t ORDER BY n");
        check::errors("rolls back with a statement open", sqlite::transaction(db) {
            sqlite::exec(db, "DELETE FROM t");
            sqlite::step(s);
            sqlite::fail("stop");
        });
        sqlite::reset(s);
        var ns: u8[>..] = [];
        while sqlite::step(s) { format(ns, sqlite::column_i64(s, 0), " "); }
        check::text("rows left", ns, "1 2 5 6 ");
        sqlite::finalize(s);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
