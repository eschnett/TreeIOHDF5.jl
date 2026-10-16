# TreeIOHDF5.jl — History

How the checkpoints got where they are: the decisions and their dates,
the designs tried and replaced, and measurements of code that no longer
exists. The current design is in [CODE.md](CODE.md).

**Step numbers.** "M9a", "M7 step 6", "step 6b" and the like are the
milestones and steps of TreeAMR, under which this code was built; their
records are in
[TreeAMR's HISTORY.md](https://github.com/eschnett/TreeAMR.jl/blob/main/HISTORY.md#milestones).

**Contents**

- [The split from TreeAMR](#the-split-from-treeamr)
- [The Julia floor](#the-julia-floor)
- [Checkpoint and restart](#checkpoint-and-restart)
- [Checkpoints over MPI](#checkpoints-over-mpi)
  - [Parallel checkpoints](#parallel-checkpoints)

## The split from TreeAMR

The checkpoints left TreeAMR on 2026-10-08, decided with Erik; TreeAMR's
`HISTORY.md`, "Code structure", has the decision and its reasons. Until
then they were TreeAMR's package extension `TreeAMRHDF5Ext`
(`ext/TreeAMRHDF5Ext.jl`) over the weak dependency HDF5 (`[compat]`
0.17), because TreeAMR's only hard dependency was KernelAbstractions, and
an application that never checkpoints should not load HDF5 and its
binaries; TreeAMR's `src/checkpoint.jl` held the docstrings, stubs
without methods, and an error hint that said to load HDF5 while the
extension was not loaded. The move kept the file format, and added the
provenance field `treeiohdf5_version`. The test that the functions say
to load HDF5 when it is not loaded went with the error hint.

Outflow faces came to TreeAMR on 2026-10-13 (TreeAMR's `HISTORY.md`,
"Domain and boundaries"), stored with the reflecting faces in one field
of face kinds, so the field this package read, `forest.reflecting`, went
away; it reads `reflecting_faces` and `outflow_faces` instead, and its
files gained the `outflow` attribute and feature.

## The Julia floor

The package supported Julia 1.11 and later, TreeAMR's floor, until
0.1.1; CI tested 1.11 and the latest release, and the documentation was
built on the latest. On 2026-10-16 Erik raised the floor of all the
Tree* packages to Julia 1.13, because supporting the earlier versions
slows development and is not useful at the moment. Release 0.1.2 makes
that change and accepts TreeAMR 0.2.3, the matching TreeAMR release,
whose only change is the same floor; nothing else changed. CI and the
documentation build run on 1.13 only. No code in `src/`, `test/`,
`docs/` or `bench/` depended on the Julia version.

The rename rule in `CODE.md` ("Rules that span several files") gave
1.11 as the reason not to use `mv(…; force = true)`: there it removed
the target before renaming. On 1.13 `mv(…; force = true)` tries a plain
rename first, but when that fails it still removes the target and
retries, and finally copies; a checkpoint must never be left with
neither the old file nor the new one, so the rule stands, now without
the version.

## Checkpoint and restart

*(Designed 2026-09-29 as M9a, before implementation, and decided with
Erik the same day except where marked; implemented, and its throughput
measured, the same day — see "Throughput and filters" below.)*

The checkpoint (M9a) was designed on 2026-09-29, before implementation, and decided with Erik the same day; it was implemented, and its throughput measured, the same day. Format version 1 was written through M7's step 6; version 2, the files per I/O process, came with step 6b (decided 2026-10-02 with Erik). The checksums were added in M7 on 2026-10-02, decided with Erik after a parallel file came back damaged; not using HDF5's own checksums was decided the same day with Erik, and checked. Version 2 bumped the format after all, for the part files, which a reader must understand; the checksums alone would not have. The element-type name was amended in the implementation: the design said `string(T)`. `sync = true` was added on 2026-09-29, after the first implementation, which left it as an open question. Rotating forests were designed for M12 on 2026-10-03 and amended in M12 step 6 the same day (the attribute and the feature go together). The original plan was that under M7 each rank compresses its own chunks.

**Parallel I/O and M7** (the facts checked 2026-09-29 against the HDF
Group's "Collective Calling Requirements in Parallel HDF5
Applications", "A Brief Introduction to Parallel HDF5" and "HDF5
Parallel Compression", and HDF5.jl's MPI page; the design is not
decided).

- In parallel HDF5 only raw data transfers — `H5Dwrite`, `H5Dread` —
  may run independently per rank, and any number of them. Every call
  that creates or changes the file's structure or metadata is
  collective: creating, opening, flushing and closing the file;
  creating groups, datasets and attributes; writing an attribute;
  extending a dataset. All ranks make the same call with the same
  arguments, so every rank pays for every object, and that cost does
  not fall as ranks are added. A layout whose object count grows with
  the blocks or the ranks — one dataset per variable, level and
  component, as in CarpetIOHDF5 — makes metadata the part that does not
  scale.
- Writing a filtered (compressed) dataset in parallel needs HDF5 ≥
  1.10.2 and collective writes. A chunk that several ranks write is
  given one owner, and the others send it their parts.
- This layout keeps the object count fixed: about a dozen, two more per
  field set, plus the application's plain data, and none of it depends
  on the number of blocks or ranks. Each rank's blocks are one
  contiguous hyperslab of every dataset, since an M7 rank holds a
  contiguous range of the curve and the curve is the block axis. And a
  chunk is one block, so under compression every chunk has one writer
  and none moves between ranks.
- The alternative many codes use is one file per I/O process plus a
  wrapper file (CarpetIOHDF5's per-process output, AthenaK's per-rank
  restart, a Conduit Blueprint root file). It is easy to write and
  needs no collective metadata, but it is awkward to read back on a
  different rank count, where each reader must find the files that
  hold its range; SAMRAI's restart requires the same process count
  unless a separate redistribution tool is run.
- **Decided:** M9a is serial. Which parallel design M7 uses is
  benchmarked first, on Symmetry and other HPC systems; this layout is
  the candidate, not a commitment. If the shared file does not hold up,
  M7 bumps `format_version`, and that is accepted. *(Amended
  2026-10-01, decided with Erik: parallel HDF5 into this layout is part
  of M7, with `format_version` unchanged, and the benchmark became M7's
  step 6 instead of a precondition — the shared file is built and then
  measured, and the per-process files remain the fallback if it does
  not hold up. The design, and the check that the stock HDF5_jll is
  already a parallel build, are under
  [Distributed meshes](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#distributed-meshes).)* *(Step 6 of M7 built it:
  the version-1 layout written and read by every rank of a distributed
  forest at once, a file loading on any rank count; what it settled is
  under "Parallel checkpoints" there.)* *(Measured on Symmetry's
  BeeGFS in step 6, 2026-10-02: the shared file lost data between
  nodes until ROMIO's read-modify-write was turned off, and its rate
  did not grow with nodes; it is to be replaced by files per I/O
  process, decided that day with Erik. The account is under "Parallel
  checkpoints".)* *(Step 6b, decided 2026-10-02 with Erik: the shared
  file is replaced by one file per I/O process and an index — the
  alternative of the fourth bullet — with every file written by one
  process and opened by one, and `format_version` becomes 2. The
  awkwardness that bullet names is met by an index that lists every
  part's block range, so a reader on any rank count knows which part
  holds which blocks; the design is "Checkpoints without parallel I/O"
  in [Distributed meshes](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#distributed-meshes).)*

**Formats considered** (a survey, 2026-09-29). No existing standard
fits a leaf-only octree checkpoint. VTKHDF has no non-overlapping AMR
type: its `OverlappingAMR` must be sorted by level, and VTK's
non-overlapping AMR exists only in the XML `.vthb` format. Conduit
Blueprint associates fields with vertices or elements only, so it has
no face or edge centering. openPMD's mesh-refinement extension is still
an open pull request. AMReX, Chombo and Carpet store overlapping
hierarchies, with coarse data under fine. For checkpoints the norm is a
code's own versioned HDF5 schema — Parthenon, FLASH, Athena++,
CarpetIOHDF5 — or its own binary format (AMReX, AthenaK, p4est).
Parthenon's `.rhdf` is the closest model, and the one followed here:
one dataset per variable over all blocks in Z-order, a block table,
collective hyperslab writes with one block per chunk, restart on any
rank count, and one integer format version. What is done differently
is keys relative to their root, no stored coordinates, and a features
list beside the version. JLD2 is set aside because it records Julia
type names, which ties a file to the definitions that wrote it, and
because it has no MPI.

M9a left open (2026-09-29) the parallel I/O design for M7: one shared file, as the version-1 layout allows, against one file per I/O process plus a wrapper file, to be benchmarked on Symmetry and other HPC systems first. Decided 2026-10-01 with Erik: the shared file, with its throughput on a cluster file system to be measured in M7's step 6. Measured there, 2026-10-02: on BeeGFS the shared file lost data between nodes until ROMIO's read-modify-write was turned off, and did not get faster with nodes; it was replaced by one file per I/O process with an index file, decided that day with Erik. The missing-filter refusal was found on 2026-09-29, measuring M9a.

## Checkpoints over MPI

Checkpoints without parallel I/O were decided on 2026-10-02 with Erik, as M7's step 6b, replacing the shared file: one writer and one opener per file, the removal of `TreeAMRHDF5MPIExt`, `open_parallel_file`, `librarycomm` and the hints, `io = :node` as the default, and the file names were decided then; the integer `io` clamp and the contiguous groups for non-contiguous nodes were decided while implementing it. The external links for tools were recommended to Erik and included.

M7 step 6b implemented the checkpoints without parallel I/O on 2026-10-02 and amended its design. After the first Symmetry run, job 568077, the gathering changed: there each member's blocks were one message, received and then written with nothing in flight, and one I/O process for eight ranks on a node saved at 0.80 GB/s, against 1.47 for step 6's shared file. The pipelined form (checksums first, pieces of at most 64 MiB, the next piece in flight) measured again made no difference that the noise lets one see; it is kept for the memory it bounds, and the likelier reason is under step 6b's record.

**What the feasibility check found** (2026-10-01, in a scratch
environment on the development machine: Apple M3 Pro, HDF5.jl 0.17.4,
HDF5_jll 2.2.2+0, which is libhdf5 2.2.0, and MPI.jl 0.20.27).

- *Parallel HDF5 needs nothing chosen.* Every one of HDF5_jll 2.2.2's
  60 artifacts is an MPI build, tagged by MPI ABI: `mpich`, `mpiabi`,
  `openmpi` and `mpitrampoline`, all four on `x86_64-linux-gnu` and on
  `aarch64-apple-darwin`, and `microsoftmpi` on Windows. MPIPreferences
  selects the one matching the MPI binary. So `HDF5.has_parallel()` is
  `true` out of the box, and has been all along under M9a, which loads
  the same MPI build and never opens a file in parallel.
- *Both binaries work.* On Julia 1.11.9 with the default binary,
  MPICH_jll 5.0.2, the `mpich` artifact loads. On Julia 1.13.1 it is
  MPIABI_jll with the `mpiabi` artifact, because a `LocalPreferences.toml`
  in the global v1.13 environment selects it on this machine. That
  preference stacks into every project, and subprocesses must see the
  same one as the `mpiexec` that launches them; launching them with
  `MPI.mpiexec()` from a parent with the same load path ensures that.
- *What was run.* Under `mpiexec -n 2` and `-n 3`,
  `h5open(path, "w", comm, info)` created a file with an attribute and
  a dataset written by column, on both Julia versions. On 1.13, a
  contiguous dataset and a chunked one with `Deflate(1)` were written
  collectively by last-axis hyperslab, one chunk per column, with one
  rank's slab empty, and read back correctly, serially and in
  parallel.
- *What was not.* Linux CI was not run. Its artifact exists for the
  default binary, and step 3, which adds MPI to the test environment,
  will show it there. `MPI.has_cuda()` exists in MPI.jl 0.20.27 and
  returns `false` for MPICH_jll here.

### Parallel checkpoints

**Parallel checkpoints** (parallel HDF5 in M7, decided 2026-10-01 with
Erik; *superseded 2026-10-02*, decided with Erik, by "Checkpoints
without parallel I/O" below, after the four-node account at the end of
this item. What follows is kept as the record of the design that was
built in step 6 and measured, and as the reason for its replacement.)
One shared file, with the version-1 layout unchanged:
`format_version` stays 1, and a file restarts on any rank count, serial
included, which is what "No coordinates, and no partition" was for.

- *Where the code goes.* The MPI-specific calls —
  `h5open(path, mode, comm, info)`, the `mpio` file access, the
  collective transfer property — come from HDF5.jl's own MPI
  extension, which loads only with MPI. So they go into a second
  extension, `TreeAMRHDF5MPIExt`, triggered by HDF5 and MPI together.
  `TreeAMRHDF5Ext` gains hooks, dispatched on the forest's communicator
  type, for opening the file, for creating objects and for the slab
  each rank reads and writes, with today's code as the serial methods.
- *Collective metadata.* Every rank creates every group, dataset and
  attribute with the same arguments, which the layout keeps to a fixed
  dozen or so at any rank count (see "Parallel I/O and M7" under
  [Checkpoint and restart](CODE.md#checkpoint-and-restart)). Attribute values
  must agree, so the provenance is formed on rank 0 and broadcast,
  since `created`, `hostname` and `nthreads` differ between ranks. It
  gains `nranks` (decided 2026-10-01 with Erik), an additive field
  whose obvious default for an older file is 1, so the format does not
  change.
- *Raw data by hyperslab.* Each rank writes and reads the last-axis
  hyperslab of its own blocks, `blockrange`, in every dataset: the leaf
  columns `root`, `level` and `coords`, and each field set's `data`.
  The transfers are collective, as a filtered dataset requires. With
  filters a chunk is one block and variable, so every chunk has exactly
  one writer. A rank with no blocks takes part with an empty slab.
- *Durability.* The write still goes to `path * ".partial"`. Under
  `sync = true` the flush has to reach every rank's writes, not only
  rank 0's: on a parallel file system each client caches its own, and
  an `fsync` on rank 0 flushes none of the others'. So the ranks make a
  collective `H5Fflush`, which the MPI-IO driver turns into
  `MPI_File_sync` on every rank (confirmed in step 6 against libhdf5
  2.2.0's source, below), and then close the file collectively. Rank 0 then
  flushes the file itself as today (`F_FULLFSYNC` on macOS, where a
  plain `fsync` does not reach the drive), renames it and flushes the
  directory. A barrier follows, so that no rank returns before the
  rename.
- *Errors.* Everything that can be refused — the field sets, the
  forest, the path, the plain data — is checked before the first
  collective HDF5 call, and the verdict is agreed by `allgather`, so a
  refusal is raised on every rank with the same reason. An error inside
  a collective HDF5 call on one rank cannot be recovered portably,
  since the others are waiting in it. It is fatal to the job, as in any
  MPI code, and documented as such.
- *Plain data and the do-block are collective.* `write_plain` and the
  `f(app)` callback run on every rank with the same data, because an
  attribute written collectively has one value. `write_plain` checks
  this by gathering a digest of the encoded bytes, and refuses data
  that differ between ranks; that is step 6's refusal test.
- *Loading.* Every rank reads all of the leaf columns, since the forest
  is replicated, builds the forest with `comm` through the validated
  `leaves` path, and reads its own slab of each field set into its
  state vector.

*(Step 6, where this was implemented; what it settled, and where it
amends the bullets above:)*

- *Where the code goes* (amended). `TreeAMRHDF5MPIExt` holds one call,
  `open_parallel_file(::MPI.Comm, path, mode)`, which is HDF5.jl's
  `h5open(path, mode, comm, info)`. The collective transfer property is
  HDF5.jl's own `dxpl_mpio = :collective`, which needs no MPI, and
  everything else is in `TreeAMRHDF5Ext` beside the serial code. The
  hooks dispatch not on the communicator type, which the HDF5 extension
  cannot name (it is `TreeAMRMPIExt`'s, and the load order of two
  extensions is not defined), but on an `Access` chosen by `commsize`:
  `Alone` for one rank, whose methods are M9a's calls unchanged, and
  `Ranked` otherwise. The extension reaches MPI through two stubs in
  `src/`: `librarycomm(comm)`, whose method in `TreeAMRMPIExt` returns
  the duplicate, and `open_parallel_file`, whose fallback refuses with
  the reason. A forest over a one-rank MPI communicator takes the
  serial path, and its file is a serial file with `nranks = 1`.
- *Who writes what.* Every rank creates every group, dataset and
  attribute with the same arguments, and writes every attribute. A
  dataset over the blocks — `root`, `level`, `coords` and each `data` —
  is written by last-axis hyperslab in one collective transfer, an
  empty rank with an empty selection (`H5Sselect_none`, which HDF5.jl
  does not wrap). Every other dataset — the extents, the provenance,
  the plain data — is written by rank 0 alone with an independent
  transfer, and read by every rank. That is legal because parallel
  HDF5 allocates an unfiltered dataset's storage when it creates it
  (`H5D__create` in `H5Dint.c`), and it keeps a value from being written
  `P` times over to the same bytes.
- *No variable-length data in a parallel file* (found in step 6).
  libhdf5 refuses to write variable-length data through the MPI-IO
  driver (`H5D__write`: "Parallel IO does not support writing VL or
  region reference datatypes yet"), from any number of ranks, and
  HDF5.jl stores an array of strings as variable-length. Attributes are
  not affected (the `features`, `centering` and `parity` arrays wrote
  and read back), nor are scalar strings, which HDF5.jl stores at a
  fixed length. So in a parallel file a plain-data array of strings is
  fixed-length UTF-8, NUL-padded to its longest string; `read` returns
  the same `Array{String}`, so the item reads back the same, with the
  same `type` and `eltype`, and the format version is unchanged. A
  string in such an array that holds a NUL is refused before anything
  is written, since the padding would lose it. The M9a reader (0.1.4)
  reads a parallel file, fixed-length strings and filtered data
  included (checked).
- *Provenance* is rank 0's, gathered to every rank by an `allgatherv` to
  which the other ranks contribute nothing, so no broadcast verb was
  added. `nranks` follows `nthreads`; a serial file carries `nranks = 1`
  (decided here: the field is then in every file M7 writes, and a file
  without it is from before M7, which `read_provenance` reads as 1).

- *Durability, confirmed.* In libhdf5 2.2.0, `H5Fflush` reaches
  `H5F__flush` (`H5VLnative_file.c`), which calls `H5F__flush_phase2`
  with `closing = false` and so `H5FD_flush` and the driver's
  `H5FD__mpio_flush`, which calls `MPI_File_sync` unless the file is
  closing (`H5FDmpio.c`). So a flush as the file closes does not sync,
  and the explicit collective flush before the close is needed. In
  MPICH's ROMIO, `MPI_File_sync` is `ADIOI_GEN_Flush`, an `fsync` on
  each rank that wrote through its own descriptor, which under
  collective buffering are the aggregators that did the writing. Then
  rank 0 does what a serial save does — `F_FULLFSYNC` on macOS, where
  the ranks' `fsync` stops short of the drive, then the rename, then the
  directory — and an `allgather` of whether it succeeded is the barrier,
  so every rank returns once the checkpoint is in place, or throws.
  Whether BeeGFS honours each client's `fsync` is the file system's,
  and is not something a test here can see.
- *Collective metadata reads are not enabled.* Each rank reads the
  file's metadata independently, which is always correct, and keeps a
  do-block that reads on rank 0 alone legal. At thousands of ranks the
  independent reads of one small object header may become the cost
  (`H5Pset_all_coll_metadata_ops` is the remedy); the Symmetry
  measurement is where that would show. *(At up to 8 ranks on one node,
  and at 32 on four nodes, step 6, it did not.)*
- *Errors inside a collective call* remain fatal, as above. A
  `write_plain` refused in the do-block is agreed, so every rank leaves
  the block together and closes the file collectively, and the partial
  file is removed (tested).

*(Step 6 on four nodes of Symmetry, 2026-10-02: what amends the bullets
above, and withdraws the step's earlier reading that its one-node
measurement stood for the design. The account, with the jobs, is in the step's record under
[Milestones](https://github.com/eschnett/TreeAMR.jl/blob/main/HISTORY.md#milestones).)* **The shared file is to be replaced**
(decided 2026-10-02 with Erik, after what follows): writing one file
from several nodes is judged not reliable enough, and the parallel
checkpoint becomes one without parallel I/O — a subset of the ranks are
I/O processes, each writes a file of its own, an index file ties them
together, and on reading each file is opened by one process. The
checksums and the reproducers below carry over to it; the hints and the
shared-file layout need not.

- *No read-modify-write* (amends "Raw data by hyperslab", which took a
  rank writing only its own bytes to be enough). A checkpoint saved by
  32 ranks on four nodes came back with one rank's slab of the leaf
  coordinates zeroed. ROMIO, the MPI-IO of MPICH and MPICH_jll, knows
  no BeeGFS and drives it with its generic POSIX driver ("UFS"), which
  turns some writes into a read-modify-write of a wider range: data
  sieving, for an independent write with a noncontiguous file view,
  under an `fcntl` write lock over the extent; and collective
  buffering, which writes each aggregator's whole file domain after
  reading it if anything in it is not being written, under no lock
  outside atomic mode (read in MPICH 5.0's `ad_write_str.c` and
  `ad_write_coll.c`). On a POSIX file system that is safe, since a
  write that has returned is visible to every reader and a lock
  excludes every other locker. Symmetry's BeeGFS clients break both:
  they hold a node's writes until a flush (`tuneFileCacheType =
  buffered`), and their `fcntl` locks are local to the node
  (`tuneUseGlobalFileLocks = false`, in `/etc/beegfs/beegfs-client.conf`
  and the client's `/proc` view). The first is shown directly: a rank's
  completed `write`, read after a barrier by a rank on another node,
  was not there in 5 of 300 trials, and never between ranks of one
  node (28 of the 32 pairs tried). The second is read from the
  configuration and was not tested. HDF5 had placed the first chunks of the filtered data before the leaf
  columns, so rank 0's write of its chunks spanned the columns; data
  sieving read them while another node still held a rank's
  coordinates, and wrote the zeros back. The explanation is the one
  consistent with all of the evidence in the step's record — under data
  sieving the loss is always whole slabs of ranks on nodes other than
  rank 0's, the rank whose write spans them, and under collective
  buffering whole file domains of aggregators; it vanishes with both off,
  it appears below HDF5 with nothing but MPI-IO calls, and the file
  system's configuration and visibility are as described — but no
  trace of an individual write's journey was taken. The destroyed write
  itself took no lock, so global locks alone would not have saved it.
- *The hints* (the remedy for ROMIO). Every parallel file is opened
  with `romio_ds_write = disable` and `romio_cb_write = disable`, so
  each rank writes exactly its own bytes. On the reproducer (four nodes,
  32 ranks, filtered saves through `save_checkpoint`) damaged saves went
  from 12 in 200 (6 %) to 0 in 1000, where the old rate predicts about
  60; and at two nodes, in the throughput benchmark, saves without the
  hints were refused by the checksums in both of two rounds and saves
  with them never. The cost is in filtered saves of data that compress
  well, where each chunk becomes a write of its own: blast with zstd(1)
  at 16 ranks saved at 1.40 GB/s with the hints against 1.88 without,
  while unfiltered saves and pulse did not change (the step's record).
  **Not covered: Open MPI.** Its own MPI-IO, OMPIO, the default of the
  HPC-X that step 7 measured between nodes, ignores the
  `romio_` keys; whether OMPIO reads or writes back anything it was
  not given was not established, since HDF5_jll's Open MPI build loads
  its own Open MPI rather than HPC-X's and the run was stopped by the
  change of plan above. Enabling `tuneUseGlobalFileLocks` on the BeeGFS
  clients, which only the administrators can do, would restore ROMIO's
  locking between data-sieving ranks, but not, by the reading above,
  the visibility of unlocked writes that the observed loss needed.

- *NFS, for comparison.* ROMIO on the NFS `/home` of the same nodes —
  whose NFS driver locks around its writes, though which driver ran was
  not checked — lost nothing with data sieving (0 damaged in 1000) or with collective
  buffering forced on (0 in 200). Plain `pwrite`s of adjacent ranges
  from several nodes, no MPI-IO involved, lost whole pages there in 98
  of 200 trials — NFS's page cache, and the reason ROMIO locks — while
  on BeeGFS the same `pwrite`s were exact in 200 of 200. Neither file
  system is coherent between nodes; they fail differently, and a
  shared file is safe only when the MPI-IO layer knows how each fails.
