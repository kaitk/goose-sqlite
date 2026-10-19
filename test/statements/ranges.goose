// Indexes and a timeout past what SQLite's int holds aren't cut down to fit:
// a bind fails with RANGE rather than bind another parameter, a column reads
// as NULL rather than as another column, and busy_timeout takes the most
// SQLite does.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let failed = sqlite::run() {
        let db = sqlite::open(":memory:");
        let s = sqlite::prepare(db, "SELECT ?, 'second'");
        // 4294967297 is 2^32 + 1, which an int32 conversion makes 1.
        check::errors("bind 4294967297", sqlite::run() { sqlite::bind_i64(s, 4294967297, 7); });
        check::errors("bind -1", sqlite::run() { sqlite::bind_text(s, -1, "x"); });
        sqlite::bind_i64(s, 1, 42);
        check::that("a row", sqlite::step(s));
        check::eq("column 0", sqlite::column_i64(s, 0), 42);
        // 4294967296 is 2^32, which an int32 conversion makes 0.
        check::eq("column 4294967296", sqlite::column_i64(s, 4294967296), 0);
        check::that("column 4294967296 is NULL", sqlite::is_null(s, 4294967296));
        check::that("column 4294967297 is NULL", sqlite::is_null(s, 4294967297));
        var text: u8[>..] = [];
        sqlite::column_text(s, 4294967297, text);
        check::text("column 4294967297 as text", text, "");
        var name: u8[>..] = [];
        sqlite::column_name(s, 4294967296, name);
        check::text("name of column 4294967296", name, "");
        sqlite::finalize(s);

        fn timeout() -> i64 {
            let q = sqlite::prepare(db, "PRAGMA busy_timeout");
            sqlite::step(q);
            let ms = sqlite::column_i64(q, 0);
            sqlite::finalize(q);
            return ms;
        }
        sqlite::busy_timeout(db, 4294967297);
        check::eq("busy_timeout 4294967297", timeout(), 2147483647);
        sqlite::busy_timeout(db, -4294967295);
        check::eq("busy_timeout -4294967295", timeout(), 0);
        sqlite::busy_timeout(db, 5000);
        check::eq("busy_timeout 5000", timeout(), 5000);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
}
