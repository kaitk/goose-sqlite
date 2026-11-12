// A Conn's query and exec: parameters of each type bound in order, rows read
// by type, statements kept and reused, a block that leaves a query early, an
// error from a kept statement, and close finalizing what it kept.
import std;
import sqlite from "../../";
import check from "../";

fn first_name(c: sqlite::Conn&, n: i64) -> u8[>..] {
    sqlite::query(c, "SELECT name FROM t WHERE n >= ? ORDER BY n", n) { r =>
        return sqlite::text(r, 0);
    };
    return str("none");
}

fn main() {
    let path = check::temp_db("conn");
    var c = sqlite::Conn { db: sqlite::Db {}, .. };
    let failed = sqlite::run() {
        c.db = sqlite::open(path, sqlite::READ_WRITE | sqlite::CREATE | sqlite::NO_MUTEX);
        sqlite::exec(c.db, "CREATE TABLE t (n INTEGER PRIMARY KEY, name TEXT, r REAL, b, x)");
        let ins = "INSERT INTO t (n, name, r, b, x) VALUES (?, ?, ?, ?, ?)";
        check::eq("insert 1", sqlite::exec(c, ins, 1, "one", 0.5, true, sqlite::NO_VALUE), 1);
        check::eq("insert 2", sqlite::exec(c, ins, 2, "two", -1.25, false, 7), 1);
        check::eq("insert 3", sqlite::exec(c, ins, 3, "kolm, 三", 0.0, true, "x"), 1);
        check::eq("statements kept", c.statements, 1);

        var seen: u8[>..] = [];
        let n = sqlite::query(c, "SELECT n, name, r, b, x FROM t WHERE n <= ? ORDER BY n", 3) { r =>
            format(seen, sqlite::int(r, 0), " ", sqlite::text(r, 1), " ", sqlite::real(r, 2), " ",
                   sqlite::int(r, 3), " ", sqlite::is_null(r, 4), "; ");
        };
        check::eq("rows", n, 3);
        check::text("values", seen, "1 one 0.5 1 true; 2 two -1.25 0 false; 3 kolm, 三 0.0 1 false; ");

        // The block returns from first_name at the first row; the statement
        // it left is reset at its next use.
        check::text("early 2", first_name(c, 2), "two");
        check::text("early 3", first_name(c, 3), "kolm, 三");
        check::text("early none", first_name(c, 4), "none");
        check::eq("statements kept", c.statements, 3);

        check::eq("update", sqlite::exec(c, "UPDATE t SET name = ? WHERE n > ?", "many", 1), 2);
        var names: u8[>..] = [];
        sqlite::query(c, "SELECT name FROM t ORDER BY n") { r => sqlite::text(r, 0, names); names.push(' '); };
        check::text("updated", names, "one many many ");
    };
    check::errors("run", failed);

    // A constraint error from a kept statement fails the run, and the
    // statement works again after.
    let dup = sqlite::run() { sqlite::exec(c, "INSERT INTO t (n) VALUES (?)", 1); };
    for e in dup { check::eq("duplicate", sqlite::primary(e.code), sqlite::CONSTRAINT); }
    let again = sqlite::run() { check::eq("insert 4", sqlite::exec(c, "INSERT INTO t (n) VALUES (?)", 4), 1); };
    check::errors("after", again);

    // Handles past the table's first chunks of 1,024 slots, each still its own
    // statement, and every one stale once finalized.
    var many: sqlite::Stmt[>..] = [];
    let opened = sqlite::run() {
        for i in 2500 { many.push(sqlite::prepare(c.db, "SELECT ?")); }
        var right = 0;
        for s, i in many {
            sqlite::bind_i64(s, 1, i);
            if sqlite::step(s) && sqlite::column_i64(s, 0) == i { right++; }
            sqlite::reset(s);
        }
        check::eq("many handles", right, 2500);
    };
    check::errors("many", opened);
    for s in many { sqlite::finalize(s); }
    let stale = sqlite::run() { sqlite::step(many[2400]); };
    for e in stale { check::eq("stale", e.code, sqlite::MISUSE); }

    check::that("close", sqlite::close(c));
}
