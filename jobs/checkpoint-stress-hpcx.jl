# The MPI-IO reproducers of `bench/checkpoint_stress.jl` under HPC-X's Open
# MPI 4.1.7 on Symmetry, launched by its own `mpiexec`: through OMPIO, Open
# MPI's own MPI-IO and its default there, and through the ROMIO 3.2.1 it
# also ships. As `bench/symmetry_checkpoint_stress_hpcx.sh` ran them until
# 2026-11-18, with `bench/` as the study's project (`jobs/checkpoint-mpi.jl`):
#
#     simlaunch snapshot bench --study <study>
#     simlaunch prepare <study> --site symmetry --spec jobs/checkpoint-stress-hpcx.jl
#     simlaunch submit <study> jobs/checkpoint-stress-hpcx.jl --site symmetry
#
# A case is (mode, io, hints, iterations): a mode below HDF5, `ompio` or
# `romio`, a ROMIO hint set of `bench/romio_hints/` (which OMPIO ignores),
# and the iterations. `CASES` is an example; the script took them on its
# command line. Eight ranks a node, eight threads a rank, STRESS_SYNC=0.
# The first run prints the MPI library and Open MPI's I/O components.
#
# What differs from the script:
#
# - The MPI is the site profile's `mpiabi` recipe: HPC-X's Open MPI through
#   mpi_abi_wrapper's `libmpi_abi.so`, MPI.jl's abi "MPIABI", under
#   `mpiexec --bind-to none`. The script's environment loaded HPC-X's
#   `libmpi` directly (abi "OpenMPI"); there HDF5_jll takes its Open MPI
#   build, whose OpenMPI_jll does not load beside HPC-X's PMIx (undefined
#   symbol `pmix_framework_names`), and `using TreeIOHDF5` fails, so the
#   script could not run in this repository. Under "MPIABI" HDF5_jll takes
#   its MPIABI build and MPIABI_jll, whose library is the wrapper's.
# - `--mca io romio321` is the variable OMPI_MCA_io, which Open MPI reads
#   from the environment; SimLaunch sets a run's `vars` in front of each
#   rank's command, so they reach the ranks on every node, as the script's
#   `-x` gave them. The ROMIO hints are files of the project, named by
#   STRESS_HINTS, as in `jobs/checkpoint-stress.jl`.
# - The study's environment is `bench/Project.toml` with HDF5, where the
#   script's had no HDF5 of its own; the modes below HDF5 load neither
#   HDF5 nor TreeIOHDF5.

const NODES = 4

const CASES = [("sieve-ind", "ompio", "default", 200),
               ("sieve-ind", "romio", "default", 200),
               ("sieve-ind", "romio", "dsoff", 200),
               ("sieve-coll", "ompio", "default", 200),
               ("sieve-coll", "romio", "cboff", 200),
               ("mpiio-coll", "ompio", "default", 200),
               ("posix", "ompio", "default", 200)]

function stress(mode, io, hints, iters)
    vars = Dict("STRESS_SYNC" => "0", "STRESS_HINTS" => hints)
    io == "romio" && (vars["OMPI_MCA_io"] = "romio321")
    return (label = "$mode-$io-$hints-$iters",
            cmd = "checkpoint_stress.jl $mode $iters .",
            ranks = 8 * NODES, vars = vars)
end

runs = Any[(label = "versions",
            cmd = "-e 'using MPI; println(MPI.Get_library_version()[1:60]); " *
                  "foreach(println, filter(contains(r\"MCA (io|fcoll|fs|fbtl):\"), readlines(`ompi_info`)))'")]
append!(runs, [stress(c...) for c in CASES])

(name = "checkpoint-stress-hpcx",
 site = "symmetry",
 time = "1:00:00",
 resources = (nodes = NODES,),
 mpi = "mpiabi",
 threads = 8,
 after = (cmd = raw"""bash "$PROJECT"/stress_summary.sh $SIMLAUNCH_JOBDIRS""",),
 run = runs)
