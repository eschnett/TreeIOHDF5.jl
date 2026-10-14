# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Contents**

- [Read first, and where things go](#read-first-and-where-things-go)
- [Commands](#commands)
- [Rules and sharp edges](#rules-and-sharp-edges)
- [Repository facts](#repository-facts)

## Read first, and where things go

TreeIOHDF5 is checkpoint and restart for TreeAMR meshes through HDF5, a
**companion package** of TreeAMR (`~/src/jl/TreeAMR`): it uses TreeAMR's
internals, listed in TreeAMR's `CODE.md`, "Companion interface", and so
accepts only the TreeAMR versions it was tested against. Read `CODE.md`
before changing anything non-trivial. The markdown files follow
TreeAMR's map:

- `README.md` — for users: what it does, an example, the status.
- `CLAUDE.md` — this file: commands, rules, repository facts. Keep it
  short.
- `CODE.md` — the current design and the reasons for it, present tense;
  mark only what is not settled, as **(open)** or **(proposed)**.
- `PLAN.md` — the concrete next steps, each with how one knows it is done.
- `HISTORY.md` — who decided what and when, designs tried and replaced,
  superseded measurements. TreeAMR's milestone records (M9a, M7 steps 6
  and 6b, M12 step 6), under which this code was built, stay in TreeAMR's
  `HISTORY.md`.
- `TODO.md`, if there is one, is Erik's: do not modify it.

When the implementation shows the design was wrong or incomplete, fix
`CODE.md` to describe the current state and record in `HISTORY.md` what
changed, when and why. Keep the tables of contents current (`##` and
`###` for `CODE.md`, `PLAN.md`, `HISTORY.md`; `##` for `README.md` and
this file), and update every reference to a heading you rename.

## Commands

Full test suite, about 3 min (835 tests; the MPI test's two `mpiexec`
jobs run beside the suite where the machine has 8+ threads and 24+ GB,
as in TreeAMR):

```bash
julia --project=. -e 'using Pkg; Pkg.test()'
```

```bash
julia --project=. -e 'using Pkg; Pkg.test(; julia_args = ["--threads=4"])'
```

On a fresh clone, instantiate the test and docs environments first.
They take TreeAMR from General and this package as `..`, through
`[sources]`:

```bash
julia --project=test -e 'using Pkg; Pkg.instantiate()'
```

Docs build, the only place the guide's doctest runs:

```bash
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
```

```bash
julia --project=docs docs/make.jl
```

A device run of the suite: `TREEAMR_TEST_BACKEND=metal` (or `cuda`) in
an environment that also has the device package.

`bench/checkpoint.jl` times `save_checkpoint` and `load_checkpoint` for
each HDF5 filter setting, on a smooth wave pulse and a blast wave with a
uniform atmosphere, and prints the file size, the ratio and GB/s for a
save with `sync = false`, one with the default `sync = true` (which adds
the flush to stable storage: `fsync`, or `F_FULLFSYNC` on macOS, where
`fsync` does not wait), and a load. It runs in the test environment with
the built-in filters only; the filter packages (H5Zzstd, H5Zlz4,
H5Zbitshuffle) are used where the environment has them, which means a
scratch environment that develops this checkout — never add them to
`test/Project.toml`. `TREEAMR_BENCH_DIR` puts the files on the file
system under test. A load right after a save reads the page cache;
`CODE.md`'s "Throughput and filters" under "Checkpoint and restart" has
the numbers and that caveat:

```bash
julia --project=test bench/checkpoint.jl
```

`bench/symmetry_checkpoint_mpi.sh` (checkpoint throughput on BeeGFS: the
shared file of TreeAMR's M7 step 6, then the part files of step 6b, once
per `io` in `TREEAMR_CKPT_IO`) launches MPICH_jll through `srun
--mpi=pmi2` by default or a system MPI through MPIPreferences
(`TREEAMR_MPI=system TREEAMR_MPI_MODULE=…`); it develops this checkout
and TreeAMR beside it (`TREEAMR_REPO`, default `../TreeAMR`).
`bench/symmetry_checkpoint_stress.sh` runs `bench/checkpoint_stress.jl`,
the reproducers of the multi-node checkpoint loss, from
`save_checkpoint` (now the part-file writer, verified by serial loads on
two nodes; `STRESS_IO`) down to plain `pwrite`;
`bench/checkpoint_inspect.jl` and `bench/checkpoint_layout.jl` read a
damaged shared file of step 6. Nothing writes one file from several
processes any more; anything that would must be checked with them first.
The jobs write SimWatch status files through `bench/simwatch.sh`.

## Rules and sharp edges

- **A checkpoint stores what cannot be recomputed**; do not add JLD2 or
  `Serialization`, and rename with `Base.Filesystem.rename`, not
  `mv(…; force = true)` (`CODE.md`, "Rules that span several files" and
  "Checkpoint and restart").
- **No file of a checkpoint has two writers or two openers.** Do not
  reintroduce parallel HDF5 or MPI-IO ("Checkpoints without parallel
  I/O" under "Checkpoints over MPI").
- **The file format is TreeAMR's, and stays readable.** The group
  `/TreeAMR.jl`, the format names, `format_version` and `features`, and
  `treeamr_version` (TreeAMR's version) are what every file since M9a
  holds; an additive field with an obvious default needs no bump, a
  change of meaning does ("Versioning").
- **Never call MPI here.** Every message goes through TreeAMR's
  communicator verbs.
- **Use only the companion interface** of TreeAMR (TreeAMR's `CODE.md`,
  "Companion interface"); a name outside it is a change to TreeAMR's
  list first. `[compat] TreeAMR` lists exact versions: append one, in a
  compat-only release, once the suite passes against it.
- Conventions are TreeAMR's: 4-space indent, about 90 columns, explicit
  `return`, `ArgumentError`s that say why, testset names that are
  claims.

## Repository facts

- Remote: `github.com/eschnett/TreeIOHDF5.jl`, branches `main` and
  `gh-pages`. 0.1.0 is the first version registered in General; TagBot
  tags each registered version with the `DOCUMENTER_KEY` deploy key.
  Work on a branch, and do not commit, push, tag or register without
  being asked.
- The test helpers `oracles.jl`, `ghost_oracles.jl`, `wave.jl` and
  `burgers.jl` are verbatim copies of TreeAMR's; the `CODE.md` they cite
  is TreeAMR's.
- All `Manifest.toml` files and `docs/build/` are gitignored.
