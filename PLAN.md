# TreeIOHDF5.jl — Plan

**Contents**

- [Release 0.1.0](#release-010)
- [Release 0.1.1](#release-011)
- [Release 0.1.2](#release-012)
- [Release 0.1.3](#release-013)

## Release 0.1.0

1. **Register.** TreeAMR 0.2.1 is registered, and the repository
   exists with its Codecov token; what is left is its `DOCUMENTER_KEY`,
   then tag and register 0.1.0 with `[compat] TreeAMR = "=0.2.1"` (alone:
   the outflow faces use names 0.2.1 added). *Done when* CI is
   green on GitHub and the package resolves from General.
2. **The downstreams.** Neither is changed yet; each needs, on a branch
   of its own, and then a release:
   - **TreeHydro**: its `src/` calls the functions, so TreeIOHDF5 goes
     in `[deps]` and `using TreeIOHDF5` beside `using TreeAMR` in
     `src/TreeHydro.jl`; then `checkpointing_available()`
     (`src/checkpoint.jl:55`) is always true and the "run `using HDF5`"
     refusal (`src/checkpoint.jl:536–544`) and its test
     (`test/checkpoint_tests.jl:42–60`) go; TreeIOHDF5 in
     `test/Project.toml` and `using TreeIOHDF5` in
     `test/checkpoint_tests.jl` and `test/restart_workload.jl`, which call
     the functions from `Main`; `showcase/` the same; `[compat] TreeAMR =
     "0.2"`. Checked on 2026-10-08 in a scratch copy with exactly these
     edits, developing both checkouts: 12444 tests pass in 6m29 (12447
     before, less the refusal's three).
   - **TreeGeneralizedHarmonic**: TreeIOHDF5 in `[deps]` beside or in
     place of its hard HDF5 dependency (`src/TreeGeneralizedHarmonic.jl:52–55`),
     `using TreeIOHDF5` where `src/checkpoint.jl` calls the functions;
     `test/prerequisite_tests.jl:224` takes `save_checkpoint` and
     `load_checkpoint` from TreeIOHDF5, and `:287` checks that TreeIOHDF5
     is loaded instead of `TreeAMRHDF5Ext`; its tests that call the
     functions from `Main` need `using TreeIOHDF5`, as TreeHydro's do;
     `[compat] TreeAMR = "0.2"`. Not checked: its suite takes about 19
     minutes, and its prerequisite test fails by design until edited.
   - **TreeWave**: only `[compat] TreeAMR = "0.1.0, 0.2"`. Checked on
     2026-10-08 in a scratch copy developing TreeAMR's checkout: 310
     tests pass.

   *Done when* each downstream's suite passes against the registered
   releases.

## Release 0.1.1

Done: symmetric walls, for TreeAMR 0.2.2 (`CODE.md`, "Checkpoint and
restart"); 850 tests pass against the registered TreeAMR 0.2.2.

## Release 0.1.2

Done: the Julia floor of 1.13, for TreeAMR 0.2.2 and 0.2.3 (`HISTORY.md`,
"The Julia floor"); 850 tests pass against the registered TreeAMR 0.2.3.

## Release 0.1.3

The half-turn seam, for TreeAMR 0.2.4 (TreeAMR's M13; `CODE.md`,
"Rotating forests"): the forest's `halfturn` pair under a feature of its
own and each field set's `halfturn` map. 889 tests pass against the
TreeAMR checkout of 0.2.4. *Done when* TreeAMR 0.2.4 is registered, the
suite passes against it, and 0.1.3 is tagged and registered with
`=0.2.4` in its `[compat]`.
