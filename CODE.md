# TreeIOHDF5.jl — Design

TreeIOHDF5 is checkpoint and restart for
[TreeAMR](https://github.com/eschnett/TreeAMR.jl) meshes, through HDF5:
the forest, the field sets an application evolves and its own plain
data, written to one file serially, or to an index and one part file per
I/O process over MPI, and read back exactly on any thread count, rank
count and backend. It was TreeAMR's own until TreeAMR 0.2 (its milestone
M9a, distributed in its M7 step 6b); how it got here is in
[HISTORY.md](HISTORY.md), and TreeAMR's milestone records are in
[TreeAMR's HISTORY.md](https://github.com/eschnett/TreeAMR.jl/blob/main/HISTORY.md#milestones).

**Status.** Implemented, and tested against TreeAMR 0.2.2 and 0.2.3,
on Julia 1.13; the releases that wait for TreeAMR's are in
[PLAN.md](PLAN.md).

**Contents**

- [Code structure](#code-structure)
  - [The companion interface](#the-companion-interface)
  - [Rules that span several files](#rules-that-span-several-files)
- [Checkpoint and restart](#checkpoint-and-restart)
- [Checkpoints over MPI](#checkpoints-over-mpi)
- [Tests](#tests)
- [Open questions](#open-questions)

## Code structure

`src/TreeIOHDF5.jl` is the module: its dependencies, the names it takes
from TreeAMR, and the exports. `src/api.jl` declares the five functions
with their docstrings and holds no HDF5 code; `src/hdf5.jl` implements
them — serial HDF5 only, over a distributed forest the I/O groups, part
files and index of "Checkpoints without parallel I/O", the data moved by
TreeAMR's communicator verbs. MPI is never called here: an `MPI.Comm`
reaches TreeAMR's MPI extension through `communicator`, and every
message goes through TreeAMR's verbs. `bench/` holds the throughput
benchmark and the Symmetry jobs, `test/` the suite. The package
supports Julia 1.13 and later, as TreeAMR does, and CI tests 1.13 only
([HISTORY.md](HISTORY.md#the-julia-floor) has why).

### The companion interface

TreeIOHDF5 is a companion package of TreeAMR: it provides infrastructure,
and so it uses TreeAMR's internals — the communicator verbs, the
cross-rank agreement (`ForestDigest`, `digest_verdict`, `layouthash`),
the seam (`hasrotating`, `rotating_dims`), the face kinds
(`reflecting_faces`, `outflow_faces`), the partition and thread
helpers, `tohost` and `samebackend`, and the fields of `Forest`,
`FieldSet` and `MortonKey` — beside its exports. The list, and why it is
versioned by exact TreeAMR releases rather than by semantic versioning,
is TreeAMR's `CODE.md`,
["Companion interface"](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#companion-interface): `Project.toml`
lists the exact TreeAMR versions this package was tested against, and
one is appended, in a compat-only release, once the suite passes against
it.

### Rules that span several files

- **A checkpoint stores what cannot be recomputed** (M9a, see "Checkpoint and restart"): the forest's parameters and its leaves, in
  curve order, and each field set's layout and **owned points only**,
  in state-vector layout. Ghosts, shared planes and schedules are the
  application's to rebuild with its own operators and hook. A load
  builds the forest through the validated `leaves` path
  (`Forest(roots; …, leaves)`, which refuses a list that does not tile
  the brick or is not balanced) and the field set through its
  constructor, so nothing read is trusted before they check it.
  Compatibility is the file's `format_version` plus a must-understand
  `features` list, never package versions; each refusal says why and
  points to `checkpoint_environment`. TreeAMR writes only under
  `/TreeAMR.jl` and the application only under its own top-level group,
  leaving the root free for M9b's sidecars. The write goes to
  `path * ".partial"` and is renamed over `path` with
  `Base.Filesystem.rename` — not `mv(…; force = true)`, which may
  remove the target first — and, under the default `sync = true`, the
  partial file is flushed to stable storage before the rename and its
  directory after (`F_FULLFSYNC` on macOS, `fsync` elsewhere), since
  closing a file ends in the page cache and a rename can reach the disk
  before the data it names. Element types are HDF5 natives or *limbs*
  (`Float32x2` as two `Float32`), named as a Base-only module prints
  them and matched against the loader's `types`. No Julia type
  definition reaches the file, so a converter can read an old file
  without the old package; do not add JLD2 or `Serialization`. Every
  file carries CRC-32C checksums — the leaf list's (`leaves_crc32c`)
  and one per block of each field set (`data_crc32c`), and the index
  one per part and field set over those — verified on load; HDF5's own
  Fletcher-32 is deliberately not used (it accepts an all-zero chunk).
- **No file of a checkpoint has two writers or two openers** (M7 step
  6b, see "Checkpoints without parallel I/O"). A shared file
  written from several nodes through MPI-IO lost data on Symmetry's
  BeeGFS (step 6), so HDF5 is used serially only and the data travel
  as messages: the ranks form `k` contiguous I/O groups (`io = :node`,
  the default, by `commnodes`; `:all`; or a number), each group's first
  rank writes a part file `path.<saveid>.<j>.h5` from its members'
  streamed blocks, and rank 0 writes the index (format version 2) last;
  its rename is the commit point, after which rank 0 removes the
  previous parts and orphans. Loading, only rank 0 opens the index and
  broadcasts an in-memory image of it without the data (`bcast`), each
  part is read by one rank, which sends the blocks to their owners, and
  every step that runs on some ranks only ends in `agree_errors`, so a
  failure anywhere throws everywhere and nobody waits on a message. The
  index's external links to the parts are for tools; the loader must
  never follow them (that opens the target). One part lives inside the
  index, so a serial checkpoint is one file; version-1 files (the
  fixtures in `test/fixtures/`) still load. Do not reintroduce parallel
  HDF5 or MPI-IO.

## Checkpoint and restart

Long runs outlast a queue's day: TreeHydro's showcase on an H200 at
10–20 levels, and TreeGeneralizedHarmonic's production runs, estimated
at 38–149 h. An application calls one function at a chunk boundary to
save the forest, its evolved field sets and its own plain data; a fresh
process loads them exactly, on any thread count and any backend, and
continues **bit-identically** at any thread count (across backends,
see "Loading" below). A file this version cannot interpret is refused
with the reason, and with a way to recreate the environment that wrote
it.

**What is saved and what is rebuilt**. A checkpoint holds
what cannot be recomputed, and nothing else:

| Item | Handling | Why |
|---|---|---|
| Forest: `D`, the geometry type, `roots`, `periodic`, `reflecting`, `outflow`, `rotating`, `extents` (bitwise, in the geometry type), `N` | saved | the inputs the forest was built from |
| Forest: the leaf list | saved | the only record of the mesh's history |
| Forest: `generation` | not saved | a staleness counter, meaningless in another process |
| Field set: element type, `nvars`, `G`, `centering`, `walls`, `parity`, `rotation` | saved | its layout |
| Field set: the **owned** points, in state-vector layout `(N, …, N, nvars, nblocks)` | saved | the authoritative data |
| Ghosts, shared vertex planes, the derived wall plane | rebuilt by `scatter!` and `fill_ghosts!` with the application's hook | derived from the owned points |
| `GhostSchedule`, `InterfaceSchedule`, `Operators`, the parity factors, the rotation tables, a `RotationPair` | rebuilt | derived, or the application's inputs |
| Regridding | nothing to save | it keeps no state between calls |
| Scratch field sets (fluxes, primitives) | the application's choice | it passes only the sets it evolves |

The flat state vector is the authoritative data and the working array
is scratch (see [Time integration](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#time-integration)), so what is
stored is what an integrator holds, and restoring it is `scatter!`
followed by the ordinary ghost fill. Ghosts are a function of the owned
points, the operators and the boundary hook; all three are back after a
load, and a stored copy of the ghosts could only disagree with the one
the fill produces. The leaf list is the one thing that cannot be
recomputed, since a mesh is the product of every regrid since the
start. Regridding itself keeps nothing between calls — the buffer, the
marks and their completion are recomputed from the flags each time —
so there is no hidden mesh state to lose. (Parthenon, by contrast,
warns that an AMR run restarted without its per-block derefinement
counters may not be bitwise exact.)

**File layout, format version 1** (read by every later version — version 2, the files per I/O
process, follows the version-1 bullets). One HDF5 file. Everything
TreeAMR writes lives under one top-level group, `/TreeAMR.jl`, and the
application gets a top-level group of its own, named after it:

    /TreeAMR.jl/         attrs: format = "TreeAMR checkpoint",
                                format_version = 1,
                                features = ["brick"]  (must understand),
                                application = "<app name>"
      provenance/        scalar datasets: treeamr_version,
                         julia_version, created (UTC, ISO 8601),
                         hostname, nthreads, nranks (M7; 1 if absent),
                         project (Project.toml text, or ""),
                         manifest (Manifest.toml text, or "")
      forest/            attrs: D, N, connectivity = "brick",
                                roots (D), periodic (D),
                                reflecting (2, D), geometry_type
                                [, geometry_limbtype, geometry_nlimbs],
                                leaves_crc32c (M7; absent before)
        extents          (limbs?, 2, D), in the geometry type, bitwise
        root             Int32[nleaves]
        level            Int8[nleaves]
        coords           UInt32[D, nleaves]
      fieldsets/<name>/  attrs: eltype [, limbtype, nlimbs], nvars,
                                G (D), centering (D: "cell" | "vertex"),
                                parity ((D, nvars): "even" | "odd" |
                                "none"; absent when the set has none),
                                range = "owned"
        data             (limbs?, N, …, N, nvars, nblocks)
        data_crc32c      UInt32[nblocks] (M7; absent before)
    /<app name>/         attr: format_version (the application's own)
      data               the plain-data tree; beside it, whatever the
                         do-block writes
    /                    otherwise free, for sidecars (M9b)

- **One top-level group per package.** Neither TreeAMR nor the
  application writes at the root or into the other's group, so the two
  layouts, and their format versions, evolve independently. The
  `application` attribute names the application's group; a name that
  would collide with `TreeAMR.jl` is refused.
- **The root stays free for sidecars** (M9b). A visualization view can
  be added to the same file and point at these datasets without copying
  them: an HDF5 hard or soft link where the layout already matches, a
  virtual dataset where it has to be remapped (VTKHDF's per-level
  arrays, say). An external link from a separate file is the fallback.
- **Leaves are stored as columns, in global curve order** — the order
  of `forest.leaves` — so block `b` of every dataset is leaf `b`, and
  any contiguous range of blocks, such as an M7 rank's, is one
  hyperslab of every dataset.
- **No coordinates, and no partition.** Coordinates follow exactly from
  the key, the extents, `N` and the centering (see
  [Precision](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#precision)), so a stored copy could only disagree. The
  partition belongs to the process that wrote the file; a reader on
  another thread or rank count chooses its own.
- **The view from C.** HDF5.jl reverses dimensions, so a C or Python
  reader sees a field set as `(nblocks, nvars, N_D, …, N_1)`, slowest
  index first, as Parthenon stores its variables, and the coordinates
  as `(nleaves, D)`.
- **Contiguous when unfiltered; with filters, one chunk per block and
  variable**, `(limbs?, N, …, N, 1, 1)`, so that reading a block
  decompresses that block and no other. The filters are the caller's
  HDF5.jl filter objects, none by default, and TreeAMR depends on no
  filter package. **None is also the recommendation, and `Shuffle()`
  followed by H5Zzstd's `ZstdFilter(1)` the one filter to name when
  size matters** (the numbers and the reasons are
  under "Throughput and filters" below).
- `range = "owned"` says the data are the owned points only, and leaves
  room for a file that stores more, which a version-1 reader would
  refuse by value.
- **Checksums** (why they were added is under "Parallel
  checkpoints" in [HISTORY.md](HISTORY.md#parallel-checkpoints)).
  `leaves_crc32c` is the CRC-32C (Castagnoli) of the bytes of `root`,
  then `level`, then `coords`, each column whole, as stored; entry `b`
  of `data_crc32c` is the CRC-32C of block `b`'s bytes in `data`, the
  slice `data[…, b]` with all its variables and limbs, in the file's
  order. Both are over the little-endian bytes the file holds, so a C or
  Python reader can check them. A load verifies both and refuses a
  mismatch, with the reason that the file was damaged while or after it
  was written; over several ranks each rank checks the blocks it reads,
  and the verdict is agreed. A file without them, from before, loads
  unchecked.
  - *No format change*. They are an additive change with an
    obvious default, "not checked", so `format_version` stays 1 and
    nothing joins `features`: a reader that ignores them reads the file
    exactly as before. A feature would have made every file M7 writes
    unreadable to 0.1.4 for nothing a reader must understand. The 0.1.4
    reader was checked to load files with them, filtered and not.
  - *CRC-32C*, because it is in Julia's standard library (`CRC32c`,
    which TreeAMR now depends on), runs in hardware on x86-64 and
    AArch64 (13.7 GB/s on one thread of the development laptop, against
    the 1–2 GB/s of a save), and is defined outside Julia.
  - *Per block*, not per rank or per file, because the file stores no
    partition and loads on any rank count: each rank checks exactly the
    blocks it reads, and the checksums are written beside the data by
    the same slab. The leaf list, which every rank reads whole, has one.
  - *Not covered*: the extents, the provenance and the plain data, which
    are small and written by rank 0 alone, and HDF5's own metadata.
  - *Not HDF5's own checksums*. HDF5's Fletcher-32 filter was considered and is not
    used, for four reasons. It accepts an all-zero chunk, trailer
    included: on libhdf5 2.2.0 a chunk overwritten with zeros through
    `H5Dwrite_chunk` read back without an error, while one nonzero byte
    with a zero trailer was refused — and whole zeroed slabs are exactly
    the loss seen on BeeGFS, whereas the CRC-32C of zeros is not zero. Its
    checksum lives inside the chunk, so an intact chunk in the wrong
    place, or one left from an earlier write, verifies; ours are stored
    apart from the data and indexed by block. It needs chunked storage,
    which would leave the contiguous, unfiltered datasets uncovered. And
    it is weaker: 16-bit words, with 0x0000 and 0xFFFF ambiguous. HDF5's
    checksums of its own metadata, which the newer format structures
    carry (through the library-version bounds), are not enabled either.
  - *Over the parts*. A part file stores each field set's
    `data_crc32c` for its blocks, and the index's part table stores a
    CRC-32C of each of those arrays, so the index vouches for the
    per-block checksums and they for the data: a part from another save,
    or one whose checksums were damaged, is refused before its data are
    read.
- **Spellings**. Shapes above are in
  Julia's order, which C sees reversed. Every `Bool` in the file —
  `periodic`, `reflecting`, a plain-data `Bool` — is a `UInt8`, 0 or 1,
  because HDF5.jl would write an HDF5 bitfield, which other readers
  handle poorly. A `(lo, hi)` pair per dimension is a `(2, D)` array,
  which C sees as `(D, 2)`. The other scalars and small arrays are
  `Int64`, the leaf columns excepted. A `Float16`, which HDF5.jl does
  not predefine, is the IEEE half type built as h5py builds it, and a
  `Complex` is the compound `(r, i)`, as HDF5.jl and h5py spell it.

**File layout, format version 2** (the design is "Checkpoints without parallel I/O" under
[Distributed meshes](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#distributed-meshes)). A checkpoint is an *index
file* `path` and one *part file* per I/O process, `path.<saveid>.<j>.h5`;
with one I/O process the single part lives inside the index, so a
serial checkpoint is one file. The index is the version-1 file with the
field data moved out:

    path:
    /TreeAMR.jl/         attrs: format = "TreeAMR checkpoint",
                                format_version = 2, features = ["brick"],
                                application, save_id (32 hex digits)
      provenance/        as in version 1, and nparts (1 if absent)
      forest/            as in version 1, leaves_crc32c included
      fieldsets/<name>/  the layout attributes of version 1; no datasets
      parttable/         file        String[k]  (relative; "" for the
                                                 part inside the index)
                         first_block Int64[k]   (global leaf index, from 1)
                         last_block  Int64[k]   (first_block − 1 if empty)
                         bytes       Int64[k]   (the part file's size; 0
                                                 for the inline part)
                         fieldsets   String[s]  (the field sets, in order)
                         data_crc32c UInt32[s, k] (CRC-32C of each part's
                                                 data_crc32c, per set)
      parts/<jjjj>       an external link to `<file>:/TreeAMR.jl` per part
                         file, for tools; with one part, the part group
                         itself, inline (`jjjj` zero-padded to 4 digits)
    /<app name>/         as in version 1

    path.<saveid>.<j>.h5:
    /TreeAMR.jl/         attrs: format = "TreeAMR checkpoint part",
                                format_version = 2, save_id, part = j,
                                first_block, last_block
      fieldsets/<name>/
        data             (limbs?, N, …, N, nvars, last − first + 1)
        data_crc32c      UInt32[last − first + 1]

The inline part, `/TreeAMR.jl/parts/0000` of the index, has the part
file's `/TreeAMR.jl` attributes and contents. The datasets keep version
1's spellings, chunking and filters; a part's block axis is its own
range, so block `b` of the forest is entry `b − first_block + 1` of the
part that holds it. The parts tile `1:nleaves` in order, as the ranks'
ranges do.

**Rotating forests** (no format bump). A forest
with a rotating seam writes a `rotating` attribute in `forest/`, the
pair `(d1, d2)`, beside `reflecting`, and each of its field sets a
`rotation` attribute in `fieldsets/<name>/`, the signed map as
`Int64[nvars]`, beside `parity`. Such a file also lists `rotating` in
`features`, so a reader from before M12 refuses it, with the reason,
instead of loading the seam as two outer faces; a forest without a seam
writes neither the attributes nor the feature, so every file it writes
is readable by every earlier reader of its version. A file without the
attributes loads as non-rotating, which is the only reading of their
absence, so the version-1 fixtures still load. The load builds the
forest through the checked `leaves` path, which refuses a leaf list that
is not conforming at the seam, and the field set through its
constructor, which refuses a map that is not a valid rotation. A
`RotationPair` is not saved: like the operators, it is the application's
input, rebuilt from the two loaded sets. The attribute and the feature go together, and a file with
one and not the other — which no TreeAMR writes — is refused as
damaged, rather than read with the seam or without it. The pair is
`Int64[2]`, checked by the forest's constructor as a caller's would be;
a map is checked for its length here and as a map by the field set's.
The map joins what the ranks agree on about a field set before a save,
beside the parity.

**Outflow faces** (no format bump). A forest with an outflow face
(TreeAMR's `outflow` keyword) writes an `outflow` attribute in
`forest/`, shaped like `reflecting` — `UInt8` of shape `(2, D)`, C's
`(D, 2)`, one per face — and lists `outflow` in `features`, so that a
reader from before them refuses the file instead of loading those faces
as outer ones and filling their ghosts from the hook. A forest without
one writes neither, so its files are readable by every earlier reader
of the version, and a file without the attribute loads with no outflow
face, which is the only reading of its absence. As for the seam, the
attribute and the feature go together, and a file with one and not the
other is refused as damaged. Which faces may be outflow is checked by
the forest's constructor, as a caller's would be. The reflecting and
outflow faces are read from the forest through TreeAMR's
`reflecting_faces` and `outflow_faces`, since the forest stores the kind
of each face in one field.

**Symmetric walls** (no format bump). A field set built with
`walls = :symmetric` (TreeAMR's AMR-8, whose fill writes the owned low
wall plane of a vertex-like dimension at the domain's faces) writes a
`walls` attribute in `fieldsets/<name>/`, the string `"symmetric"`, and
the file lists `symmetric_walls` in `features`, so that a reader from
before them refuses it instead of rebuilding the set with half-open
walls, whose fill leaves those planes as they are. A set with half-open
walls writes nothing, so a file of such sets is readable by every
earlier reader of the version, and a set without the attribute loads
with half-open walls. A set with the attribute in a file without the
feature is refused as damaged, as is any value but `"symmetric"`. The
walls join what the ranks agree on about a field set before a save.

**Element types**.

- **Native types** — `Float16`, `Float32`, `Float64`, the signed and
  unsigned integers, `Bool`, and `Complex` of those — are stored as
  themselves, bit for bit.
- **An `isbits` type made of one native type throughout**, with no
  padding, is stored as **limbs**: a leading dimension of that native
  type, with `eltype` naming the type, `limbtype` the native type and
  `nlimbs` the count. MultiFloats' `Float32x2`, which the test suite
  uses (see [Precision](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#precision)), is two `Float32` limbs. The name
  is the type as a module importing nothing but Base prints it,
  `MultiFloats.MultiFloat{Float32, 2}` (not `string(T)`, which qualifies a name or not according
  to what the writer had imported into `Main`, so one type would be
  recorded under two names depending on how the run was started). The
  loader cannot name such a type without its package, so the caller
  passes it — `load_checkpoint(path; types = (Float32x2,))` — and the
  loader matches it by name and checks its size and its limbs against
  the file's. The name is a label to match against,
  not a recipe: without the type the data still read as plain `Float32`
  limbs, which is what a converter or a Python reader needs. The
  geometry type is treated the same way, for `extents`.
- **No conversion on load** in version 1. A field set comes back in the
  type it was saved in, since exactness is the point of a checkpoint;
  loading into a narrower type is an open question.

**Versioning**. This is also the answer to how files from
older versions are treated: what cannot be interpreted is rejected,
with the reason, and defaults are supplied where they are obvious.

- **Compatibility is decided by the file's `format_version` and its
  `features`, never by package versions.** Two releases may write the
  same format, and a release reads every format version it knows,
  whichever release wrote the file.
- **An additive change with an obvious default needs no bump**; the
  reader supplies the default. Had the format existed before M10, its
  files would have had no `reflecting`, and "no reflecting faces" is
  the only reading of that.
- **A change of meaning bumps `format_version`**, and a reader refuses
  a version newer than it knows.
- **A new capability that an old reader must not silently ignore** — a
  multi-block connectivity, say — adds a name to `features`, and a
  reader refuses a file that names a feature it does not know. This is
  Zarr v3's `must_understand` idea, with every listed feature
  must-understand: what may be ignored is simply not listed. Version 1
  lists one, `brick`. M12 adds `rotating`, listed only by a file whose
  forest has the seam (see "Rotating forests" above), and outflow faces
  add `outflow`, listed only by a file whose forest has one (see
  "Outflow faces" above), and symmetric walls `symmetric_walls`, listed
  only by a file holding a set that has them (see "Symmetric walls"
  above).
- **Refusals are `ArgumentError`s that say why.** They name the TreeAMR
  version that wrote the file, from `provenance`, and point to
  `checkpoint_environment(path, dir)`. That writes the stored
  `Project.toml` and `Manifest.toml` into `dir`, so that `julia
  --project=dir` recreates the writer's environment, and "use the older
  version" is one command.
- **Why the layout is plain and documented.** Two versions of TreeAMR
  cannot be loaded into one Julia process, so a converter from an old
  format cannot call the old package: it reads the old *file*. That
  works only if the file is plain HDF5 described here, with no Julia
  type a reader has to resolve. It is also why the format is neither
  JLD2 nor `Serialization`, both of which tie a file to the definitions
  of the types that wrote it.
- **The application's group carries its own `format_version`.** TreeAMR
  stores it and returns it and does not interpret it; the application
  checks it. Plain data written as NamedTuples come back as
  NamedTuples, so keyword defaults on the application's side are the
  good-default path for a field it adds later.

**Writing**.

- **Atomically.** The file is written to `path * ".partial"` and moved
  over `path` when it is complete; on any error the partial file is
  removed and the error rethrown. A crash while writing then cannot
  destroy the previous checkpoint, which is the one a restart needs.
  With part files, the parts are written and flushed first,
  under a fresh save id that no index names, and the rename of the index
  is the commit point; the previous index's parts are deleted only after
  it. See "Checkpoints without parallel I/O".
- **Durably, by default** (`sync = true`). Closing a
  file only hands its data to the operating system's page cache, which
  survives the process but not a power loss or a kernel crash; and the
  rename is a separate update of the directory, which can reach the
  disk before the data it points to, leaving `path` naming a truncated
  file with the previous checkpoint already gone. So the partial file
  is flushed to stable storage before the rename, and its directory
  after it, so that the rename is durable too. On Linux the flush is
  `fsync`; on macOS it is `fcntl(F_FULLFSYNC)`, because `fsync` there
  hands the data to the drive without waiting for the drive's own
  cache (1 ms against 125 ms for 540 MB), falling back to `fsync` on a
  file system without it; a directory that refuses an `fsync`
  (`EINVAL`) is accepted. HDF5 cannot do this itself: its flush, too,
  ends in the page cache. `sync = false` is for files that need not
  outlive the machine, such as a test's. What the flush costs is under
  "Throughput and filters" below.
- **Two forms per field set.** `name => (fs, u)` writes the state
  vector `u`, and is the recommended form: after `solve` the working
  array holds whatever the last right-hand side scattered, which is a
  stage, not the solution. `name => fs` gathers the owned points from
  `fs.work` first, which is right for a set whose working array is
  current by construction — an auxiliary set filled by
  `fill_by_coordinates!`, say.
- **Through the host.** Device data are copied to the host (`tohost`,
  in `src/device.jl`) before they are written.
- **One forest.** Every field set must be over the forest being saved
  (`===`), as for `regrid!`.
- **Filters are the caller's**, as above.

**Loading**.

1. The forest is built through the validated leaves path,
   `Forest{R}(roots; N, periodic, reflecting, extents, leaves)`, which
   refuses a list that does not tile the brick exactly or is not
   balanced, so that a damaged or hand-edited file cannot yield a mesh
   the schedule would silently get wrong.
2. `FieldSet{T}(forest, nvars; G, centering, parity, backend)`.
3. `u = statevector(fs)`: allocated on the backend and first-touched by
   the block owners, so NUMA placement is right although the HDF5 read
   that fills it is serial — placement is decided at the first touch,
   not by the later write. (Whether automatic NUMA balancing then moves
   pages that one thread touches is the unproven candidate in the
   [Open questions](#open-questions) item on the integrator's own
   passes; a load touches them once.)
   The read goes into `u`, through a host buffer on a device.
4. `scatter!(fs, u)`.

Ghosts are left to the application's `fill_ghosts!(fs,
GhostSchedule(fs, ops); boundary)`, with its own operators and hook.
The file does not hold those because they are the application's
inputs, the hook often a closure. Nothing stored depends on the thread
count or the backend, so a checkpoint loads on any of them, and the
load itself is exact everywhere. What follows is bit-identical at any
thread count, by the invariant under [Parallelism](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#parallelism);
across backends it is as close as a host run and a device run ever are
— bit for bit in the Burgers study on Metal, not promised in general.

**Throughput and filters** (measured 2026-09-29, `bench/checkpoint.jl`).
The machine is the development laptop — an Apple M3 Pro, 6 performance
and 6 efficiency cores, 36 GB, its internal SSD under APFS — with Julia
1.13.1 and HDF5.jl 0.17.4 over libhdf5 2.2.2. The mesh is 3D, 3296
blocks of `16³`, refined twice around the sphere `r = 1/2` (56, 1000
and 2240 blocks on levels 0, 1 and 2). It carries two `Float64` states,
each with its feature on the refined shell:

- `pulse`, a smooth outgoing spherical Gaussian `(u, ∂ₜu)`,
  vertex-centered, 216 MB — TreeWave's and TreeGeneralizedHarmonic's
  kind of data;
- `blast`, a blast wave in the five conserved variables,
  cell-centered, 540 MB: a smooth interior behind a discontinuity and a
  uniform atmosphere outside it, the same bits everywhere — TreeHydro's
  kind.

Throughput is in GB/s of state data (owned points, 1 GB = 10⁹ bytes),
the best of five calls after one that compiles. `save` is
`save_checkpoint(…; sync = false)`, which ends in the page cache;
`sync` is the default, `sync = true`, which adds the flushes of the
file and of its directory to stable storage (on macOS
`fcntl(F_FULLFSYNC)`: a plain `fsync` there returned in 1 ms for 540
MB, against 125 ms for the full flush, so it proves nothing). `load` is
all of `load_checkpoint`, at one thread and at six; the saves are the
one-thread run's. One chunk is one block and variable, 32 KB. The
ratio is the state's size over the file's.

| data | filter | ratio | save | sync | load, 1 thread | load, 6 threads |
|---|---|---|---|---|---|---|
| pulse | none | 1.00 | 5.3 | 4.0 | 1.11 | 3.65 |
| pulse | `Shuffle` + `Deflate(1)` | 1.34 | 0.10 | 0.10 | 0.25 | 0.30 |
| pulse | `Shuffle` + zstd 1 | 1.32 | 0.62 | 0.61 | 0.73 | 1.37 |
| pulse | `Shuffle` + zstd 3 | 1.34 | 0.45 | 0.44 | 0.72 | 1.34 |
| pulse | `Shuffle` + LZ4 | 1.30 | 0.82 | 0.80 | 0.74 | 1.55 |
| pulse | bitshuffle + LZ4 | 1.19 | 0.58 | 0.59 | 0.52 | 0.77 |
| blast | none | 1.00 | 6.4 | 3.9 | 1.20 | 3.98 |
| blast | `Shuffle` + `Deflate(1)` | 6.00 | 0.32 | 0.32 | 0.49 | 0.68 |
| blast | `Shuffle` + zstd 1 | 6.14 | 1.06 | 1.02 | 0.76 | 1.36 |
| blast | `Shuffle` + zstd 3 | 6.23 | 0.90 | 0.88 | 0.76 | 1.37 |
| blast | `Shuffle` + LZ4 | 5.68 | 1.20 | 1.18 | 0.86 | 1.75 |
| blast | bitshuffle + LZ4 | 4.85 | 0.64 | 0.63 | 0.52 | 0.76 |

zstd is H5Zzstd's `ZstdFilter(level)`, LZ4 H5Zlz4's `Lz4Filter()`, and
bitshuffle H5Zbitshuffle's `BitshuffleFilter(compressor = :lz4)`. Blosc
was not measured. **Bitshuffle with zstd cannot be measured with the
registered H5Zbitshuffle** (0.1.3): it calls `bshuf_compress_zstd`
without its last argument, `comp_lvl`, so zstd compresses at whatever
level the argument register happens to hold. The same data and the
same `comp_level = 1` came out 175.3 MB at 0.02 GB/s in one process and
181.6 MB at 0.35 GB/s in another — though bit for bit readable in both.
HDF5.jl's unreleased 0.18, where the filter moves into an extension,
passes the level. This table is the second of two measurements the
same day; across the six runs, the unfiltered save varied between 4.6
and 7.3 GB/s and its flush to stable storage between 2.9 and 5.4, while
a filtered save agreed within 15 %, with no trend in the thread count.
The laptop was in use, with a video call and an endpoint-security
agent that scans written files taking about a core, so these are its
numbers, not a quiet node's. The flush costs an unfiltered save of
540 MB about 50 ms here, and a filtered one nothing measurable, which
is why `sync = true` is the default.

- **No filter is the recommendation.** Unfiltered, a save reaches the
  page cache at 5–7 GB/s and stable storage at 3–5, and a load runs at
  2.8–4.0 GB/s on six threads. A smooth field compresses 1.3-fold at
  best, because the low mantissa bits of smooth data are noise to a
  lossless coder, and every filter buys that with 9 to 70 times the
  save time. A checkpoint is written to be read once, if at all.
- **When size matters, `Shuffle()` then `ZstdFilter(1)`.** Data that
  are mostly a uniform atmosphere are where a filter pays: 6.1-fold at
  1.0 GB/s saved, within 1.5 % of level 3's ratio and 1.2 times its
  speed. `Shuffle` with LZ4 is 12 % faster at 8 % less ratio, the
  choice if time matters more. The built-in `Deflate(1)`, the only
  filter every HDF5 has, gets less ratio at a third of the speed on
  such data, and on smooth data it is six times slower than zstd, at
  0.10 GB/s. Bitshuffle with LZ4 loses to byte shuffle with LZ4 on both
  counts at this chunk size.
- **A filtered file needs its filter to be read.** In Julia the
  filter's package is loaded before `load_checkpoint` (`using
  H5Zzstd`), and in C or Python the HDF5 plugin is installed (h5py's
  through hdf5plugin). Without it the read fails with HDF5's own error,
  a plugin it cannot find, and not with a refusal that says why (an
  open question).
- **Compression is serial.** HDF5 runs the filter pipeline chunk by
  chunk on the calling thread, so a filtered save gains nothing from
  threads, and a filtered load gains only the part of it that is not
  HDF5's. Over a distributed forest each I/O process compresses its
  group's chunks, so a filter parallelizes over the I/O processes —
  every rank under `io = :all`, one per node under the default.
- **Where an unfiltered load goes.** For the 540 MB state at one
  thread, 470 ms: the field set's allocation and zero fill 157, the
  state vector's first touch 84, the HDF5 read 87, `scatter!` 134, the
  validated forest 20. At six threads the threaded parts fall to 27,
  13, 30 and 6 ms, and the read, 82 ms, is half of the 156.
- **The loads read the page cache.** A load right after a save reads
  the file the save just wrote, so the load numbers are decompression
  and memory bandwidth, not the SSD's read rate. A cold-cache load
  needs the cache dropped first (`purge` on macOS, `drop_caches` on
  Linux, both root-only) and was not measured. The numbers that matter
  for a production run are the cluster file system's, which
  `TREEAMR_BENCH_DIR` points the benchmark at, and belong to M7's
  parallel-I/O measurement. (They are under M7's steps 6, for the shared
  file, and 6b, for the part files that replaced it, in
  [HISTORY.md](https://github.com/eschnett/TreeAMR.jl/blob/main/HISTORY.md#milestones).)

The facts about parallel HDF5 checked before M7, the shared-file design they led to, and why it was replaced by the part files are in [HISTORY.md](HISTORY.md#checkpoint-and-restart) and under "Checkpoints without parallel I/O" in [Distributed meshes](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#distributed-meshes).

**Multi-block**. Keys are relative to their root,
`connectivity = "brick"` is a tagged record rather than an assumption,
and no coordinates are stored. A conforming multi-block forest, the
likely route to spherical domains, is then a new connectivity kind,
with whatever describes its roots stored beside the leaves, plus a
feature name. Nothing in the format obstructs it. Parthenon's layout
would: it stores global tree locations in one virtual tree over the
root grid, which a multi-block forest cannot express.

The survey of existing formats that this layout follows from (formats considered, and the one modelled) is in [HISTORY.md](HISTORY.md#checkpoint-and-restart).

**The API in brief**. `fieldsets` and `application` have no defaults,
and the refusals say why.

    # TreeAMR: a forest from a validated leaf list
    Forest{T}(roots; N, periodic, reflecting, extents, leaves)

    # TreeIOHDF5
    save_checkpoint(path, forest;                    # returns path
                    fieldsets   = ("U" => (U, u), "aux" => aux),  # or ()
                    application = "TreeHydro" => 1,  # name => its version
                    data = (; t, chunk, recipe), filters = (),
                    sync = true,                     # flush to stable storage
                    io = :node)                      # I/O processes
    save_checkpoint(path, forest; …) do app::HDF5.Group
        # further datasets in the application's group, beside `data`
    end
    ck = load_checkpoint(path; backend = CPU(), types = (),
                         fieldsets = nothing,        # or names, a subset
                         comm = nothing)             # or an MPI.Comm (M7)
        # ck.forest, ck.fieldsets["U"].fieldset, ck.fieldsets["U"].state,
        # ck.application, ck.data, ck.provenance
    load_checkpoint(path; …) do app … end        # result in ck.result
    write_plain(parent, name, value); read_plain(parent, name)
    checkpoint_environment(path, dir; force = false)  # returns dir

- **The `leaves` keyword validates**, in the tone of the other
  refusals: every root index is below `prod(roots)`; the keys are
  strictly sorted, which also refuses duplicates; the leaves tile the
  brick exactly, checked by one walk along the curve (each leaf starts
  where the previous leaf's subtree ends, and every root is covered);
  and the list is balanced (`isbalanced`). An unbalanced list is
  refused rather than rebalanced, because it cannot have come from a
  forest, and `block_sources!` would silently build wrong prolongations
  from it. `MortonKey`'s own checks cover each key.
- **Plain data are a closed, documented set of types**: `Bool`, `Int8`
  to `Int64` and `UInt8` to `UInt64`, `Float16`, `Float32`, `Float64`,
  `Complex` of those, `Rational`s of the native integers, `String`,
  `Symbol`, `VersionNumber` and `Nothing`; tuples, NamedTuples, and
  `AbstractDict`s with `String` or `Symbol` keys; and arrays of native
  numbers or strings. Every item is a dataset or group with a `type`
  attribute from a closed vocabulary — `number`, `rational`, `string`,
  `symbol`, `version`, `nothing`, `array`, `tuple`, `namedtuple`,
  `dict` — with `eltype` naming a number's or an array's element type
  (`"String"` for strings) and `keytype` (`"String"` or `"Symbol"`) on
  a dict. A Rational is the dataset `[numerator, denominator]` in its
  integer type; a nonempty tuple of one native number type is one
  array, and any other tuple a group of the items `"1"`, `"2"`, …; and
  groups keep their order (`track_order`), so a NamedTuple keeps its
  field order. A NamedTuple comes back as a NamedTuple and a Dict as a
  `Dict{String,Any}` or `Dict{Symbol,Any}`, an array as an `Array`.
  Anything else is an `ArgumentError` that says to convert it to a
  NamedTuple: structs are the application's to convert (`to_plain`,
  `from_plain` on its side), so no type name reaches the file.
  Rationals store exactly, and TreeHydro already states its parameters
  as Rationals, so a case recipe round-trips exactly.

**Where a checkpoint belongs in a chunked driver**. The
downstream drivers integrate in chunks: `solve` over a fixed number of
steps, then flag, regrid, rebuild the schedules and restart the
integrator (see [Regridding](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#regridding)). A checkpoint goes at a
chunk boundary, *after* the regrid. There the integrator holds nothing
but `(t, u)`, for the fixed-step explicit methods every downstream
application uses, so restoring `t` and `u` restores the integrator —
a step size computed from the forest or the state comes out the same —
and a restarted run begins the next chunk with exactly what the
uninterrupted one began it with. Mid-chunk, the integrator's own state
(its stages and cached derivatives) would have to be saved too; before
the regrid, a restart would have to replay the regrid and whatever the
application does after it, such as TreeHydro's atmosphere reset. The
application's run state — the time or chunk index, histories, trackers
— goes in its plain data.

## Checkpoints over MPI

**Parallel checkpoints.** The shared-file checkpoint that preceded
"Checkpoints without parallel I/O" — one file written through parallel
HDF5 and MPI-IO — its four-node account on Symmetry and the ROMIO
findings that led to its replacement are in
[HISTORY.md](HISTORY.md#parallel-checkpoints). What carries over from it:

- *The agreement.* Before the file is created every rank runs the
  serial checks — the field sets, `application`, the geometry type —
  and walks `data` the way `write_plain` will write it, refusing what it
  would refuse, with the same messages, and folding a hash of every
  item's name, type and bits. One `allgather` carries a `ForestDigest`
  (the full one: a forest that differs would write a corrupt leaf
  list), the hash of the path and every keyword but `data` as its
  layout, and the data hash, and `digest_verdict` gives the verdict, the
  data a message of its own. A load agrees on its arguments the same
  way, with rank 0 alone checking that the file exists and is HDF5;
  what the file holds is the same for every rank, so a refusal of its
  contents comes on every rank at the same point without a message.
  Serially the walk runs too, so a value outside the plain-data types is
  now refused before the file is created rather than while it is
  written, with the same message.
- *How much of the plain data is checked*: all of it, by
  that hash, once per `save_checkpoint` and once per `write_plain` in
  the do-block. Two reasons. Under the collective contract a value that
  differs between ranks need not fail: an attribute written with
  different values is undefined in parallel HDF5, which does not check
  it, and a dataset that rank 0 writes alone would silently record rank
  0's value, so a restart would read one rank's run state as
  everyone's. And the
  cost is a walk over values that are small next to the field data, plus
  one collective per call. What the do-block writes through HDF5 itself
  is not checked; the docstring says it must be the same on every rank.

- *Checksums*. The leaf list and every
  block of every field set carry a CRC-32C, verified on load, with the
  verdict agreed across ranks; the format and the reasons are under
  "Checksums" in [Checkpoint and restart](#checkpoint-and-restart).
  They are not the remedy — damage refused is still a lost checkpoint
  — but they are the defence for file systems and MPI-IO
  implementations this was not measured on: the next such loss is
  refused with its reason instead of restored into a wrong state. A
  damaged field set would have been restored: only the leaf list's own
  validation caught this one, and only because zeros broke the curve
  order.

**Checkpoints without parallel I/O** (it
replaces the shared file of "Parallel checkpoints" above, whose
four-node account is the reason). Writing one file
from several nodes was not reliable on Symmetry, and the remedy found
there — two ROMIO hints — is specific to one MPI-IO implementation on
one file system, while the same measurement showed NFS losing whole
pages to plain `pwrite`s from several nodes. Smaller clusters may fail
in ways of their own, and a checkpoint that can be lost is not one. So
no file of a checkpoint is ever shared between processes:

- **One writer and one opener per file**. Every file a
  checkpoint consists of is created and written by exactly one process,
  and on reading opened by exactly one process. HDF5 is used serially
  only, so nothing depends on MPI-IO, its hints, or a file system's
  coherence between clients. `TreeAMRHDF5MPIExt`, `open_parallel_file`,
  `librarycomm` and the hints are removed, and HDF5_jll need
  no longer be a parallel build or match the MPI: the stock one still
  is, which is harmless, and any other serves.
- **I/O groups.** The ranks are split into `k` contiguous groups in rank
  order, by the equal-count split that partitions the blocks
  (`equalsplit`); the first rank of each group is its *I/O process*, and
  the others its members. The ranks own contiguous runs of the curve in
  rank order, so a group's blocks are one contiguous run of the curve,
  and its part of every field set is one range of blocks. The keyword
  `io` of `save_checkpoint` chooses `k`:
  - `io = :node`, the default: one per shared-memory node.
    `k` is the number of nodes, which a verb, `commnodes`, counts
    from `MPI_Comm_split_type(MPI_COMM_TYPE_SHARED)`; its serial method
    answers 1. A node's client is the unit a cluster file system caches
    and is fed by, and one file per node keeps the number of files, and
    the metadata server's load, at the number of nodes.
  - `io = :all`: every rank writes its own part, and nothing is sent.
  - An integer `k ≥ 1`, used as it is up to the rank count and clamped
    to it beyond (an I/O process with no member is a rank
    writing its own part, so a larger `k` can mean nothing else).
  - *Nodes whose ranks are not contiguous*. The groups
    are always contiguous, equal-count rank ranges; `:node` sets `k`
    only. Under the usual block placement of ranks (SLURM's `block`
    distribution, `mpiexec`'s by-slot default) the groups are then
    exactly the nodes and every message stays on its node. Under a
    round-robin placement, or with unequal counts per node, a group
    spans nodes and its messages cross the network, which costs time
    and nothing else. Contiguity is worth more than locality: it is what
    makes a part one range of blocks, which one reader can send back
    out as contiguous ranges at any other rank count.
- **Files**. Beside the *index file* `path`, which rank 0
  writes, each I/O process writes one *part file*,
  `path.<saveid>.<j>.h5` for its group `j in 0:k-1`, in the index's
  directory. The save id is 128 random bits drawn by rank 0
  (`RandomDevice`) and written as 32 lowercase hex digits; it is
  recorded in the index and in every part, with the part's number and
  block range, so that a part from another save — the previous one, or
  one that crashed — is refused rather than read. With one I/O process
  (a serial run, `io = 1`, or one node under `:node`) the single part
  lives inside the index file, so a serial checkpoint is still one
  file. The layout is format version 2, under "File layout, format
  version 2" in [Checkpoint and restart](#checkpoint-and-restart).
- **Writing.**
  1. Every refusal is decided before anything is created and agreed
     across the ranks.
  2. Rank 0 draws the save id and broadcasts it (the verb `bcast`,
     with a serial method).
  3. Each member sends its owned data — the state vector, on the host;
     a device field set through `tohost` as before — to its I/O
     process: the members in curve order, a member's per-block
     CRC-32Cs first and then its blocks, in messages of whole blocks of
     at most 1 GiB each (one block if a block is larger; 64 MiB as
     implemented, see below). The I/O
     process writes each message as it arrives, by hyperslab, with the
     next receive already posted, so it holds at most two messages and
     never its group's data whole. It checks every block it receives
     against the member's CRC before writing it, so a block damaged in
     transit is refused rather than written.
  4. The I/O process writes its part's `data_crc32c`, closes the part
     and, under `sync = true`, flushes it and then its directory to
     stable storage (`flush_to_storage`). It reports success, the
     part's size in bytes, and a checksum of each field set's
     `data_crc32c` to every rank, in one `allgatherv`, which is also the
     verdict: if any I/O process failed, every rank throws and each I/O
     process removes its new part. Nothing is committed.
  5. Rank 0 writes `path * ".partial"`: the format attributes, the
     provenance, the forest, the field sets' layouts, the part table,
     the external links, and the application's group, the do-block's
     writes included. Under `sync = true` it flushes the file, renames
     it over `path` (`Base.Filesystem.rename`), which is the commit
     point, and flushes the directory; the verdict on that is agreed.
  6. Only then does rank 0 delete the parts the previous index named,
     read from it before the commit, and every *orphan*: a file in the
     index's directory whose name is exactly `basename(path)`, a dot,
     32 lowercase hex digits, a dot, decimal digits and `.h5`, with a
     save id other than this one. A failure to delete is a warning, not
     an error, since the checkpoint is in place.

  A crash at any point before the rename leaves the previous index and
  every part it names intact, plus at worst new parts that no index
  names, which the next save removes; a crash after it leaves the new
  checkpoint complete and at worst old parts, removed the same way. An
  I/O process whose writing fails goes on receiving everything its
  members send, without writing it, so that no member waits forever in
  a send, and the failure arrives in the verdict. An error of the MPI
  library itself remains fatal to the job. The cost of the cleanup rule
  is that a copy of the index under another name in the same directory
  does not keep its parts: an earlier checkpoint is kept by saving to
  another path, or by moving the index and its parts to another
  directory together, which keeps their relative names valid.
- **Reading.**
  1. The arguments are agreed, and only rank 0 opens the index. With
     one rank it reads it directly. Otherwise it copies everything but
     the part data — the `/TreeAMR.jl` group's attributes, the
     provenance, the forest, the field sets' layouts, the part table
     and the application's group — into an in-memory HDF5 file (the
     core driver, without a backing store) and broadcasts its bytes,
     and every rank opens that image (HDF5.jl's `h5open(bytes)`, which
     sets the file image). HDF5 itself serializes the forest and the
     plain data, so no serializer is needed. A refusal of the file
     itself — it is missing, or is not a checkpoint — is rank 0's, and
     is broadcast in place of the image, so it is raised on every rank;
     what the image holds is the same everywhere, so a refusal of its
     contents comes on every rank at the same point without a message.
  2. Each part is read by exactly one rank: the owner, under the new
     partition, of the part's first block, moved on to the next rank
     while that one already reads `cld(k, P)` parts, so that no rank
     reads more than its share when that is possible. The assignment is
     a function of the replicated part table, the same on every rank.
  3. Each reading rank opens its parts and checks each against the
     index: that it is a part, its save id, its number and block range,
     its size in bytes, and the checksum of each field set's
     `data_crc32c`. The verdict is agreed before any data move, so a
     missing part, a part from another save, or a truncated one is
     refused on every rank.
  4. Each owner posts its receives, straight into its state vector. The
     reader reads, for each field set, the part's blocks in the range
     each owner needs — contiguous, so a part goes to a contiguous run
     of ranks — by hyperslab, in pieces of at most 1 GiB (64 MiB as
     implemented), checks each
     block's CRC-32C, and sends it, with at most two pieces in flight; a
     piece for itself it reads in place. A reader whose read fails goes
     on sending, so no owner waits forever, and the damage and failure
     verdict is agreed afterwards: a block that fails its checksum is
     refused on every rank.

  A version-1 file is read as one inline part covering every block, by
  rank 0, which already has it open; so a version-1 file, written
  serially or by the shared-file writer, loads on any rank count.
  Loading on a different rank count, and serially, works for every
  combination, as it did.
- **The do-block runs on every rank**, as it did. Rank 0's application
  group is the index's; every other rank gets the same group in an
  in-memory scratch file, discarded afterwards, so that a block that
  calls collective operations still runs on every rank. `write_plain`
  in it still agrees its value across the ranks, so what rank 0 writes
  is what every rank passed; a dataset the block writes through HDF5
  itself is kept from rank 0 alone and must be the same on every rank.
  On loading, each rank's block gets the application group of its
  image.
- **External links for tools**. For
  each part file the index holds an HDF5 external link,
  `/TreeAMR.jl/parts/0003` → `ckpt.h5.<saveid>.3.h5:/TreeAMR.jl`, so
  that `h5dump`, h5py and HDFView navigate from the index into every
  part. TreeAMR's loader never traverses them: traversing an external
  link opens its target, which would have rank 0 open every part, and
  the other ranks hold the index only as an image. It takes the part
  names from the part table and resolves them against the index's
  directory itself. *The shadowing caveat*, for external tools: HDF5
  resolves a relative external link by trying a prefix
  (`HDF5_EXT_PREFIX`, or the link access property), the current
  working directory and the directory of the file holding the link, and
  HDF5's documentation lists the working directory before the parent's
  directory — so a tool started in another directory may open a
  same-named file there instead of the part. (Checked 2026-10-02:
  libhdf5 2.2.0, HDF5_jll's, and h5dump 2.1.1 resolved the parent's
  directory first, and fell back to the working directory only when the
  part was missing there; older libraries may not.) TreeAMR's own
  reader cannot be misled either way.
- **Format version 2; the reader reads 1 and 2.** The parts change what
  a file is, so the version is bumped, as "If the shared file does not
  hold up, M7 bumps `format_version`" accepted. 0.1.4 refuses a
  version-2 file with its format-version refusal, saying it was written
  by a newer TreeAMR and naming `checkpoint_environment` (accepted, by
  the versioning rules).
- **What carries over from the shared file**: the CRC-32C checksums per block and
  of the leaf list, now with a checksum per part and field set in the
  index above them; the refusals agreed before anything is created; the
  plain-data agreement; the self-checking benchmark, which loads every
  save it times; and the BeeGFS reproducers, whose `save_checkpoint`
  modes now exercise this writer and whose MPI-IO and POSIX modes
  remain as regression jobs for the file system. The shared-file
  layout, the collective transfers, the fixed-length string arrays
  (parallel HDF5 wrote no variable-length data) and the hints do not.

- *The save id* is drawn from `Base.Libc.getrandom!`, which is what
  `RandomDevice` reads, and not from `rand`: an application that seeds
  the global generator the same way in every run would draw, in a
  restarted run, the id of the checkpoint it restarted from, and its
  parts would overwrite that checkpoint's before the commit. An I/O
  process also refuses to create a part file that exists already.
- *The gathering's messages.* Per field set and member, first a vector
  of `UInt32`: a status word, then the member's per-block CRC-32Cs; then
  its blocks in pieces of whole blocks. A member that cannot prepare
  its data (gather it, copy it to the host) sends the status 1 and no
  blocks, and its own error comes in the verdict, so its I/O process
  never waits for blocks that are not coming. The I/O process holds two
  receive buffers of at most one piece each and writes its own blocks
  straight from its state vector. The I/O process receives every member's
  checksums first, queues all the members' pieces in curve order, and
  keeps the next piece in flight while it writes the current one — the
  first while it writes its own blocks — and a piece is at most 64 MiB,
  so a member's blocks are several. It is kept for the memory it
  bounds (the measurements are under M7 step 6b in
  [HISTORY.md](https://github.com/eschnett/TreeAMR.jl/blob/main/HISTORY.md#m7--mpi)).
- *An empty part is stored contiguously*, without filters: HDF5 refuses
  a chunk larger than a fixed dataset whose extent is 0, which a group
  whose ranks hold no blocks would otherwise need.
- *Version 2 requires its checksums*: a part without `data_crc32c`, or
  an index without `leaves_crc32c`, is refused as damaged; in a version-1
  file they stay optional.
- *The agreements.* Every step that runs on some ranks only — the parts,
  the index and the do-block, the commit, opening the parts, reading
  them — ends in one `allgather` of whether each rank failed and an
  `allgatherv` of the messages (`agree_errors`). A rank that failed
  throws its own error; every other rank throws one that quotes the
  first failing rank's message, an `ArgumentError` when that was a
  refusal, so the reason is on every rank's screen. The commit's verdict
  also carries whether the rename happened: if only the directory flush
  after it failed, the new checkpoint is the one at `path`, and its
  parts are kept.
- *The cleanup runs on rank 0 after the others have returned.* It
  touches only files of earlier saves, and the next collective call
  orders it before anything else the ranks do with the directory (the
  MPI test waits at a barrier before it lists the directory). Of the
  names the previous index lists, only those of the part form — a
  `.`, 32 hex digits, a `.`, digits and `.h5`, no `/` — are removed, so
  a damaged index cannot make a save remove any other file.
- *Flushing.* Each I/O process flushes its part and then the directory,
  so the part's directory entry is durable before an index names it;
  rank 0 flushes the index, renames it, and flushes the directory.
- *The index image.* The `/TreeAMR.jl` group's attributes and the field
  sets' layout attributes are copied attribute by attribute, as HDF5.jl
  reads and writes them, and the provenance, the forest, the part table
  and the application's group by `H5Ocopy` (HDF5.jl's `copy_object`),
  which keeps a group's creation order, so a NamedTuple's fields come
  back in order (checked). The image is created with the core driver
  and no backing store, so nothing touches the disk.
- *Reading.* A reader reads a piece for itself straight into its state
  vector, and for another rank into one of two send buffers, waiting on
  that buffer's previous send first; the pieces are cut as the
  gathering's are, so both ends agree on them without a message.
- *Plain data.* Without parallel HDF5 an array of strings is
  variable-length again, as in M9a. A string or `Symbol` holding a NUL is
  now refused by the plain-data walk, serially too, before anything is
  written: HDF5 stores a C string, and HDF5.jl refused it in the middle
  of the write.

The feasibility check of parallel HDF5, from before TreeAMR's M7 was
built, is in [HISTORY.md](HISTORY.md#checkpoints-over-mpi).

## Tests

`test/runtests.jl` includes TreeAMR's test helpers, copied verbatim —
`oracles.jl`, `ghost_oracles.jl`, `wave.jl` and `burgers.jl` — and then
`checkpoint_tests.jl`, `device_tests.jl` (the device round trip; the CPU
always, and CUDA or Metal with `TREEAMR_TEST_BACKEND`), `partition_tests.jl`
(a save over a communicator that lacks a verb is refused by its name) and
`mpi_tests.jl`.

`checkpoint_tests.jl` checks a bitwise round trip over every centering,
`Float64`/`Float32`/`Float32x2` and every face kind, restarts of the
wave and Burgers studies that continue byte for byte through regrids,
the refusals with their reasons, the checksums (a damaged block, a
recomputed one, missing ones), the atomic write and a failing I/O
process, plain data and `checkpoint_environment`, and that the
version-1 files in `test/fixtures/` (written by the step-6 writer)
still load; the leaf-list `Forest` it loads through is tested in
TreeAMR's `runtests.jl`, against the oracles. The part files themselves are
`mpi_workload.jl`'s: saves with `io = :all`, `2` and `:node`, a part
from another save, a missing part, orphans, a failed I/O process, and
the `OPEN_LOG` hook showing that no file is opened by two processes.

**Over MPI**, `mpi_tests.jl` runs the standalone `mpi_workload.jl`
serially in process (the reference) and under `MPI.mpiexec()` at `-n 3`
and `-n 2`, one thread a rank, and requires every line byte for byte
except the `sum` lines, as TreeAMR's MPI test does; `test/mpi_jobs.jl`
starts both jobs at the start of the suite where the machine has room.
The workload is TreeAMR's, reduced to the cases that end in a checkpoint
— a rank without blocks (E2), a rotating quadrant and its pair (Q2), a
single leaf at the axis (QE2) — and the chunked restarts (C, C1) and the
refusals. Each run writes its files to one directory
(`TREEAMR_CHECKPOINT_DIR`), and a run that loads another rank count's
files waits for that run's marker (`TREEAMR_CHECKPOINT_FROM`), so the
serial reference, three ranks and two ranks may run at once.

## Open questions

- **What M9a leaves open** (see
  [Checkpoint and restart](#checkpoint-and-restart)). None of it is
  needed to restart a run.
  - Conversion on load, such as `Float64` into `Float32` for a device
    without fp64. Version 1 loads the saved type only, since exactness
    is the point of a checkpoint.
  - Partial loads: a subset of a field set's variables, or a range of
    blocks.
  - Appendable time series: several states in one file.
  - An ADIOS2 backend, if parallel HDF5 does not scale at M7. The data
    model maps one-to-one onto ADIOS2 variables (the datasets) and
    attributes.
    **Inconsistent:** this item is conditional on parallel HDF5 at M7,
    which M7 replaced by part files written serially.
  - A refusal for a missing filter. A
    file saved with H5Zzstd's filter and loaded without `using H5Zzstd`
    fails with HDF5's `H5Error`, a plugin it cannot find in a build
    directory, rather than with a reason. The loader could read the
    data set's filter pipeline first and name the filter and the
    package that provides it.
- *Compression where the data are*. With `io =
  :node` one process per node runs HDF5's filter pipeline for the
  node's blocks, serially, so a filtered save is bounded by one core's
  compression per node (blast with zstd(1) on four nodes: 1.45 GB/s,
  against 4.50 with `io = :all`; step 6b's record). The members could
  compress their own chunks and send them compressed, for the I/O
  process to write with `H5Dwrite_chunk`, and a load could send
  compressed chunks to their owners (`H5Dread_chunk`); either needs the
  filter pipeline outside HDF5's own write, which HDF5.jl does not wrap.
  Until then `io = :all`, or a larger integer, is the setting for a
  filtered save; whether that should be the default is Erik's to decide.
- **Another backend.** TreeAMR's design said: "checkpoint and restart
  through HDF5.jl, as a package extension, as specified under Checkpoint
  and restart. Visualization export is M9b; an ADIOS2 backend only if
  parallel HDF5 does not scale at M7 (see Open questions)." 

  **Inconsistent:** the I/O bullet makes an ADIOS2 backend conditional on parallel HDF5 not scaling at M7, but M7 replaced the parallel-HDF5 checkpoint by part files written serially ("Checkpoints without parallel I/O" under [Distributed meshes](https://github.com/eschnett/TreeAMR.jl/blob/main/CODE.md#distributed-meshes)).
