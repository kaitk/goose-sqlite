// A call that can fail, outside sqlite::run or a transaction, doesn't compile.
import sqlite from "../../";

fn main() {
    let db = sqlite::open(":memory:");
    sqlite::close(db);
}
// error: return from run: no enclosing call of run on this compile-time call path
