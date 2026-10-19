// A transaction outside sqlite::run doesn't compile: inside another, it can
// fail the enclosing block.
import sqlite from "../../";

fn main() {
    let db = sqlite::Db { id: 0 };
    let failed = sqlite::transaction(db) { };
}
// error: call to fail requires an enclosing call of run
