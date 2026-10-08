# TreeIOHDF5.jl

Checkpoint and restart for [TreeAMR](https://github.com/eschnett/TreeAMR.jl)
meshes, through HDF5. A long run stops and resumes: `save_checkpoint`
writes the mesh, the evolved fields and the application's own run state,
and `load_checkpoint` reads them back exactly in a new process, on any
thread count, rank count or backend; the run then continues bit for bit.
Only what cannot be recomputed is stored: the leaves, and the fields
without their ghost zones.

See [CODE.md](CODE.md) for the file format and the design,
[PLAN.md](PLAN.md) for what comes next and [HISTORY.md](HISTORY.md) for
how it got here.

**Contents**

- [Status](#status)
- [Example](#example)
- [Testing](#testing)

## Status

The checkpoints were part of TreeAMR (its milestone M9a, and over MPI its
M7) until TreeAMR 0.2, and moved here unchanged: files written by
TreeAMR's own HDF5 extension load as they did. Serially a checkpoint is
one HDF5 file; over MPI it is an index and one part file per I/O process,
none of them written or opened by more than one process, and every
checkpoint carries checksums that a load verifies.

TreeIOHDF5 is a *companion package* of TreeAMR: it uses TreeAMR's
internals, so it accepts only the TreeAMR versions it was tested against
(TreeAMR's `CODE.md`, "Companion interface"). Neither TreeIOHDF5 nor
TreeAMR 0.2 is registered yet.

## Example

```julia
using TreeAMR, TreeIOHDF5

forest = Forest((2, 2); N = 8, periodic = (true, true))
fs = FieldSet(forest, 1; G = 2)
fill_by_coordinates!((x, v) -> sinpi(x[1]) * cospi(x[2]), fs)
u = statevector(fs); gather!(u, fs)

save_checkpoint("run.h5", forest; fieldsets = ("u" => (fs, u),),
                application = "MyApp" => 1, data = (; t = 0.25, chunk = 3))

ck = load_checkpoint("run.h5")
ck.data                                     # (t = 0.25, chunk = 3)
restored = ck.fieldsets["u"].fieldset       # fill its ghosts, and continue
```

## Testing

```julia
using Pkg
Pkg.test("TreeIOHDF5")
```
