// Each bound type read back, with the type SQLite stored: integers at both
// ends of i64, reals, text with multi-byte UTF-8 and a NUL inside, blobs with
// every byte value, empty text and blobs, and NULL.
import std;
import sqlite from "../../";
import check from "../";

fn main() {
    let path = check::temp_db("types");
    var blob: u8[>..] = [];
    for i in 256 { blob.push(i as! u8); }
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        // No column affinity, so each value keeps the type it was bound as.
        sqlite::exec(db, "CREATE TABLE v (id INTEGER PRIMARY KEY, x)");
        let ins = sqlite::prepare(db, "INSERT INTO v (id, x) VALUES (?, ?)");
        var id = 0;
        fn next() {
            sqlite::reset(ins);
            id++;
            sqlite::bind_i64(ins, 1, id);
        }
        next(); sqlite::bind_i64(ins, 2, 9223372036854775807); sqlite::step(ins);
        next(); sqlite::bind_i64(ins, 2, -9223372036854775807 - 1); sqlite::step(ins);
        next(); sqlite::bind_f64(ins, 2, -0.125); sqlite::step(ins);
        next(); sqlite::bind_f64(ins, 2, 1.0e300); sqlite::step(ins);
        next(); sqlite::bind_text(ins, 2, "päev, 日"); sqlite::step(ins);
        next(); sqlite::bind_text(ins, 2, "a\0b"); sqlite::step(ins);
        next(); sqlite::bind_text(ins, 2, ""); sqlite::step(ins);
        next(); sqlite::bind_blob(ins, 2, blob); sqlite::step(ins);
        next(); sqlite::bind_blob(ins, 2, ""); sqlite::step(ins);
        next(); sqlite::bind_null(ins, 2); sqlite::step(ins);
        // clear_bindings sets every parameter to NULL, the id too.
        sqlite::reset(ins);
        sqlite::clear_bindings(ins);
        sqlite::step(ins);
        sqlite::finalize(ins);

        let q = sqlite::prepare(db, "SELECT id, typeof(x), x FROM v ORDER BY id");
        sqlite::step(q); check::eq("1 i64 max", sqlite::column_i64(q, 2), 9223372036854775807);
        check::eq("1 type", sqlite::column_type(q, 2), sqlite::INTEGER);
        sqlite::step(q); check::eq("2 i64 min", sqlite::column_i64(q, 2), -9223372036854775807 - 1);
        sqlite::step(q); check::that("3 f64 -0.125", sqlite::column_f64(q, 2) == -0.125);
        check::eq("3 type", sqlite::column_type(q, 2), sqlite::FLOAT);
        sqlite::step(q); check::that("4 f64 1e300", sqlite::column_f64(q, 2) == 1.0e300);
        sqlite::step(q);
        var t: u8[>..] = [];
        sqlite::column_text(q, 2, t);
        check::text("5 text", t, "päev, 日");
        check::eq("5 type", sqlite::column_type(q, 2), sqlite::TEXT);
        sqlite::step(q);
        t.clear();
        sqlite::column_text(q, 2, t);
        check::that("6 text with a NUL", t == "a\0b");
        sqlite::step(q);
        t.clear();
        sqlite::column_text(q, 2, t);
        check::eq("7 empty text's length", t.len, 0);
        check::eq("7 type", sqlite::column_type(q, 2), sqlite::TEXT);
        sqlite::step(q);
        var b: u8[>..] = [];
        sqlite::column_blob(q, 2, b);
        check::that("8 blob of bytes 0 to 255", b == blob);
        check::eq("8 type", sqlite::column_type(q, 2), sqlite::BLOB);
        sqlite::step(q);
        b.clear();
        sqlite::column_blob(q, 2, b);
        check::eq("9 empty blob's length", b.len, 0);
        check::eq("9 type", sqlite::column_type(q, 2), sqlite::BLOB);
        sqlite::step(q);
        check::that("10 null", sqlite::is_null(q, 2));
        // A NULL reads as 0 and as no bytes.
        check::eq("10 as i64", sqlite::column_i64(q, 2), 0);
        sqlite::column_text(q, 2, b);
        check::eq("10 as text's length", b.len, 0);
        sqlite::step(q);
        check::eq("11 cleared id", sqlite::column_i64(q, 0), 11);
        check::that("11 cleared x", sqlite::is_null(q, 2));
        // SQLite converts: an integer read as text and as a real.
        sqlite::reset(q);
        sqlite::step(q);
        t.clear();
        sqlite::column_text(q, 0, t);
        check::text("1 id as text", t, "1");
        check::that("1 id as f64", sqlite::column_f64(q, 0) == 1.0);
        var rows = 1;
        while sqlite::step(q) { rows++; }
        check::eq("rows", rows, 11);
        sqlite::finalize(q);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
