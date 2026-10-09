# TreeIOHDF5.jl — Plan

**Contents**

- [Release 0.1.0](#release-010)

## Release 0.1.0

1. **Register.** TreeAMR 0.2.0 is registered, and the repository
   exists; what is left is its Codecov token and its `DOCUMENTER_KEY`,
   then tag and register 0.1.0 with `[compat] TreeAMR = "=0.2.0"`. *Done when* CI is
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
