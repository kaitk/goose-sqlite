# Decisions

The record of goose-sqlite's design decisions, for contributors and agents: each dated,
with its reason and the trade-off that matters.

## Settled

- **Bindings, not SQLite in Goose.** SQLite is about 250,000 lines of C, and its file
  format and query planner are not what measuring Goose is about (2026-10-19).
- **SQLite before Postgres.** It needs no network code, so it waits on nothing in
  goose-http, and goose-rest needs a database for its examples and best practices
  (goose-rest's task 035). snowtime-native, which a Goose port would replace, already
  runs on SQLite (2026-10-19).
- **Synchronous, one connection per thread.** SQLite's calls block, so a goose-rest
  program runs them on a lane, never on a worker. snowtime-native's layout fits that: one
  writer thread, and read-only WAL connections each owned by one reader thread
  (`crates/server/src/connections.rs`) (2026-10-19).

## Proposed

- **The amalgamation in the repository, built from the `.build` sidecar.** Every
  platform then builds the same SQLite version with the same compile-time options, with
  no system library: macOS's is old, Windows has none, and Linux needs a `-dev` package.
  rusqlite's `bundled` feature, which snowtime-native uses, does the same. The cost is
  one large C file, compiled into each program that imports the package.

## Open

- Whether `goose build` compiles `sqlite3.c` (about 9 MB) in acceptable time with each
  platform's C compiler, and whether the sidecar can pass SQLite's `-D` options.
