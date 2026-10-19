// One connection used by four threads at once, each with a statement of its
// own: the connection's mutex makes them take turns, so every insert lands.
// One connection per thread is still the layout to use; this checks only that
// sharing one doesn't corrupt it.
import std;
import sqlite from "../../";
import check from "../";

let THREADS = 4;
let ROWS = 2000;

struct Done { id: i64, code: i32 }

thread_fn writer(id: i64, db: sqlite::Db) {
    let failed = sqlite::run() {
        let s = sqlite::prepare(db, "INSERT INTO t (who, n) VALUES (?, ?)");
        for n in ROWS {
            sqlite::reset(s);
            sqlite::bind_i64(s, 1, id);
            sqlite::bind_i64(s, 2, n);
            sqlite::step(s);
        }
        sqlite::finalize(s);
    };
    var code: i32 = 0;
    for e in failed { code = e.code; }
    qput(Done { id: id, code: code });
}

fn main() {
    let failed = sqlite::run() {
        let db = sqlite::open(":memory:");
        sqlite::exec(db, "CREATE TABLE t (who INTEGER, n INTEGER)");
        var ids: i64[>..] = [];
        for i in THREADS { ids.push(thread_spawn(writer, i, db)); }
        var errors = 0;
        for i in THREADS { if qget<Done>().code != 0 { errors++; } }
        for id in ids { thread_wait(id); }
        check::eq("threads that failed", errors, 0);
        let s = sqlite::prepare(db, "SELECT count(*), count(DISTINCT who) FROM t");
        sqlite::step(s);
        check::eq("rows", sqlite::column_i64(s, 0), THREADS * ROWS);
        check::eq("writers", sqlite::column_i64(s, 1), THREADS);
        sqlite::finalize(s);
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
}
