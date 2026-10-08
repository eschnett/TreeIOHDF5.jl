# TreeIOHDF5.jl

Checkpoint and restart for [TreeAMR](https://github.com/eschnett/TreeAMR.jl)
meshes, through HDF5. TreeIOHDF5 is a companion package of TreeAMR: it
provides infrastructure, and so it uses TreeAMR's internals and is tied
to exact TreeAMR versions (TreeAMR's `CODE.md`, "Companion interface");
an application uses only its exports. The file format is specified in
this package's `CODE.md`.

## Checkpoints and restarts

A long run stops and resumes through a checkpoint: [`save_checkpoint`](@ref)
writes the forest, the field sets the application evolves and its own
run state to one HDF5 file, and [`load_checkpoint`](@ref) reads them into
fresh objects in a new process — on any thread count and any backend —
exactly. The two come with `using TreeIOHDF5`.

What is stored is what cannot be recomputed: the forest's parameters and
leaf list, and each field set's layout and **owned** points. The ghosts
are not stored, since they follow from the owned points, the operators
and the boundary hook, and the last two are the application's own; after
a load it fills them as it would at any right-hand side. The run state —
the time, the chunk index, histories — goes in `data`, as plain data
(see [`write_plain`](@ref)), and comes back as it went in:

```jldoctest checkpoint
julia> using TreeAMR, TreeIOHDF5

julia> forest = Forest((2, 2); N = 8, periodic = (true, true));

julia> refine!(forest, forest.leaves[1]); balance!(forest);

julia> fs = FieldSet(forest, 1; G = 2);

julia> fill_by_coordinates!((x, v) -> sinpi(x[1]) * cospi(x[2]), fs);

julia> u = statevector(fs); gather!(u, fs);

julia> path = joinpath(mktempdir(), "run.h5");

julia> save_checkpoint(path, forest; fieldsets = ("u" => (fs, u),),
                       application = "MyApp" => 1, data = (; t = 0.25, chunk = 3));

julia> ck = load_checkpoint(path);

julia> ck.forest.leaves == forest.leaves
true

julia> ck.application, ck.data
("MyApp" => 1, (t = 0.25, chunk = 3))

julia> restored = ck.fieldsets["u"].fieldset;

julia> ck.fieldsets["u"].state == u
true

julia> ops = Operators(prolongation = 4, restriction = 4);

julia> fill_ghosts!(restored, GhostSchedule(restored, ops));

julia> fill_ghosts!(fs, GhostSchedule(fs, ops));

julia> restored.work == fs.work
true
```

A checkpoint belongs at a chunk boundary, *after* the regrid, where a
fixed-step integrator holds nothing but `(t, u)`: a restart then begins
the next chunk with exactly what the uninterrupted run began it with.
Pass `name => (fs, u)` for an evolved set — after `solve` its working
array holds a stage, not the solution — and leave scratch sets such as
fluxes out. The file is written beside `path` and renamed over it only
when complete, so a failed write never destroys the previous checkpoint.
A serial checkpoint is one file; a distributed one adds a part file per
I/O process beside it (see [Over MPI](@ref)).

Compression is HDF5's, through `filters`. None is the default and, by
the measurements in the design document, the recommendation: smooth
data compress only about 1.3-fold, at many times the cost. When size
matters, `filters = (HDF5.Filters.Shuffle(), H5Zzstd.ZstdFilter(1))`,
after `using H5Zzstd`, shrinks a state that is mostly uniform
atmosphere about six-fold. A filtered file can be read only where its
filter is loaded too.

A software element type such as MultiFloats' `Float32x2` is stored as
its limbs, and a load names it through `types = (Float32x2,)`. A file
this version cannot interpret — a newer format version, an unknown
feature — is refused with the reason and the versions that wrote it, and [`checkpoint_environment`](@ref) writes out that version's
`Project.toml` and `Manifest.toml`, so that `julia --project=dir` can
read it.

## Over MPI

Over a forest distributed with TreeAMR's `comm` keyword, `save_checkpoint`,
`write_plain` in its do-block and `load_checkpoint(path; comm)` are
collective, and `using MPI` loads TreeAMR's MPI extension, through which
every message goes. A checkpoint never has two processes write or open one file,
so it depends on no parallel I/O: the ranks form groups of consecutive
ranks, one per node by default (`io = :node`; `io = :all` gives every
rank its own, or pass a number), and each group's first rank receives
the group's blocks and writes them into a part file of its own,
`path.<saveid>.<j>.h5`, beside the index that rank 0 writes at `path`
last. Loading, rank 0 alone opens the index and shares it, and each part
is read by one rank, which sends the blocks to their owners. A
checkpoint written at any rank count loads at any other, or serially,
and continues bit for bit. The plain data must be the same on every
rank; data that differ are refused on every rank before anything is
written. Keep the index and its parts together: the next save to the
same path removes the parts of the one it replaces, and any other file
named like one of its parts. One part per node keeps the number of
files small; one per rank was faster on the cluster measured, most of
all with a filter, which each I/O process runs for its group alone.

```julia
save_checkpoint("run.h5", forest; fieldsets = ("u" => (fs, u),),
                application = "MyApp" => 1, data = (; t, chunk))   # io = :node
# run.h5, run.h5.<saveid>.0.h5, run.h5.<saveid>.1.h5, … one part per node
```
