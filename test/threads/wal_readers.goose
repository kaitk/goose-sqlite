// One writer and two read-only WAL readers, each a connection of its own
// thread's: each reader opens a read transaction and counts the rows, the
// writer commits more while both hold theirs, and each reader still counts
// its snapshot's rows, then the new ones once its transaction ends.
import std;
import sqlite from "../../";
import check from "../";

let READERS = 2;

// What a reader counted, at step 1 and 2 inside its read transaction and
// step 3 after it.
struct Seen { reader: i64, step: i64, rows: i64, code: i32 }

// The writer has committed: a reader may read again.
struct Go { n: i64 }

fn count(db: sqlite::Db) -> i64 {
    let s = sqlite::prepare(db, "SELECT count(*) FROM t");
    sqlite::step(s);
    let n = sqlite::column_i64(s, 0);
    sqlite::finalize(s);
    return n;
}

thread_fn reader(id: i64, path: u8[]) {
    var step = 0;
    let failed = sqlite::run() {
        let db = sqlite::open(path, sqlite::READ_ONLY);
        sqlite::busy_timeout(db, 5000);
        let failed = sqlite::transaction(db) {
            step = 1;
            qput(Seen { reader: id, step: 1, rows: count(db), code: 0 });
            qget<Go>();
            step = 2;
            qput(Seen { reader: id, step: 2, rows: count(db), code: 0 });
        };
        for e in failed { sqlite::fail(e.code, e.message); }
        step = 3;
        qput(Seen { reader: id, step: 3, rows: count(db), code: 0 });
        sqlite::close(db);
    };
    for e in failed { qput(Seen { reader: id, step: step, rows: -1, code: e.code }); }
}

fn main() {
    let path = check::temp_db("wal_readers");
    let failed = sqlite::run() {
        let db = sqlite::open(path);
        var mode: u8[>..] = [];
        let s = sqlite::prepare(db, "PRAGMA journal_mode = WAL");
        sqlite::step(s);
        sqlite::column_text(s, 0, mode);
        sqlite::finalize(s);
        check::text("journal mode", mode, "wal");
        sqlite::exec(db, "CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1)");

        var ids: i64[>..] = [];
        for r in READERS { ids.push(thread_spawn(reader, r, str(path))); }
        var seen: Seen[>..] = [];
        for i in READERS { seen.push(qget<Seen>()); }
        // Both readers hold a snapshot of one row; a WAL writer doesn't wait
        // for them.
        let errs = sqlite::transaction(db) {
            for n in 10 { sqlite::exec(db, str("INSERT INTO t VALUES (", n + 2, ")")); }
        };
        check::errors("write while both read", errs);
        check::eq("rows the writer sees", count(db), 11);
        for i in READERS { qput(Go { n: i }); }
        for i in 2 * READERS { seen.push(qget<Seen>()); }
        for id in ids { thread_wait(id); }
        sort(seen) { a, b => a.reader * 10 + a.step < b.reader * 10 + b.step };
        for x in seen {
            print("reader ", x.reader, ", step ", x.step, ": ", x.rows, " rows",
                  if x.code != 0 { str(", error ", x.code, ": FAILED") } else { str("") });
            assert(x.code == 0);
        }
        check::that("closed", sqlite::close(db));
    };
    check::errors("run", failed);
    check::remove_db(path);
}
