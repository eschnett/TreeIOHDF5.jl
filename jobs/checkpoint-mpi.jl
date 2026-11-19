# The distributed checkpoint throughput on Symmetry's BeeGFS:
# `bench/checkpoint.jl mpi`, which `bench/symmetry_checkpoint_mpi.sh` ran until 2026-11-18.
# The runs are a product, so this is a spec in Julia (SimLaunch's
# SPEC.md, "A spec in Julia"). The study's project is `bench/`, whose
# Project.toml adds the filter packages to this checkout, so the snapshot
# is taken of it and the commands are relative to it:
#
#     simlaunch snapshot bench --study <study>
#     simlaunch prepare <study> --site symmetry --spec jobs/checkpoint-mpi.jl
#     simlaunch submit <study> jobs/checkpoint-mpi.jl --site symmetry
#
# For each mesh (6³ roots, 3296 blocks; 12³, 12648 blocks) and each `io`
# (`TREEAMR_BENCH_IO`): one node at 1, 2, 4 and 8 ranks, then 2, 4, … nodes
# up to `NODES` at 8 ranks a node, 64 / ranks threads a rank. The files go
# into each run's own job directory, which is on BeeGFS, and the benchmark
# removes them after each filter setting. `submit --run <label>` picks
# runs, as TREEAMR_CKPT_ONENODE=0 did; another `NODES` is an edit here.
#
# What differs from the script:
#
# - The environment is `bench/Project.toml` with MPI, where the script
#   made a scratch environment that developed this checkout and added the
#   filter packages; every filter setting is measured, as there.
# - Each rank is bound to its 8 / ranks-a-node NUMA domains, cores and
#   memory (`placement = "numa"`), where the script's `--cpu-bind=cores`
#   bound it to its block of 64 / ranks-a-node cores, the same cores.
# - The MPI is still MPICH_jll under `srun --mpi=pmi2`, the profile's `jll`
#   recipe, with HDF5_jll's MPICH artifact. TREEAMR_MPI=system has no
#   counterpart here; it would be another recipe of the site's profile.
# - The time is 6 hours, where the script asked for one, which ends during
#   the 12³ mesh even with `none` and `shuffle+deflate(1)` alone (jobs
#   602670 and 602671, the spec and the script, on the same two nodes).
#   Those two settings took 1:54 for all runs (job 602743), most of it
#   Deflate's; the other five save 3 to 10 times faster (CODE.md,
#   "Throughput and filters"), so all seven should take about 4 hours.

const NODES = 2         # the job's nodes
const RPN = 8           # ranks a node of the runs on several nodes: one per NUMA domain
const CORES = 64        # an AMD node's
const ROOTS = (6, 12)
const IO = ("node", "all")

bench(nodes, rpn, roots, io) =
    (label = "roots$roots-$(nodes)x$rpn-$io", cmd = "checkpoint.jl mpi",
     mpi = "jll", ranks = nodes * rpn, nodes = nodes, threads = CORES ÷ rpn,
     placement = "numa",
     vars = Dict("TREEAMR_BENCH_ROOTS" => string(roots), "TREEAMR_BENCH_IO" => io))

powers(n) = [2^k for k in 0:floor(Int, log2(n))]

runs = Any[(label = "versions", mpi = "jll",
            cmd = "-e 'using MPI, HDF5; MPI.versioninfo(); " *
                  "println(\"HDF5 \", HDF5.libversion, \" parallel \", HDF5.has_parallel())'")]
for roots in ROOTS
    for rpn in powers(RPN), io in IO
        push!(runs, bench(1, rpn, roots, io))
    end
    for nodes in powers(NODES)[2:end], io in IO
        push!(runs, bench(nodes, RPN, roots, io))
    end
end

(name = "checkpoint-mpi",
 site = "symmetry",
 time = "6:00:00",
 resources = (nodes = NODES,),
 vars = Dict("TREEAMR_BENCH_DIR" => "."),
 # the table of every run, in the job's log
 after = (cmd = raw"""for d in $SIMLAUNCH_JOBDIRS; do echo "== $d"; grep -E '^(ranks=|# files|pulse|blast)' "$d/output.log"; done""",),
 run = runs)
