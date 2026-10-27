# Agent rules

This file holds what every session needs. `agents/` holds the rules for particular work:
read the file a task touches before starting it.

## Project context

- What this is, its API, and its pin: `README.md`
- How it works, for users: `docs/architecture.md`; the decisions, each dated with its
  reason and trade-off: `docs/decisions.md`. A new decision goes in `docs/decisions.md`,
  and `docs/architecture.md` changes with it where it describes what changed
- Toolchain, local setup, the SQLite pin, and tests: `docs/development.md`
- Goose compiler and stdlib gaps found here: `docs/goose-findings.md`
- Measurements, such as build times: `docs/results.md` (each machine's latest run) and
  `docs/results-history.md` (earlier runs)
- What the package takes from others' work, SQLite's amalgamation first:
  `docs/credits.md`
- Task tracking: `tasks/` (see `tasks/README.md`)
- The library: SQLite's C interface (`sqlite.org/c3ref`), for the amalgamation's version
  in `docs/development.md`.
- Its first user: Plod, whose programs run the database on lanes.
- The language: the pinned Goose release's `docs/tutorial.md`, `docs/goose_spec.md`,
  `docs/stdlib.md`, and `docs/packages.md` (C sources in a `.build` sidecar). Read the
  tutorial before writing Goose; check the spec before assuming a feature exists.
- Rules for particular work: `agents/goose.md` (writing Goose, and recording what it
  lacks), and `agents/writing.md` (docs, tasks, and prose reviews)

Follow the recorded decisions; if a change contradicts one, update the doc in the same
change or ask first. Record setup facts and environment traps you find (paths, shell
quirks, compilers) in `docs/development.md`, not in agent memory, so the next agent
finds them. Every measurement, such as a build time, goes in `docs/results.md` with how
it was measured: machine, OS, compiler, command, and run count. Docs and commits don't credit a
decision or a request to a person, as in "Kait asked": date it (`(2026-10-19)`). A
name goes only where one belongs, such as a copyright line or another project's
author. Describe the setup without anyone's machine,
checkouts, or home directory. What only one machine needs, such as where its Goose
checkout is, goes in `CLAUDE.local.md`, which git ignores. Benchmark results still name
their machine.

## Keep changes small

Agreed 2026-10-20.

- Meet the requirement's intent with the least machinery. Before building around an
  obstacle, ask whether the requirement needs it at all.
- When a fix starts to need a new public API, a change in another repository, or a
  workaround, stop. Say so in a sentence or two, and propose the simpler reading of the
  requirement.
- A feature's cost falls on the programs that use it: no fields in shared structs and no
  code on shared paths for one feature.
- When a design makes other code compensate (a fallback, a rescan, a special case
  elsewhere), change the design rather than add the compensation.
- Add a setting, a check, or a script option only for a failure that isn't visible
  already.

## Working beside other agents

Several agents work in these repositories at once (2026-10-20).

- Work in a worktree of your own, on a branch from `origin/main`:
  `git worktree add ../<repository>-<topic> -b <topic> origin/main`. Remove it once
  the branch is merged.
- Leave alone a branch, a commit, or an uncommitted change that isn't yours, in any
  checkout. Ask if it's in your way.
- Keep logs, exports, and scratch files in a directory of your own.
- Problems with your own sandbox, such as no network or no SSH, go in your report,
  not in the docs.

## Goose

- Build with the official Goose release that `scripts/goose.sh` pins. Check for a newer
  release at the start of a session and move the pin to it. Pin a commit
  (`GOOSE_COMMIT`) only when a fix this repository needs isn't released yet, and return
  to a release once one has it (2026-10-15).
- Don't edit a Goose checkout. Work around a compiler or stdlib gap here, record it in
  `docs/goose-findings.md` as `agents/goose.md` says, and report blockers to the
  maintainer.

## C, and only for SQLite

- SQLite's amalgamation is vendored as SQLite publishes it. Don't edit it; its version
  and compile-time options go in `docs/decisions.md` and `docs/development.md`.
- The C in `shim/` only adapts SQLite's API to Goose: opaque handles, bytes in and
  bytes out, and error codes. Anything that doesn't need SQLite's types, such as
  migrations and the transaction helper, is Goose.
- SQLite's calls block. The package starts no threads and never assumes it runs on a
  worker; a connection belongs to one thread.

## Code conventions

- Comment only where the code is hard to follow without it, and say only what a reader
  of that code needs: why, a constraint, or a contract the code can't show. Don't restate
  the next line, and don't describe earlier versions or the task that added the code;
  history belongs in git.
- Edit files with the Edit tool, not with `sed` or a Python or PowerShell script. On
  Windows, line endings differ by file type and a shell adds a layer of escaping, and
  scripted edits break on both.
- Tests follow Goose's own convention: a top-level `test/` by area, each test a small
  program whose printed output a golden file in `test/expected/` checks, `// error:`
  fixtures for code that must not compile, and a runner that batches them with
  `goose --multi-test`. A test writes its database to a temporary file and removes it.

## Commits

- One lean sentence in imperative mood, at most 72 characters.
- No body, no `Co-Authored-By` or any other trailers.
- Fetch and rebase before pushing a finished commit to `origin`.
