// A transaction inside another is a savepoint: three levels deep; an inner
// failure, from fail or a constraint, undoes only the inner rows; an inner
// success is undone when the outer one fails; the outer one begun by exec;
// a statement left open across ROLLBACK TO; and an error after which SQLite
// ends the whole transaction, which stops the outer block.
import std;
import sqlite from "../../";
import check from "../";

// The rows of t, in order, as "1 2 3 ".
fn rows(db: sqlite::Db) -> u8[>..] {
    let s = sqlite::prepare(db, "SELECT n FROM t ORDER BY n");
    var ns: u8[>..] = [];
    while sqlite::step(s) { format(ns, sqlite::column_i64(s, 0), " "); }
    sqlite::finalize(s);
    return ns;
}

fn main() {
    let path = check::temp_db("savepoint");
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        sqlite::exec(db, "PRAGMA journal_mode = WAL; CREATE TABLE t (n INTEGER UNIQUE)");

        check::errors("three levels", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (1)");
            check::errors("second", sqlite::transaction(db) {
                sqlite::exec(db, "INSERT INTO t VALUES (2)");
                check::errors("third", sqlite::transaction(db) {
                    sqlite::exec(db, "INSERT INTO t VALUES (3)");
                });
                check::errors("third, failing", sqlite::transaction(db) {
                    sqlite::exec(db, "INSERT INTO t VALUES (4)");
                    sqlite::fail("not 4");
                });
                check::text("in the second", rows(db), "1 2 3 ");
            });
        });
        check::text("three levels, committed", rows(db), "1 2 3 ");
        check::that("after, not in a transaction", !sqlite::in_transaction(db));
        sqlite::exec(db, "DELETE FROM t");

        check::errors("an inner failure", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (1)");
            check::errors("inner", sqlite::transaction(db) {
                sqlite::exec(db, "INSERT INTO t VALUES (2)");
                sqlite::fail("not 2");
            });
            check::that("the outer one goes on", sqlite::in_transaction(db));
            sqlite::exec(db, "INSERT INTO t VALUES (3)");
        });
        check::text("only the inner rows undone", rows(db), "1 3 ");
        sqlite::exec(db, "DELETE FROM t");

        check::errors("an inner constraint failure", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (1)");
            check::errors("inner", sqlite::transaction(db) {
                sqlite::exec(db, "INSERT INTO t VALUES (2)");
                sqlite::exec(db, "INSERT INTO t VALUES (1)");
            });
            check::that("the outer one goes on", sqlite::in_transaction(db));
        });
        check::text("2 undone, 1 committed", rows(db), "1 ");
        sqlite::exec(db, "DELETE FROM t");

        check::errors("the outer one fails", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (1)");
            check::errors("inner", sqlite::transaction(db) {
                sqlite::exec(db, "INSERT INTO t VALUES (2)");
            });
            sqlite::fail("not any");
        });
        check::text("the released inner rows undone too", rows(db), "");

        sqlite::exec(db, "BEGIN");
        sqlite::exec(db, "INSERT INTO t VALUES (1)");
        check::errors("inside exec's BEGIN", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (2)");
        });
        check::errors("inside exec's BEGIN, failing", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (3)");
            sqlite::fail("not 3");
        });
        check::that("still in exec's transaction", sqlite::in_transaction(db));
        sqlite::exec(db, "COMMIT");
        check::text("exec's COMMIT keeps 1 and 2", rows(db), "1 2 ");

        // A statement on the connection outlives the savepoint's ROLLBACK TO.
        let s = sqlite::prepare(db, "SELECT n FROM t ORDER BY n");
        check::errors("a statement open across ROLLBACK TO", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (3)");
            check::errors("inner", sqlite::transaction(db) {
                sqlite::exec(db, "DELETE FROM t");
                sqlite::step(s);
                sqlite::fail("stop");
            });
            sqlite::reset(s);
            var ns: u8[>..] = [];
            while sqlite::step(s) { format(ns, sqlite::column_i64(s, 0), " "); }
            check::text("rows inside", ns, "1 2 3 ");
        });
        sqlite::finalize(s);
        check::text("3 committed", rows(db), "1 2 3 ");

        // OR ROLLBACK makes SQLite end the whole transaction, the savepoint
        // with it: the inner error fails the outer block at the inner call,
        // rather than let it go on outside a transaction.
        var after = false;
        check::errors("SQLite ends the transaction", sqlite::transaction(db) {
            sqlite::exec(db, "INSERT INTO t VALUES (4)");
            check::errors("inner, not returned", sqlite::transaction(db) {
                sqlite::exec(db, "INSERT OR ROLLBACK INTO t VALUES (1)");
            });
            after = true;
            sqlite::exec(db, "INSERT INTO t VALUES (5)");
        });
        check::that("the outer block stops at the inner call", !after);
        check::that("no transaction left", !sqlite::in_transaction(db));
        check::text("4 rolled back, 5 never inserted", rows(db), "1 2 3 ");

        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
