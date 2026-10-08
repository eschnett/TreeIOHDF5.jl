# A checkpoint over a distributed forest stops at the first verb its
# communicator lacks, by name, rather than write this rank's blocks as if
# they were the whole mesh. A rank is simulated in process, as in
# TreeAMR's `partition_tests.jl`, by a communicator that answers its rank
# and the rank count, and the forest digest by replication, and nothing
# else.

struct PartitionCommunicator <: TreeAMR.Communicator
    rank::Int
    size::Int
end
TreeAMR.commrank(c::PartitionCommunicator) = c.rank
TreeAMR.commsize(c::PartitionCommunicator) = c.size
TreeAMR.allgather(c::PartitionCommunicator, d::TreeAMR.ForestDigest) = fill(d, c.size)

# The forest `serial` as rank `r` of `P` holds it: the same leaves, the
# same brick, through the validated `leaves` path.
rank_forest(serial::Forest{D,T}, r, P) where {D,T} =
    Forest{T}(serial.roots; N=serial.N, periodic=serial.periodic,
              reflecting=serial.reflecting, extents=serial.extents,
              rotating=TreeAMR.rotating_dims(serial),
              leaves=serial.leaves, comm=PartitionCommunicator(r, P))

@testset "A checkpoint over a distributed forest refuses a communicator by verb" begin
    # The failure: a save that writes one rank's blocks as the whole
    # checkpoint, or fails inside HDF5, when its communicator cannot
    # agree on the arguments.
    serial = nested_forest(Val(2); N=8)
    forest = rank_forest(serial, 1, 3)
    fs = FieldSet(forest, 1; G=2)
    @test_throws "does not implement `allgather`" save_checkpoint(
        tempname(), forest; fieldsets=("u" => fs,), application="A" => 1)
end
