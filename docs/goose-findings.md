# Goose findings

Gaps, bugs, and surprises in the pinned Goose compiler and stdlib, found while building
this package. Each entry has a minimal program that shows it, the Goose commit it was
found on, the workaround used here, and whether it has been reported upstream.

The entries come in two parts: [bugs](#bugs), where Goose does something wrong or other
than its spec says, then [feature requests](#feature-requests), for what it lacks. Each
part runs from the least work a fix is expected to take to the most, so the cheap fixes
come first. The order is an estimate from reading the compiler. Place a new entry where
its expected work puts it, and delete an entry once the pin has its fix: git keeps it.

## Bugs

None yet.

## Feature requests

### `goose check` of a library rejects a typed function that can fail

Found on `3ee3871` (`v2026.2`), task 001. Status: open; not reported

`goose check lib.goose` checks each fully typed function of a library module as if a
program called it with nothing around it, so a function that reaches
`return ... from run` fails the check: "return from run: no enclosing call of run on
this compile-time call path". In a program, the same function compiles wherever its
calls lie inside `run`, so the error is about a call path no program has. A generic
function is checked only where it's called, and passes. Expected: `goose check` of a
module with no `main` checks the rule only on the paths its own code calls, so a
library can type its parameters and still be checked on its own.

    namespace lib;

    fn run<F>() -> i64 { F(); return 0; }
    fn fail() { return 1 from run; }

    fn checked(x) { if x < 0 { fail(); } }        // passes goose check
    fn rejected(x: i64) { if x < 0 { fail(); } }  // fails goose check

Without `rejected`, `goose check lib.goose` passes; a program that calls
`lib::rejected(-1)` inside `lib::run() { ... }` compiles and runs.

Workaround: each function in `sqlite.goose` that can fail keeps one untyped parameter,
such as `step(s)` ([development](development.md#traps)).
