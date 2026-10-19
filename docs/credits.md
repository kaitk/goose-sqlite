# Credits

goose-sqlite carries one work of others, SQLite, and follows two others' designs. This
page names what it takes from each.

## SQLite

`vendor/sqlite/sqlite3.c` and `sqlite3.h` are SQLite's amalgamation, as
[sqlite.org](https://sqlite.org/) publishes it, unchanged; the version and checksums are
in [development](development.md#sqlite). SQLite is in the
[public domain](https://sqlite.org/copyright.html). The shim in `shim/sqlite.c` is
written against SQLite's [C interface](https://sqlite.org/c3ref/intro.html), and the
compile-time options follow SQLite's
[recommended set](https://sqlite.org/compile.html#rcmd), with the departures that
[decisions](decisions.md) gives.

## rusqlite

Building SQLite from its amalgamation inside the package, so a program needs no
system library, follows [rusqlite](https://github.com/rusqlite/rusqlite)'s `bundled`
feature. No code is taken from it.

## Goose's standard library

`sqlite::run` and `sqlite::fail` are the pattern of the `exception` module in Goose's
standard library, `try` and `throw` over `return ... from`, typed to `sqlite::Error`.
