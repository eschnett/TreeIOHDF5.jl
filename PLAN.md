# TreeIOHDF5.jl — Plan

**Contents**

- [Release 0.1.0](#release-010)
- [Release 0.1.1](#release-011)
- [Release 0.1.2](#release-012)
- [Release 0.1.3](#release-013)
- [Release 0.1.4](#release-014)
- [Release 0.1.5](#release-015)
- [Release 0.1.6](#release-016)
- [Forests of patches](#forests-of-patches)

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

Done: compat only, for TreeAMR 0.2.4, the cheaper ghost fill on nested
meshes, which leaves the companion interface unchanged; 850 tests pass
against the registered TreeAMR 0.2.4.

## Release 0.1.4

Done: the half-turn seam, for TreeAMR 0.2.5 (TreeAMR's M14; `CODE.md`,
"Rotating forests"): the forest's `halfturn` pair under a feature of its
own and each field set's `halfturn` map; tagged and registered with
`=0.2.5` in its `[compat]`.

## Release 0.1.5

Done: compat only, for TreeAMR 0.2.6, the folds over points
(`mesh_fold`, `block_fold`), which leave the companion interface
unchanged; 889 tests pass against the registered TreeAMR 0.2.6.

## Release 0.1.6

Element sets, for TreeAMR 0.2.7 (TreeAMR's M16; `CODE.md`, "Element
sets" under "Checkpoint and restart"): a set's order `P` as an attribute,
under the feature `elements`. `[compat] TreeAMR = "=0.2.7"` alone, since
the save reads `FieldSet`'s new field `P`. 974 tests pass against the
registered TreeAMR 0.2.7, and the docs build with their doctest.

1. Tag and register 0.1.6. *Done when* CI is green on GitHub and the
   package resolves from General.

## Forests of patches

For TreeAMR's M17 (`CODE.md`, "Forests of patches" under "Checkpoint
and restart"): a forest of patches saved as its patches and glue table,
under the feature `patches` in place of `brick`, with no format bump.
Implemented on the branch `eschnett-claude/multi-patch`, which starts
from 0.1.6's and takes TreeAMR through `[sources]` from the checkout
beside this one (`../TreeAMR`, branch `eschnett-claude/multi-patch`,
still versioned 0.2.7); 1088 tests pass against it at one thread.

1. Once TreeAMR releases M17, replace the `[sources]` path entries in
   `Project.toml`, `test/Project.toml` and `docs/Project.toml` by that
   release (by its PR branch until it is registered, then by nothing),
   set `[compat] TreeAMR` to that version alone — the save calls
   `patch_keywords`, which 0.2.7 does not have — and the package
   version to the next patch release; run the suite and the docs build
   against it. *Done when* it is tagged and registered after 0.1.6, and
   CI is green on GitHub.
