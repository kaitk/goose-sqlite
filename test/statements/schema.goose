// A schema created and queried: a table and an index, rows inserted with
// bound values, and a query with a named parameter that reads them back in
// order.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let path = check::temp_db("schema");
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        sqlite::exec(db, """
            CREATE TABLE project (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, hours REAL);
            CREATE INDEX project_hours ON project (hours);
            """);
        let ins = sqlite::prepare(db, "INSERT INTO project (name, hours) VALUES (?, ?);  ");
        check::eq("parameters", sqlite::parameter_count(ins), 2);
        for name, i in ["alpha", "beta", "gamma"] {
            sqlite::bind_text(ins, 1, name);
            sqlite::bind_f64(ins, 2, 1.5 * (i + 1));
            check::that(str("insert ", name, " steps to done"), !sqlite::step(ins));
            check::eq(str(name, "'s rowid"), sqlite::last_insert_rowid(db), i + 1);
            check::eq("rows changed", sqlite::changes(db), 1);
            sqlite::reset(ins);
        }
        sqlite::finalize(ins);
        let q = sqlite::prepare(db, "SELECT id, name, hours FROM project WHERE hours >= :min ORDER BY hours DESC");
        sqlite::bind_f64(q, sqlite::parameter(q, ":min"), 3.0);
        var names: u8[>..] = [];
        for i in sqlite::column_count(q) {
            if i > 0 { names.append(", "); }
            sqlite::column_name(q, i, names);
        }
        check::text("columns", names, "id, name, hours");
        while sqlite::step(q) {
            var name: u8[>..] = [];
            sqlite::column_text(q, 1, name);
            print("row: ", sqlite::column_i64(q, 0), " ", name, " ", sqlite::column_f64(q, 2));
        }
        // A statement runs again from its first row after a reset, with its
        // bindings kept.
        sqlite::reset(q);
        var again = 0;
        while sqlite::step(q) { again++; }
        check::eq("rows after a reset", again, 2);
        sqlite::finalize(q);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
