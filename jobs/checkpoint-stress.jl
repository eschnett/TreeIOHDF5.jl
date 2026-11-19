# The reproducers of the multi-node checkpoint loss of M7 step 6, and the
# regression job of the part-file writer of step 6b
# (`bench/checkpoint_stress.jl`), on Symmetry under MPICH_jll and its ROMIO,
# launched by `srun` over PMI-2, as `bench/symmetry_checkpoint_stress.sh`
# ran them until 2026-11-18. A spec in Julia, one run a case. The study's project is
# `bench/`, as in `jobs/checkpoint-mpi.jl`:
#
#     simlaunch snapshot bench --study <study>
#     simlaunch prepare <study> --site symmetry --spec jobs/checkpoint-stress.jl
#     simlaunch submit <study> jobs/checkpoint-stress.jl --site symmetry
#
# A case is (mode, sync, hints, iterations, io) as the script's
# `mode:sync:hints:iters:io`: a mode of checkpoint_stress.jl, STRESS_SYNC,
# a ROMIO hint set of `bench/romio_hints/`, the iterations, and for the
# `treeamr` modes STRESS_IO. `CASES` is step 6b's measurement; step 6's
# is `STEP6` below, and other cases are an edit here. Eight ranks a node,
# one per NUMA domain, eight threads a rank; the loss needs ranks on more
# than one node. The files go into each run's own job directory on BeeGFS;
# the `[after]` command prints a summary a case, and the script removes its
# last save when it ends, since the job directory is read-only afterwards.
#
# What differs from the script: the cases are written here instead of on
# the command line; the ROMIO hints are files of the project, which each
# run names by STRESS_HINTS, and `checkpoint_stress.jl` points ROMIO_HINTS
# at the file (a variable of a spec is passed as written, so it cannot
# hold the project's path); and STRESS_BASEDIR, for files on /home's NFS
# instead, has no counterpart, since a run writes into its job directory.

const NODES = 4

const CASES = [("treeamr-filt", 0, "default", 500, "node"),
               ("treeamr-filt", 1, "default", 500, "all"),
               ("treeamr", 0, "default", 500, "node")]

const STEP6 = [("treeamr-filt", 0, "default", 200, "node"),
               ("treeamr-filt", 0, "dsoff", 200, "node"),
               ("sieve-ind", 0, "default", 2000, "node"),
               ("sieve-ind", 0, "dsoff", 2000, "node"),
               ("sieve-coll", 0, "cbon", 200, "node"),
               ("sieve-coll", 0, "cboff", 200, "node"),
               ("visible", 0, "default", 200, "node")]

runs = [(label = "$mode-$sync-$hints-$iters-$io",
         cmd = "checkpoint_stress.jl $mode $iters .",
         ranks = 8 * NODES,
         vars = Dict("STRESS_SYNC" => string(sync), "STRESS_HINTS" => hints, "STRESS_IO" => io))
        for (mode, sync, hints, iters, io) in CASES]

(name = "checkpoint-stress",
 site = "symmetry",
 time = "1:00:00",
 resources = (nodes = NODES,),
 mpi = "jll",
 threads = 8,
 placement = "numa",
 after = (cmd = raw"""bash "$PROJECT"/stress_summary.sh $SIMLAUNCH_JOBDIRS""",),
 run = runs)
