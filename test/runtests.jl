using Test
using Random
using TreeAMR
using TreeIOHDF5

include("oracles.jl")
include("ghost_oracles.jl")
include("wave.jl")
include("burgers.jl")
# The MPI test's `mpiexec` jobs start now where the machine has room for
# them beside the suite, and are collected by `mpi_tests.jl`.
include("mpi_jobs.jl")
start_mpi_jobs!()

@info "Running the tests on $(Threads.nthreads()) thread(s)"

@testset "TreeIOHDF5.jl" begin
include("checkpoint_tests.jl")
include("device_tests.jl")
include("partition_tests.jl")
include("mpi_tests.jl")
end
