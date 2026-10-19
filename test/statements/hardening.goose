// open turns on SQLite's defensive mode and turns off trusted_schema, so SQL
// can't corrupt the database file on purpose, and a schema from elsewhere
// can't run functions with side effects.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let path = check::temp_db("hardening");
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        fn pragma(name: const u8[:]) -> i64 {
            let s = sqlite::prepare(db, str("PRAGMA ", name));
            sqlite::step(s);
            let v = sqlite::column_i64(s, 0);
            sqlite::finalize(s);
            return v;
        }
        check::eq("trusted_schema", pragma("trusted_schema"), 0);
        sqlite::exec(db, "CREATE TABLE t (n INTEGER)");
        // Defensive mode ignores writable_schema = ON.
        sqlite::exec(db, "PRAGMA writable_schema = ON");
        check::eq("writable_schema after ON", pragma("writable_schema"), 0);
        check::errors("delete from sqlite_schema", sqlite::run() {
            sqlite::exec(db, "DELETE FROM sqlite_schema");
        });
        // And schema_version = N, which would make other connections misread
        // the schema.
        let version = pragma("schema_version");
        sqlite::exec(db, str("PRAGMA schema_version = ", version + 100));
        check::that("schema_version unchanged", pragma("schema_version") == version);
        let s = sqlite::prepare(db, "SELECT count(*) FROM sqlite_schema");
        sqlite::step(s);
        check::eq("tables left", sqlite::column_i64(s, 0), 1);
        sqlite::finalize(s);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
