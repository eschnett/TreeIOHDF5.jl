"""
    TreeIOHDF5

Checkpoint and restart for TreeAMR meshes, through HDF5: the forest, the
field sets an application evolves and its own plain data, written to one
file serially or to an index and one part file per I/O process over MPI,
and read back exactly on any thread count, rank count and backend.

See `CODE.md` in the package root for the file format and the reasons
behind it.
"""
module TreeIOHDF5

using HDF5: HDF5, API, h5open, create_group, create_dataset, dataspace, attributes,
            read_attribute, write_attribute, write_dataset, copy_object, create_external
using KernelAbstractions: CPU, Backend, get_backend
using CRC32c: crc32c
using TreeAMR
# TreeAMR's companion interface: internals that a package providing
# infrastructure on TreeAMR may use, and a physics package may not. They
# are not covered by TreeAMR's semantic versioning, which is why
# `Project.toml` lists the exact TreeAMR versions this package was tested
# against (TreeAMR's `CODE.md`, "Companion interface").
using TreeAMR: threaded_foreach, tohost, samebackend, Communicator, commrank, commsize,
               allgather, allgatherv, bcast, commnodes, isend, irecv, waitall,
               equalsplit, equalsplit_part, ForestDigest, digest_verdict, layouthash,
               hasrotating, rotating_dims, ishalfturn, halfturn_dims, reflecting_faces,
               outflow_faces

export save_checkpoint, load_checkpoint, write_plain, read_plain, checkpoint_environment

include("api.jl")
include("hdf5.jl")

end
