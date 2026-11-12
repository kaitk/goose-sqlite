// busy_timeout: a connection that finds another holding the write lock waits
// up to its timeout and then fails with BUSY, or fails at once with 0. A
// timeout below 0, or past SQLite's int, isn't cut down to another one: -1
// fails at once, and 4294967297, which an int32 conversion makes 1, would
// wait about 24.8 days, so it isn't run here.
import std;
import os;
import sqlite from "../../";
import check from "../";

fn main() {
    let path = check::temp_db("busy");
    let failed = sqlite::run() {
        let a = sqlite::open(path);
        sqlite::exec(a, "PRAGMA journal_mode = WAL; CREATE TABLE t (n INTEGER)");
        let b = sqlite::open(path);
        sqlite::exec(a, "BEGIN IMMEDIATE");

        fn attempt(ms: i64) -> i32, i64 {
            sqlite::busy_timeout(b, ms);
            let start = clock_ns();
            var code: i32 = 0;
            let tried = sqlite::run() { sqlite::exec(b, "INSERT INTO t VALUES (1)"); };
            for e in tried { code = sqlite::primary(e.code); }
            return code, (clock_ns() - start) / 1000000;
        }
        let code0, ms0 = attempt(0);
        check::eq("timeout 0", code0, sqlite::BUSY);
        check::that("timeout 0 fails at once", ms0 < 20);
        let code_neg, ms_neg = attempt(-1);
        check::eq("timeout -1", code_neg, sqlite::BUSY);
        check::that("timeout -1 fails at once", ms_neg < 20);
        let code50, ms50 = attempt(50);
        check::eq("timeout 50", code50, sqlite::BUSY);
        check::that("timeout 50 waits 50 ms", ms50 >= 50);

        sqlite::exec(a, "COMMIT");
        let code_free, _ = attempt(50);
        check::eq("lock free", code_free, 0);
        check::that("closed a", sqlite::close(a));
        check::that("closed b", sqlite::close(b));
    };
    check::errors("run", failed);
}
