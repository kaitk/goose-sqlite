// Foreign keys are enforced by default, and not when a connection is opened
// with foreign_keys false.
import std;
import sqlite from "../../";
import check from "../";

fn setting(db: sqlite::Db) -> i64 {
    let s = sqlite::prepare(db, "PRAGMA foreign_keys");
    sqlite::step(s);
    let on = sqlite::column_i64(s, 0);
    sqlite::finalize(s);
    return on;
}

fn main() {
    let path = check::temp_db("foreign_keys");
    check::errors("schema", sqlite::run() {
        let db = sqlite::open(path);
        sqlite::exec(db, """
            CREATE TABLE project (id INTEGER PRIMARY KEY);
            CREATE TABLE entry (id INTEGER PRIMARY KEY, project INTEGER REFERENCES project (id));
            INSERT INTO project VALUES (1);
            """);
        check::eq("by default, foreign_keys", setting(db), 1);
        check::errors("an entry for project 1", sqlite::run() {
            sqlite::exec(db, "INSERT INTO entry (project) VALUES (1)");
        });
        check::errors("an entry for project 2", sqlite::run() {
            sqlite::exec(db, "INSERT INTO entry (project) VALUES (2)");
        });
        check::that("closed", sqlite::close(db));
    });
    check::errors("off", sqlite::run() {
        let db = sqlite::open(path, sqlite::READ_WRITE, false);
        check::eq("with foreign_keys false, foreign_keys", setting(db), 0);
        check::errors("an entry for project 2", sqlite::run() {
            sqlite::exec(db, "INSERT INTO entry (project) VALUES (2)");
        });
        check::that("closed", sqlite::close(db));
    });
    check::remove_db(path);
}
