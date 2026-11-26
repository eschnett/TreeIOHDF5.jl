# TreeIOHDF5.jl — Plan

**Contents**

- [Release 0.1.0](#release-010)
- [Release 0.1.1](#release-011)
- [Release 0.1.2](#release-012)
- [Release 0.1.3](#release-013)
- [Release 0.1.4](#release-014)
- [Release 0.1.5](#release-015)
- [Release 0.1.6](#release-016)
- [Release 0.1.7](#release-017)
- [Release 0.1.8](#release-018)
- [Cluster jobs through SimLaunch](#cluster-jobs-through-simlaunch)
- [Release 0.1.10](#release-0110)
- [Release 0.1.11](#release-0111)
- [Release for TreeAMR 0.3](#release-for-treeamr-03)

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

Done: element sets, for TreeAMR 0.2.7 (TreeAMR's M16; `CODE.md`,
"Element sets" under "Checkpoint and restart"), under the feature
`elements`; 974 tests pass against the registered TreeAMR 0.2.7.

## Release 0.1.7

Done: forests of patches, for TreeAMR 0.2.8 (TreeAMR's M17; `CODE.md`,
"Forests of patches" under "Checkpoint and restart"), under the feature
`patches`; 1088 tests pass against the registered TreeAMR 0.2.8.

## Release 0.1.8

Compat only, for TreeAMR 0.2.9, the interpolation on element sets and
patches (TreeAMR's M19, steps 1–7), which leaves the companion interface
unchanged: `[compat] TreeAMR = "=0.2.8, =0.2.9"`. 1088 tests pass against
the registered TreeAMR 0.2.9.

1. Tag and register 0.1.8. *Done when* CI is green on GitHub and the
   package resolves from General.

## Cluster jobs through SimLaunch

The Symmetry scripts became SimLaunch specs in `jobs/` on 2026-11-17
(`HISTORY.md`, "Cluster jobs"); the scripts stay until a run of each
spec has been compared with theirs, as SimLaunch's `CONVERTING.md` asks.

1. **Run the smoke spec on Symmetry.** Done 2026-11-17: job 602669 in
   `amddebugq`, on cn102 (EPYC 7543), after the precompile job 602668;
   both runs finished, the serial one and two ranks of MPICH_jll under
   `srun` with HDF5_jll's MPICH artifact, with the same file sizes and
   ratios as on the laptop.
2. **Compare the throughput.** `jobs/checkpoint-mpi.jl` beside a run of
   `bench/symmetry_checkpoint_mpi.sh` with
   `TREEAMR_BENCH_FILTERS=none,shuffle+deflate(1)`, the settings the
   spec has. *Done when* the rates agree within the scatter of the runs
   (the ranks of fewer than eight a node are no longer bound to cores,
   so those may differ; say so if they do); then delete the script.

   Run 2026-11-17 in `amdq` on cn091–092: the spec as job 602670, the
   script as 602671 right after it, on the same nodes. Both ran out of
   their hour at the same point, the 12³ mesh at one node and two ranks
   (`io = node`), since a run on one rank of that mesh takes 13 minutes;
   the spec now asks for 2½ hours. Of the 12 runs both finished (all ten
   of the 6³ mesh, the two on one rank of the 12³), the file sizes and
   ratios are the same, the compressed rates agree within 0.03 GB/s (5 %
   at 16 ranks), and the uncompressed rates differ by up to ±20 % in
   both directions, the scatter of BeeGFS without a trend: a blast-wave
   save with `io = all` at 5.87 against 7.09 GB/s on eight ranks, 6.42
   against 5.25 on sixteen. The unbound runs
   on 2 and 4 ranks a node fall on both sides too.

   The spec with 2½ hours, job 602743 on cn088 (EPYC 7532) and cn098
   (EPYC 7543), finished all 21 runs in 1:54. Its 6³ mesh repeats job
   602670 within the same scatter, and its 12³ runs that the script also
   reached (one rank, and the start of two) agree with the script's. The
   rest of the 12³ mesh has no counterpart, since the script never got
   that far in its hour: with `io = all` the uncompressed saves reach
   8–10 GB/s on 8 and 16 ranks, with `io = node` they stay near 1–1.5
   GB/s, one writer a node. The script was deleted on 2026-11-18.
3. **Compare the stress jobs.** `jobs/checkpoint-stress.jl` and
   `jobs/checkpoint-stress-hpcx.jl` against a run of their scripts with
   the same cases. *Done when* the summaries agree (no damage in the
   `treeamr` modes, the same pattern of damage below HDF5); then delete
   both scripts and `bench/simwatch.sh`, and the mentions of them in
   `CLAUDE.md` and `CODE.md`.

   Run 2026-11-18, four nodes each, the specs side by side and the
   scripts after them, from the copy of job 602671 (TreeAMR 0.2.10):
   - **MPICH_jll**: `checkpoint-stress.jl` as job 605553 (cn083–086),
     the script as 605556 (cn101–104), step 6b's three cases at 500
     iterations each. Both: 0 bad rows in every case, filtered with
     `io = node` (357 s against 307 s), filtered with `sync` and `io =
     all` (401 against 365), unfiltered (208 against 202).
   - **HPC-X**: `checkpoint-stress-hpcx.jl` as 605555, the script as
     605557, both on cn106–109, the spec's seven cases at 200 iterations.
     Neither could run as written: with HPC-X's `libmpi` loaded directly
     (abi "OpenMPI"), `using TreeIOHDF5` loads HDF5_jll's Open MPI build,
     whose OpenMPI_jll fails beside HPC-X's PMIx (undefined symbol
     `pmix_framework_names`; precompile job 605545, and on the login
     node). Both ran through the profile's `mpiabi` recipe instead,
     HPC-X behind mpi_abi_wrapper 1.2.0, under which HDF5_jll takes
     MPIABI_jll; the script's environment got the same preferences. Both
     agree: the four OMPIO cases (`sieve-ind`, `sieve-coll`,
     `mpiio-coll`, `posix`) 0 bad rows, and the three ROMIO cases
     (`OMPI_MCA_io = romio321`: `sieve-ind` with and without data
     sieving, `sieve-coll` with collective buffering off) abort on all 32
     ranks within seconds, "stack smashing detected" in
     `MPI_File_write_at_all`, in the wrapper's `w_MPI_File_write_at_all`.
     The script's summary counts those as 0 damaged, since it counts only
     `BAD` lines.

   The crash is the wrapper's, not HPC-X's. Without it (job 605602, the
   script with HPC-X's `libmpi` loaded directly, now that
   `checkpoint_stress.jl` loads TreeIOHDF5 only in the modes that save
   through it) the three ROMIO cases ran: `sieve-ind` with data sieving
   damaged 16 of 200 saves (ranks 9–30, none on rank 0's node, as under
   MPICH in step 6), with data sieving off 0, `sieve-coll` with
   collective buffering off 0, and OMPIO 0. A probe of the crashing call
   (`MPI_File_write_at_all` of the coords column, 32 ranks, job 605604)
   with a guard buffer as its status: HPC-X directly writes exactly the
   24 bytes of Open MPI's `MPI_Status` under ROMIO and OMPIO; through the
   wrapper, ROMIO smashes the stack on every rank and OMPIO is fine. The
   cause (job 605605, the linker's binding log): HPC-X's ROMIO plugin,
   `mca_io_romio321.so`, calls the public `MPI_*` functions (72 of them;
   the OMPIO plugin none), and through the wrapper its
   `MPI_Status_set_elements_x` and `MPI_Type_size_x` bind to
   `libmpi_abi.so`'s ABI functions instead of Open MPI's `libmpi.so`. The
   ABI's status is 32 bytes, so it overruns the 24-byte Open MPI status
   the wrapper's `w_MPI_File_write_at_all` keeps on its stack. A bug of
   mpi_abi_wrapper 1.2.0 (or of how its library is loaded), for its own
   repository.

   mpi_abi_wrapper 1.2.1 fixes it
   ([eschnett/mpi_abi_wrapper#19](https://github.com/eschnett/mpi_abi_wrapper/pull/19):
   the components the implementation loads later are bound to the
   implementation). Installed at the profile's path the same evening,
   all of it ran again on cn083–086: the spec as job 605722, the script as 605723
   right after it, the probe as 605724. No stack is smashed anywhere; the
   probe finds ROMIO writing the wrapper's 32-byte ABI status exactly, and
   HPC-X directly its 24 bytes, as before. The spec's seven cases: 0 bad
   rows each, the three ROMIO cases included. The script's: the same,
   except `mpiio-coll` under OMPIO, which aborted on all ranks with a UCX
   assertion (`proto_select.c:246`, `rkey->ep_cfg_index=3
   ep_cfg_index=2`) in UCC's allreduce under OMPIO's `vulcan` collective
   write, a failure of HPC-X's own and not of the status; the same case
   passed in 605555, 605557 and 605722. So the summaries agree, and the
   spec now measures ROMIO under HPC-X.

   `sieve-ind` with data sieving lost nothing in 200 saves in either run
   through the wrapper, where HPC-X directly had lost 16 in 200 (605602,
   on cn101–104). The wrapper is not why: job 605739 alternated the two on
   cn083–086, three rounds of 200 saves each, and neither lost a save,
   HPC-X directly included. The loss comes and goes with the nodes or the
   state of BeeGFS, as under MPICH in step 6, so a clean run does not show
   it gone.

   The `[after]` commands could not delete the last saves (37 MB left in
   the job directories), since a job directory is read-only once its job
   ends; `checkpoint_stress.jl` now removes them itself at its end,
   checked on the laptop. Job 605722 ran the study's older snapshot, so
   its saves are left too. (The `hpcx` recipe, HPC-X without the wrapper,
   still cannot be prepared for the spec, since `bench/Project.toml` holds
   HDF5, whose Open MPI build does not load there.) Done 2026-11-18: both
   scripts and `bench/simwatch.sh` deleted, their mentions updated.
4. **Run the spec with every filter on Symmetry.** Since the comparison
   `checkpoint-mpi.jl` runs in `bench/Project.toml` and measures all
   seven filter settings, and binds the runs of 1, 2 and 4 ranks a node
   to their share of the NUMA domains (`HISTORY.md`, "Cluster jobs").
   Only the smoke spec has run in that environment, on the laptop. *Done
   when* a job in `amdq` (about 4 hours, 6 asked) finishes every run with
   the filter packages loaded, and the `none` and `shuffle+deflate(1)`
   rows agree with job 602743's; then the numbers can replace CODE.md's
   multi-node ones where they differ.

   Run 2026-11-18 as job 605468 on cn106–107 (EPYC 7543; the profile
   now Erik's own, `HISTORY.md`, "Cluster jobs"): all 21 runs finished in
   3:50, each of the 20 benchmark runs with "filter packages: H5Zzstd,
   H5Zlz4, H5Zbitshuffle" and all fourteen rows, under the same Julia
   1.13.4, HDF5 2.2.0 and MPICH 5.0.2 as job 602743. The file sizes and
   ratios are the same. The uncompressed saves agree within the scatter
   of BeeGFS, without a trend (on the 12³ mesh with `io = all`: 9.90
   against 9.71 GB/s for the blast wave on 8 ranks, 8.44 against 8.93 on
   16; with `io = node` 1–1.9 GB/s in both). `shuffle+deflate(1)` is
   faster everywhere, by 25–35 % on one node (a blast-wave save on one
   rank 0.17 against 0.13 GB/s, on 8 ranks 1.03 against 0.80) and by
   7–13 % on two: compression is bound by the CPU, and 602743's first
   node was an EPYC 7532 (Zen 2) and its second a 7543, where 605468 had
   7543s (Zen 3) only. That the runs of 8 ranks a node, bound alike in
   both jobs, gain as much as those of 1, 2 and 4 says the gain is the
   CPU's, not the new binding. Uncompressed loads of 2 and 4 ranks a
   node are 15–40 % faster (5.69 against 4.30 GB/s, 4 ranks, blast wave),
   which may be the binding; they read the page cache. CODE.md's one
   multi-node number, under "Compression where the data are", is TreeAMR's
   step 6b on four nodes (blast wave, zstd(1): 1.45 GB/s with `io =
   :node`, 4.50 with `io = :all`), which a two-node job does not repeat;
   per node it agrees with this job's 12³ mesh (0.84 and 4.64 GB/s on two
   nodes, 0.42 against 0.36 a node with `io = :node`), so nothing is
   replaced. Done.

## Release 0.1.10

Compat only, for TreeAMR 0.2.11, which makes the communicator verbs
`commrank`, `commsize`, `allgather` and `allgatherv` public (TreeGRRMHD's
AMR-13): `[compat] TreeAMR = "=0.2.8, =0.2.9, =0.2.10, =0.2.11"`. The
names this package imports keep their meaning, and its `allgatherv`
calls pass `UInt8` and `UInt64` vectors, which the new `isbits` check
accepts. 1088 tests pass against the TreeAMR checkout.

1. Tag and register 0.1.10 once TreeAMR 0.2.11 is registered. *Done
   when* CI is green on GitHub and the package resolves from General.

## Release 0.1.11

The appendix of a set interpolated across a glue (TreeAMR's M20), for
TreeAMR 0.2.12: `[compat] TreeAMR = "=0.2.12"` alone, since this package
now imports `hasappendix`, `corelength` and `appendix_entries`, which
0.2.12 added. A checkpoint of such a set stores the appendix in a dataset
of its own beside the cores ("M20: the appendix" in `HISTORY.md`).

1. Tag and register 0.1.11. *Done when* CI is green on GitHub and the
   package resolves from General.

## Release for TreeAMR 0.3

Closed blocks (TreeAMR's M22): a set with a vertex-like dimension stores
its closed blocks under the feature `closed_blocks`, the appendix and the
`walls` attribute are gone, and a file of the half-open layout with a
vertex-like set is refused ("Closed blocks" in `CODE.md`). `[compat]
TreeAMR = "=0.3.0"`; the `[sources]` path entries to the TreeAMR
checkout beside this one go once 0.3.0 is registered.

1. **(open)** Erik's answers on the half-open files — whether they are
   converted, filled on load or stay refused — and the release's version
   number. *Done when* `CODE.md` says what such a file becomes.
2. Tag and register once TreeAMR 0.3.0 is registered. *Done when* CI is
   green on GitHub and the package resolves from General.
