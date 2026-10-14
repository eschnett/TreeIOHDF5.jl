# TreeIOHDF5.jl

Checkpoint and restart for
[TreeAMR](https://github.com/eschnett/TreeAMR.jl) meshes, through
HDF5. A function `save_checkpoint` writes the mesh, the evolved fields
and the application's state, and `load_checkpoint` reads them back in.
This works on any thread count, MPI rank count, or accelerator
backend. This stores only data which cannot be recomputed: the leaves
of the mesh tree and the fields without their ghost zones.

[![CI](https://github.com/eschnett/TreeIOHDF5.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/eschnett/TreeIOHDF5.jl/actions/workflows/CI.yml)
[![Documentation](https://img.shields.io/badge/docs-dev-blue.svg)](https://eschnett.github.io/TreeIOHDF5.jl/dev)
[![codecov](https://codecov.io/gh/eschnett/TreeIOHDF5.jl/graph/badge.svg)](https://codecov.io/gh/eschnett/TreeIOHDF5.jl)

See [CODE.md](CODE.md) for the file format and the design,
[PLAN.md](PLAN.md) for what comes next.

**Contents**

- [Status](#status)
- [Example](#example)
- [Testing](#testing)

## Status

For a serial simulation, a checkpoint is one HDF5 file. With MPI,
there is an index file and a "part" file for every I/O process. There
are checksums to guard against silent I/O errors. (We were bitten.)

TreeIOHDF5 is a *companion package* of TreeAMR: it uses TreeAMR's
internals, so it accepts only the TreeAMR versions it was tested against
(TreeAMR's `CODE.md`, "Companion interface").

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
