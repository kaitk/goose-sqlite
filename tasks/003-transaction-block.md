# 003: The transaction block, as goose-postgres's

Status: todo (2026-10-19). Settled together with goose-postgres's task 004.

goose-rest runs a use case with several queries, and business rules between them, as
one job on a lane, in one transaction (goose-rest's task 052). Its repository functions
take the transaction as their last parameter, as TypeScript libraries do, and the
compiler should check that they run inside one. goose-postgres gets that block in its
task 004; this package takes the same one where its API allows, so a program's data
access reads the same on either database.

`sqlite::transaction(db) { ... }` does most of it already: it runs `BEGIN`, the block,
and `COMMIT`, and rolls back and returns the error when a call fails or the block calls
`fail`. What it lacks against goose-postgres's design:

- **A value from the block.** The block's value is discarded, so a block writes what
  it builds into the caller's variables. A spike on Goose `v2026.2` (goose-postgres's
  task 004) shows the form that compiles: `let order, err =
  sqlite::transaction<Order>(db) { tx => ... order };` returning `T, Error[]`, for a
  fixed-size `T` the call names. A non-fixed value still goes into the caller's
  variables, since `default<T>()` takes only a fixed-size type and Goose can't name
  a block's result type before calling it.
- **A transaction value.** The block gets no parameter, so a repository function takes
  the `Db` and can be called outside a transaction. A `sqlite::Tx` handed to the block,
  `{ tx => ... }`, lets such a function take `tx: sqlite::Tx`, which only a
  transaction gives out.
- **`fail` only inside a transaction.** `fail` returns from `run`, which `transaction`
  also calls, so it compiles inside a plain `run` too. A `fail(tx, ...)` that returns
  from a catcher only `transaction` calls compiles only inside one; the spike shows
  the compiler rejecting it elsewhere. Calls that fail keep returning from `run`'s
  catcher, so they work in both.

## Steps

1. Agree the forms with goose-postgres's task 004, and record them in
   `docs/decisions.md`: the overloads with and without a value, `Tx`, and what happens
   to the current block form. A transaction inside another becomes a savepoint in both
   packages (agreed 2026-10-19, as Drizzle and other ORMs do): `SAVEPOINT`, then
   `RELEASE` on success or `ROLLBACK TO` on failure, where today the inner `BEGIN`
   fails.
2. The block, keeping the untyped parameter on each function that can fail
   (`docs/goose-findings.md`).
3. Tests: a block that returns a value and commits; one that fails at depth through a
   function taking `tx`; and `// error:` fixtures for `fail(tx, ...)` outside a
   transaction and a `Db` passed where a `Tx` is asked.
4. `docs/architecture.md` and `README.md`.

## Acceptance criteria

- [ ] The forms recorded in `docs/decisions.md` and `docs/architecture.md`, the same as
      goose-postgres's or with each difference named
- [ ] A transaction that returns a value, and one that rolls back from a function
      taking `tx`, with tests
- [ ] `fail` outside a transaction doesn't compile, with a fixture
- [ ] `scripts/test.sh` passes
