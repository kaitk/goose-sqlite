# goose-sqlite

SQLite for [Goose](https://github.com/aardappel/goose): a Goose API over SQLite's C
library, built from the SQLite amalgamation that this repository carries, so a program
needs no system SQLite. Its first user is
[goose-rest](https://github.com/kaitk/goose-rest), whose programs run the database on
lanes, threads of their own.

Nothing is built yet. The plan is in [tasks](tasks/README.md), and the choices so far
are in [decisions](docs/decisions.md).

## Status

🟢 works · 🟡 partial or next · 🔴 not yet

| | Feature | Notes |
|---|---|---|
| 🟡 | Connections | Open a file read-write or read-only, with pragmas such as `journal_mode = WAL`. |
| 🟡 | Statements | Prepare, bind, step, read columns, reset, and finalize. |
| 🟡 | Transactions | `BEGIN`, `COMMIT`, and `ROLLBACK`, with the error that ended one. |
| 🔴 | Migrations | Numbered SQL files applied in order, once each. |

## Pins

The Goose release in `scripts/goose.sh` (`v2026.2`). The SQLite version is the
amalgamation's, in [development](docs/development.md).
