// A statement reports some errors only when it finishes, after its rows: here
// a deferred foreign key, checked when the INSERT ... RETURNING ends. Stepping
// until step returns false reports it; resetting after the first row doesn't,
// and the insert is lost without a word.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let failed = sqlite::run() {
        let db = sqlite::open(":memory:");
        sqlite::exec(db, "CREATE TABLE parent (id INTEGER PRIMARY KEY)");
        sqlite::exec(db, str("CREATE TABLE child (id INTEGER PRIMARY KEY, ",
            "p INTEGER REFERENCES parent (id) DEFERRABLE INITIALLY DEFERRED)"));
        fn children() -> i64 {
            let q = sqlite::prepare(db, "SELECT count(*) FROM child");
            sqlite::step(q);
            let n = sqlite::column_i64(q, 0);
            sqlite::finalize(q);
            return n;
        }
        let s = sqlite::prepare(db, "INSERT INTO child (p) VALUES (99) RETURNING id");
        check::errors("step until done", sqlite::run() {
            check::that("a row", sqlite::step(s));
            // The step past the last row fails, so this line isn't reached.
            check::that("done", !sqlite::step(s));
        });
        check::eq("children", children(), 0);

        sqlite::reset(s);
        check::that("the first row", sqlite::step(s));
        check::eq("its id", sqlite::column_i64(s, 0), 1);
        sqlite::reset(s);
        check::eq("children after a reset at the first row", children(), 0);
        sqlite::finalize(s);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
}
