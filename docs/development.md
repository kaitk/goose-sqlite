# Development

The package is Goose over SQLite's C, which `goose build` compiles from the `.build`
sidecar, so it builds wherever the Goose compiler finds a C compiler. The tests have run
on macOS on arm64, and on Linux on arm64 and x64 in Docker (2026-10-19). They haven't
run on Windows.

## Toolchain

Use the Goose pin in [README.md](../README.md#pins). The scripts also need:

| Tool | Requirement | Purpose |
|---|---|---|
| C compiler | clang or gcc; on Windows, MSVC or `clang-cl` with Visual Studio Build Tools | `goose build` of SQLite and the shim, and of each test |
| Python | 3, with its standard library | `test/run_tests.py` |
| POSIX shell, git, curl, shasum or sha256sum | on `PATH`; Git Bash on Windows | `scripts/goose.sh` and `scripts/test.sh` |
| CMake | with Make or Ninja | building Goose from source, on Linux arm64 or for `GOOSE_COMMIT` |

## SQLite

`vendor/sqlite/` holds `sqlite3.c` and `sqlite3.h` from SQLite 3.54.1's amalgamation
(source id `2026-10-16 14:45:20 555e07ef33f6...`), unchanged.
`sqlite-amalgamation-3540100.zip`, 2,990,966 bytes, has the SHA3-256
`92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`, as
[SQLite's download page](https://sqlite.org/download.html) publishes it, and the SHA-256
`0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9`. The files from it:

| File | Bytes | SHA3-256 |
|---|---:|---|
| `sqlite3.c` | 9,582,521 | `e2b869d3003b33c942b7dd7063604fbc53553e1b66609570df39b9b7b558ee81` |
| `sqlite3.h` | 695,729 | `15ef3f5dbc4a7a980f828fa0d1e473cee5a124e7bb77e9bc70fc0bfa3f9a2af8` |

`.gitattributes` keeps git from changing their line endings, so a checkout on any
platform has these bytes. The compile-time options are in `sqlite.build`, each with its
reason in [decisions](decisions.md). `goose build` compiles them once per C compiler
and keeps the result under `GOOSE_HOME`; the first build of a program that imports the
package takes 10 s or more for it ([results](results.md#build-times)).

### Move the SQLite pin

At the start of a session, check [the download page](https://sqlite.org/download.html)
for a newer release. To move to it, in its own commit:

1. Download `sqlite-amalgamation-<version>.zip` into an empty directory, and check its
   SHA3-256 against the page's:
   `python3 -I -c "import hashlib, sys; print(hashlib.sha3_256(open(sys.argv[1], 'rb').read()).hexdigest())" <zip>`.
2. Copy its `sqlite3.c` and `sqlite3.h` over `vendor/sqlite/`'s; leave out `shell.c`
   and `sqlite3ext.h`.
3. Check the release notes for changes to the options in `sqlite.build` and to the
   [recommended options](https://sqlite.org/compile.html#rcmd).
4. Run `scripts/test.sh`, and update the version and checksums on this page, in
   [README.md](../README.md#pins), and in [decisions](decisions.md).

## Set up the Goose compiler

The scripts use the Goose release pinned in `scripts/goose.sh` (`v2026.2`, 2026-10-16)
unless told otherwise. The first script that needs the compiler downloads the release's
archive for the platform from
[the releases page](https://github.com/aardappel/goose/releases), checks its SHA-256,
and unpacks it into `build/goose-v2026.2-<platform>/`; later runs reuse it. Run
`scripts/goose.sh` to fetch it and print the compiler's path. The release needs the Xcode
command line tools on macOS and the C library's headers on Linux
([Goose's README](https://github.com/aardappel/goose#install-a-release)). Linux on arm64
has no release archive, so there the script builds the release's tag from source, as
`GOOSE_COMMIT` does below.

Use another compiler only when the release can't do the job, such as a Goose fix not
yet released. Two settings choose one, and the first set wins:

| Setting | Compiler |
|---|---|
| `GOOSE` | The binary it names, such as a checkout's build or a release unpacked elsewhere. |
| `GOOSE_COMMIT` | That commit of `aardappel/goose`, cloned into `build/goose-<commit>/` and built with CMake (and Ninja if installed) on first use. Give the full 40-hex hash; a shallow fetch can't resolve an abbreviated one. |

The `.build` sidecar has `exclude = ["build"]`, as goose-http's has: Goose collects a
package's JIT symbol table from every `.goose` file under its root, and the release's
stdlib under `build/` declares the runtime's `extern fn`s.

To build a checkout by hand, clone it anywhere and point `GOOSE` at its build. Don't edit
it (`AGENTS.md`):

```sh
git clone -o upstream https://github.com/aardappel/goose.git ../goose
cmake -S ../goose -B ../goose/build-macos -DCMAKE_BUILD_TYPE=Release
cmake --build ../goose/build-macos -j
export GOOSE=$PWD/../goose/build-macos/goose
```

On Linux, name the build directory `build-linux`.

### Move the pin

The pin is a Goose release. At the start of a session, check for a newer one:

```sh
gh release list -R aardappel/goose --limit 3
```

To move to a new release, update `goose_release` and the four archives' SHA-256 sums in
`scripts/goose.sh`. GitHub lists each asset's digest:

```sh
gh api repos/aardappel/goose/releases/tags/<tag> -q '.assets[] | "\(.name) \(.digest)"'
```

Then run `scripts/test.sh`, and update the pin in `README.md` and this page's release
paths, in its own commit. Packages imported by the same program must use a compatible
Goose pin, since the program builds with one compiler.

Pin a commit only when a Goose fix that this repository needs isn't in a release yet:
set `GOOSE_COMMIT` in the scripts' environment, record the commit in the README's Pins
table with the reason, and return to a release once one includes the fix.

## Test

`scripts/test.sh` runs everything, and stops at the first step that fails:

1. `goose check` of `sqlite.goose` alone, and of each root file under `test/`.
2. `test/run_tests.py`: the tests under `test/<area>/` ([Run the tests](#run-the-tests)).
   `test/statements/` checks a schema created and queried, with numbered and named
   parameters and a reset; each bound type read back with the type SQLite stored
   (`i64` at both ends, reals, UTF-8 text, text holding a NUL, blobs of every byte
   value, empty text and blobs, and NULL); and the errors each call fails with, after
   each of which the connection still works; foreign keys enforced by default and
   not when `open` turns them off; and parameter and column indexes and a
   `busy_timeout` past a 32-bit `int`, which fail with `RANGE`, read as NULL, and
   clamp rather than wrap. `test/transactions/` checks that a
   transaction commits, rolls back when a call in it fails or it calls `fail`, and
   nests as savepoints: three deep, inside an `exec`'s `BEGIN`, an inner failure
   undoing only its own rows, an outer failure undoing the inner ones, a statement
   left open across `ROLLBACK TO`, and an error after which SQLite ends the whole
   transaction, which stops the outer block. `test/threads/` runs one writer and
   two read-only WAL readers, each on its own thread with its own connection: the
   writer commits while both readers hold read transactions, and each reader sees
   its snapshot until its transaction ends. `test/compile/` holds the fixtures that
   must not compile: a call that can fail, and a transaction, outside `run`.

```sh
scripts/test.sh
```

`GOOSE`, `GOOSE_COMMIT`, and `CC` pass through to `test/run_tests.py`. It took 2 s on
the M1 Pro with SQLite already built, and 21 s on Linux arm64 in Docker, where the first
build compiled it (2026-10-19).

### Run the tests

Each test is a program, `test/<area>/<name>.goose`, that prints what it checks and
asserts it; `test/expected/<name>.out` holds what it must print. The shared helpers are
`test/check.goose`, which a test imports with `import check from "../";`. A test writes
its database to the system's temporary directory (`TMPDIR`, `TEMP`, or `/tmp`), under a
name of its own, and removes it and its `-wal`, `-shm`, and `-journal` files. Names are
unique across areas, since `test/expected/` is one directory. `test/run_tests.py` is
Python 3 with its standard library alone:

```sh
python3 test/run_tests.py                 # every test
python3 test/run_tests.py statements      # one area
python3 test/run_tests.py types           # one test; names and areas can be mixed
python3 test/run_tests.py -O0 threads     # one level only
python3 test/run_tests.py --bless types   # rewrite test/expected/types.out from its output
```

Every test links the package's C, so the runner builds each with `goose build`, at
`-O0` and at `-O2`, into `build/test/`, as Goose's own runner builds a fixture with C
of its own, and runs each as a process of its own, in parallel (`-j N`). The first
build runs alone: it compiles SQLite when `GOOSE_HOME` has no build of it for this C
compiler, and the rest reuse it. A run passes when its stdout is the `.out` file, and
it exits 0. Where `test/expected/<name>.aborts` exists, the run must exit nonzero
instead, and each nonblank line of `test/expected/<name>.stderr` must occur in its
stderr. A file with `// error: <message>` lines is a fixture that must not compile:
`goose --check` must exit 1, with each message in its diagnostics, checked in batches
with `goose --multi-test`. The runner reports every failure, with a diff for a changed
output, then a count per area, and exits 1 if any test failed; `-v` lists the passes
too.

After a change that alters what a test prints, run it with `--bless`, and read the diff
of `test/expected/` before committing it: blessing writes whatever the program printed
at the first level it ran, provided it exited as expected.

### Linux in Docker

On a machine with Docker, the tests run in a Debian container with the repository
mounted read-only and copied in, so the container's `build/` stays apart from the
host's. On arm64 this builds Goose from source first:

```sh
docker run --rm -v "$PWD":/repo:ro debian:trixie-slim sh -c '
  apt-get update -qq && apt-get install -y -qq gcc g++ make cmake ninja-build python3 \
    git curl ca-certificates >/dev/null &&
  mkdir /work && cd /repo && tar --exclude=./build --exclude=./.git -cf - . |
  (cd /work && tar -xf -) && cd /work && sh scripts/test.sh'
```

For Linux x64 on an arm64 host, add `--platform linux/amd64` and use the `python:3.12`
image, which has gcc, git, and curl: the release's `linux-x64` archive then runs under
emulation. There the tests took 37 s, SQLite's build included (2026-10-19).

## Traps

- Each package function that can fail has an untyped parameter, such as `step(s)`. A
  fully typed one is checked by `goose check sqlite.goose` as a function of its own,
  with no `run` around it, and rejected: "return from run: no enclosing call of run
  on this compile-time call path". A generic one is checked only where a program
  calls it ([findings](goose-findings.md#goose-check-of-a-library-rejects-a-typed-function-that-can-fail)).
- `NOTHING` is an SQL keyword (`ON CONFLICT DO NOTHING`), so `SELECT * FROM nothing`
  is a syntax error, not "no such table".
