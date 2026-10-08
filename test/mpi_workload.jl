# The checkpoint workload of the rank-count independence test: the cases
# of TreeAMR's `test/mpi_workload.jl` that end in a checkpoint, the
# chunked restarts and the refusals, which moved here with the
# checkpoints (TreeAMR 0.2). What follows is that file's description;
# the cases not run here are TreeAMR's.
#
#
# Run as a standalone script, it prints on rank 0 a digest of everything
# a distributed mesh produces, in lines that must not depend on the
# number of ranks:
#
#     mpiexec -n 3 julia --project=test test/mpi_workload.jl mpi
#     julia --project=test test/mpi_workload.jl                 # serially
#
# The field data are gathered to every rank in block order before they
# are digested — the state vector after several time steps, and the
# working arrays *with their ghosts* after a fill, so the exchange is
# checked bit for bit, ghosts included, and not only through what the
# ghosts did to the interior. Integer, max and min reductions are
# printed exactly. The floating-point sums are printed on lines whose
# second word is `sum`; they are promised to roundoff across rank counts
# only ("Reductions" under "Distributed meshes" in CODE.md), and the
# test compares them with a tolerance. Every other line must be
# identical byte for byte. Lines starting with `#` depend on the rank
# count — the refusals and the negative control — and are checked
# separately by `mpi_tests.jl`.
#
# Without the argument `mpi` the forests are serial, which is the
# reference; `mpi_tests.jl` runs it in its own process, into an
# `IOBuffer` it defines as `WORKLOAD_IO`. Deliberately self-contained —
# its own RK4 and SSPRK3, no ODE package, no test helpers — so that a
# rank starts in seconds. From step 4 of M7 on it regrids too: the
# leaves and the transferred arrays after every regrid are digested
# before any ghost fill, so the transfer itself is checked bit for bit.
# From step 5 on it interpolates: every rank queries its own slice of one
# global point list, and the answers gathered in rank order are the
# serial answers in global order. From step 6 on it checkpoints: a run
# saved after a regrid, with one part file per rank, per two groups and
# per node (step 6b), and continued from each file at the same rank count
# must print what the uninterrupted run prints; the files of other runs,
# written at other rank counts, are loaded at this one on `#` lines
# (`TREEAMR_CHECKPOINT_DIR`, and `TREEAMR_CHECKPOINT_FROM` for the rank
# counts whose files to wait for and load, which lets `mpi_tests.jl` run
# the launches at once); and the version-1 fixtures, written by the
# shared-file writer's version, load at every rank count. From M12 on it
# runs a rotating quadrant too: the wave, a set that turns into itself
# and a `RotationPair` through a fill, a regrid, interpolation beyond the
# seam and a checkpoint, loaded at the other rank counts as well.

using TreeAMR
using MPI: MPI
using KernelAbstractions: @kernel, @index, @Const
using Printf: @sprintf
using SHA: sha256
using MultiFloats: Float32x2
using TreeIOHDF5
using HDF5: HDF5
using HDF5.Filters: Shuffle, Deflate

const USE_MPI = "mpi" in ARGS
USE_MPI && MPI.Init()
const COMM = USE_MPI ? MPI.COMM_WORLD : nothing
const RANK = USE_MPI ? MPI.Comm_rank(MPI.COMM_WORLD) : 0
const NRANKS = USE_MPI ? MPI.Comm_size(MPI.COMM_WORLD) : 1
const OUT = isdefined(@__MODULE__, :WORKLOAD_IO) ? WORKLOAD_IO : stdout
# Under MPI the checkpoints' messages are cut at 4 KiB (a test hook of
# TreeIOHDF5; 64 MiB otherwise), so that a rank's blocks travel to its
# I/O process, and a part's from its reader, in several messages.
const CKPT = TreeIOHDF5
USE_MPI && (CKPT.MAX_MESSAGE[] = 4096)

emit(words...) = (RANK == 0 && println(OUT, join(words, " ")); nothing)

digest(bytes::AbstractVector{UInt8}) = bytes2hex(sha256(bytes))[1:32]
digest(v::Vector{<:AbstractFloat}) = digest(reinterpret(UInt8, v))
digest(s::AbstractString) = digest(codeunits(s))

# Every rank's part of a per-block vector, in rank order, which is block
# order: the ranks own contiguous runs of the curve.
gathered(forest, v) = TreeAMR.allgatherv(forest.comm, collect(vec(v)))

# A forest refined twice around `centre`, so that three levels meet. A
# forest mutation is collective: every rank makes the same calls.
function forest_of(roots::NTuple{D,Int}, N; periodic=ntuple(_ -> false, D),
                   reflecting=ntuple(_ -> (false, false), D), rotating=nothing,
                   centre=nothing, levels=2) where {D}
    forest = Forest(roots; N=N, periodic=periodic, reflecting=reflecting,
                    rotating=rotating, comm=COMM)
    centre === nothing && return forest
    for lvl in 0:(levels - 1)
        r = 0.6 / 2^lvl
        targets = filter(forest.leaves) do k
            level(k) == lvl || return false
            ext = block_extent(forest, k)
            return all(d -> abs((ext[d][1] + ext[d][2]) / 2 - centre[d]) <= r, 1:D)
        end
        refine!(forest, targets)
        balance!(forest)
    end
    return forest
end

# The serial schedule's transfer count, summed over the ranks: each
# rank's local transfers and those it receives. The ones it sends are
# another rank's received ones, so the totals sent and received agree.
function transfers(forest, groups, stages)
    nlocal = sum(TreeAMR.ntransfers, groups; init=0)
    layouts(f) = sum(st -> st.remote === nothing ? 0 : length(f(st.remote)), stages;
                     init=0)
    nrecv, nsent = layouts(r -> r.recvlayout), layouts(r -> r.sendlayout)
    counts = TreeAMR.allgather(forest.comm, (nlocal + nrecv, nsent, nrecv))
    total = sum(first, counts)
    balanced = sum(c -> c[2], counts) == sum(c -> c[3], counts)
    return "$total balanced $balanced"
end
transfers(forest, s::GhostSchedule) =
    transfers(forest, [s.phase1; reduce(vcat, s.phase2; init=eltype(s.phase1)[])],
              s.stages)
transfers(forest, s::InterfaceSchedule) =
    transfers(forest, reduce(vcat, s.phases; init=eltype(eltype(s.phases))[]), s.stages)

# The reductions of one variable: exact ones as they are, sums marked.
function reductions(tag, fs, u)
    emit(tag, "count", mesh_mapreduce(x -> 1, +, 0, fs))
    emit(tag, "linf", @sprintf("%.17g", volume_weighted_norm(fs, u; p=Inf)))
    emit(tag, "min", @sprintf("%.17g", mesh_mapreduce(identity, min, Inf, fs; vars=1)))
    emit(tag, "negmax",
         @sprintf("%.17g", mesh_mapreduce(x -> -abs(x) - 1, max, -Inf, fs; vars=1)))
    # An `init` that is not neutral, under a weight: every block's value
    # is `0.5 max(1, …) = 0.5`, so a rank with no blocks must contribute
    # nothing rather than its `init`, or this would print 1.
    emit(tag, "initmax",
         @sprintf("%.17g", mesh_mapreduce(x -> -abs(x), max, 1.0, fs; vars=1,
                                          weight=k -> 0.5)))
    emit(tag, "sum l2", @sprintf("%.17g", volume_weighted_norm(fs, u)))
    emit(tag, "sum mass", @sprintf("%.17g", total_mass(fs, 1)))
    return nothing
end

# --- the wave equation, as in thread_workload.jl ---------------------------

@kernel function wave_kernel!(du, @Const(work), @Const(spacings), ::Val{D},
                              ::Val{G}) where {D,G}
    I = @index(Global, NTuple)
    b = I[D + 1]
    c = ntuple(d -> I[d] + G[d], Val(D))
    u0 = work[c..., 1, b]
    laplacian = zero(eltype(du))
    for d in 1:D
        up = Base.setindex(c, c[d] + 1, d)
        um = Base.setindex(c, c[d] - 1, d)
        laplacian += work[up..., 1, b] - 2 * u0 + work[um..., 1, b]
    end
    h = spacings[b]
    du[ntuple(d -> I[d], Val(D))..., 1, b] = work[c..., 2, b]
    du[ntuple(d -> I[d], Val(D))..., 2, b] = laplacian / (h * h)
end

function wave_rhs!(du, u, fs, sched, spacings, ::Val{D}, ::Val{G}, boundary) where {D,G}
    scatter!(fs, u)
    fill_ghosts!(fs, sched; boundary=boundary)
    map_blocks!(wave_kernel!, fs, statearray(du, fs), fs.work, spacings, Val(D), Val(G))
    return du
end

function rk4!(u, fs, sched, dt, nsteps, ::Val{D}, ::Val{G}, boundary) where {D,G}
    spacings = block_spacings(fs.forest)
    k1, k2, k3, k4, tmp = (similar(u) for _ in 1:5)
    for _ in 1:nsteps
        wave_rhs!(k1, u, fs, sched, spacings, Val(D), Val(G), boundary)
        @. tmp = u + (dt / 2) * k1
        wave_rhs!(k2, tmp, fs, sched, spacings, Val(D), Val(G), boundary)
        @. tmp = u + (dt / 2) * k2
        wave_rhs!(k3, tmp, fs, sched, spacings, Val(D), Val(G), boundary)
        @. tmp = u + dt * k3
        wave_rhs!(k4, tmp, fs, sched, spacings, Val(D), Val(G), boundary)
        @. u += (dt / 6) * (k1 + 2 * k2 + 2 * k3 + k4)
    end
    return u
end

pulse(x0, σ) = (x, v) -> begin
    g = exp(-sum(d -> (x[d] - x0[d])^2, 1:length(x)) / (2σ^2))
    v == 1 ? g : (x[1] - x0[1]) * g
end

# --- every centering through one fill, and the interface restriction ------

# Data that no stencil reproduces by accident: a function of the global
# leaf, the stored index and the variable alone, so it is the same at
# any rank count, written over every stored point of a block. Smooth
# data would let a wrong source or a wrong weight go unnoticed wherever
# the two interpolants agree, and would make the injection at a
# vertex-like coarse-fine face a no-op.
function pseudorandom!(fs::FieldSet{T,D}) where {T,D}
    offset = first(blockrange(fs.forest)) - 1
    for b in 1:nblocks(fs), v in 1:fs.nvars
        block = blockview(fs, b, v)
        for idx in CartesianIndices(block)
            h = hash((offset + b, Tuple(idx), v))
            block[idx] = T((h >> 11) * 0x1p-53) - T(1) / 2
        end
    end
    return fs
end

# --- regridding (step 4 of M7) ---------------------------------------------

# How a regrid moved blocks between ranks, from the leaves before and
# after: kept blocks whose owner rose and fell, and coarsened blocks
# whose `2^D` children had more than one owner. A function of the rank
# count, so it goes on `#` lines.
function migration(forest::Forest{D}, old, new) where {D}
    P = NRANKS
    owner(n, i) = TreeAMR.equalsplit_part(n, P, i) - 1
    oldindex = Dict(k => i for (i, k) in enumerate(old))
    up, down, straddling = 0, 0, 0
    for (j, k) in enumerate(new)
        i = get(oldindex, k, nothing)
        if i !== nothing
            up += owner(length(new), j) > owner(length(old), i)
            down += owner(length(new), j) < owner(length(old), i)
        elseif level(k) < TreeAMR.MAX_LEVEL &&
               all(c -> haskey(oldindex, c), TreeAMR.childkeys(k))
            owners = Set(owner(length(old), oldindex[c]) for c in TreeAMR.childkeys(k))
            straddling += length(owners) > 1
        end
    end
    return up, down, straddling
end

# A regrid of every pair, followed by the digests that do not depend on
# the rank count — the leaves, and each field set's arrays as the
# transfer left them, ghosts zero — and the `#` line that does.
function regridded(tag, forest, pairs; flags, buffer=0, boundary=nothing)
    old = copy(forest.leaves)
    changed = regrid!(forest, pairs; flags=flags, buffer=buffer, boundary=boundary)
    emit(tag, "regrid", changed, nleaves(forest), maxlevel(forest),
         digest(string(forest.leaves)))
    for (i, (fs, sched)) in enumerate(pairs)
        sched === nothing && continue
        if fs isa RotationPair                      # both members (M12)
            emit(tag, "transferred$i", digest(gathered(forest, fs.a.work)),
                 digest(gathered(forest, fs.b.work)))
        else
            emit(tag, "transferred$i", digest(gathered(forest, fs.work)))
        end
    end
    up, down, straddling = migration(forest, old, forest.leaves)
    emit("#", tag, "migrated", up, "up", down, "down", straddling, "straddling")
    return changed
end

# The tracked pulse: a right-moving Gaussian, vertex-centered, against
# outer faces with the hook, refined where it is large through
# `firing_boxes` (local) and regridded between RK4 steps.
pulse_fires(work, idx, b, x) = abs(work[idx..., 1, b]) > 0.2

function moving_pulse(x0, σ)
    return (x, v) -> begin
        g = exp(-sum(d -> (x[d] - x0[d])^2, 1:length(x)) / (2σ^2))
        v == 1 ? g : (x[1] - x0[1]) / σ^2 * g
    end
end

function pulse_flags(fs, lmax)
    return map(enumerate(firing_boxes(pulse_fires, fs))) do (b, (n, box))
        k = blockkey(fs, b)
        n == 0 && return level(k) > 0 ? Coarsen : Keep
        return level(k) < lmax ? (Refine, box) : (Keep, box)
    end
end

# --- ranks without blocks ---------------------------------------------------

# Two leaves, so that at three ranks one rank holds no block, through
# every operation an application makes on it: the all-variables forms of
# the fill and the boundary hook, the wave equation, the interface
# restriction, interpolation, regrids that give the empty rank blocks
# and take them away again, the initial-data cycle and a checkpoint. A
# step that assumed a rank has a block 1 throws there while the others
# wait, which `main` turns into an abort: the all-variables hook's length
# check did, until it was guarded in 0.1.6.
const EMPTY_PARITY = [(OddParity, EvenParity), (EvenParity, EvenParity)]
const EMPTY_DATA = AllVariables(x -> (sin(2x[1]) + x[2] / 3, x[1] * x[2] - 1))
const EMPTY_HOOK = CellBoundary(AllVariables((x, δ) -> EMPTY_DATA.f(x)))

function empty_rank_case(tag)
    D = 2
    forest = forest_of((2, 1), 8; reflecting=((true, false), (false, false)))
    emit(tag, "leaves", nleaves(forest), maxlevel(forest), digest(string(forest.leaves)))
    empties() = count(iszero, TreeAMR.allgather(forest.comm, length(blockrange(forest))))
    emit("#", tag, "empty ranks", empties())
    fs = FieldSet(forest, 2; G=2, parity=EMPTY_PARITY)
    fill_by_coordinates!(EMPTY_DATA, fs)
    sched = GhostSchedule(fs, OPS4)
    fill_ghosts!(fs, sched; boundary=EMPTY_HOOK)
    emit(tag, "filled", digest(gathered(forest, fs.work)))
    u = statevector(fs)
    gather!(u, fs)
    rk4!(u, fs, sched, 0.2 * minimum_spacing(forest), 3, Val(D), Val(fs.G), EMPTY_HOOK)
    emit(tag, "state", digest(gathered(forest, u)))
    scatter!(fs, u)
    reductions(tag, fs, u)

    vfs = FieldSet(forest, 2; G=0, centering=vertexcentered(D), parity=EMPTY_PARITY)
    pseudorandom!(vfs)
    restrict_interfaces!(vfs, InterfaceSchedule(vfs))
    emit(tag, "restricted", digest(gathered(forest, vfs.work)))

    # Rank 0 asks for every point, beyond the wall too; the others for none.
    fill_ghosts!(fs, sched; boundary=EMPTY_HOOK)
    pts = [(-0.4 + 2.35 * mod(j * 0.618034, 1.0), 0.97 * mod(j * 0.381966, 1.0))
           for j in 1:23]
    r = interpolate(fs, RANK == 0 ? pts : similar(pts, 0), Lagrange(4);
                    derivs=((0, 0), (1, 0)))
    emit(tag, "interpolated", digest(gathered(forest, r.values)))

    # Refined, every rank has blocks; coarsened again, the third has none.
    regridded("$tag.refine", forest, (fs => sched, vfs => nothing);
              flags=fill(Refine, length(blockrange(forest))), boundary=EMPTY_HOOK)
    sched = GhostSchedule(fs, OPS4)
    fill_ghosts!(fs, sched; boundary=EMPTY_HOOK)
    emit(tag, "refined", digest(gathered(forest, fs.work)))
    regridded("$tag.coarsen", forest, (fs => sched,);
              flags=fill(Coarsen, length(blockrange(forest))), boundary=EMPTY_HOOK)
    sched = GhostSchedule(fs, OPS4)
    fill_ghosts!(fs, sched; boundary=EMPTY_HOOK)
    emit(tag, "coarsened", digest(gathered(forest, fs.work)))
    emit("#", tag, "empty ranks after the regrids", empties())

    path = joinpath(checkpoint_dir(), "$tag-n$NRANKS.h5")
    save_checkpoint(path, forest; fieldsets=("u" => fs,), application="Empty" => 1)
    ck = load_checkpoint(path; comm=COMM)
    back = ck.fieldsets["u"].fieldset
    v = statevector(back)
    gather!(v, back)
    gather!(u, fs)
    emit(tag, "checkpoint", nleaves(ck.forest), gathered(forest, u) == gathered(forest, v))

    # The initial-data cycle from the two leaves, in both callback forms.
    for (name, initial) in (("all", EMPTY_DATA), ("each", (x, v) -> EMPTY_DATA.f(x)[v]))
        forest = forest_of((2, 1), 8; reflecting=((true, false), (false, false)))
        fs = FieldSet(forest, 2; G=2, parity=EMPTY_PARITY)
        _, passes, converged = adapt_to_initial_data!(
            fs, OPS4; initial=initial, boundary=EMPTY_HOOK,
            flag=(b, k) -> level(k) < 1 && block_extent(forest, k)[1][1] < 0.5 ?
                           Refine : Keep)
        emit(tag, "adapted", name, passes, converged, nleaves(forest),
             digest(gathered(forest, fs.work)))
    end
    return nothing
end

# --- rotating seams (M12) ---------------------------------------------------

# A quadrant `[0, 3]^2` with a rotating seam, refined at the axis and the
# seam, through every operation: the fill of a set that turns into itself
# — a scalar and a vector, cell-centered — and of a `RotationPair` of
# face-centered sets, `(B_1, F_1)` and `(F_2, B_2)`, whose stages are
# merged and share their tags; a regrid of both, the pair filled as a pair
# before its transfer; interpolation over the whole plane, three quarters
# of the points turned back across the seam; and a checkpoint, saved and
# loaded at this rank count and at the others (`rotating_cross`). Each
# set has a variable that is zero everywhere, the vector's `v_2` and each
# member's second, so the turned ghosts hold `−0`, which a pack that
# applied the sign would turn into `+0`; the digests are of the bytes.
const QUAD_DATA = (x, v) -> v + x[1] / 7 - x[2]^2 / 5 + x[1] * x[2] / 11
const QUAD_HOOK = boundary_by_coordinates(QUAD_DATA)

# The rotated transfers this rank receives from another, summed over the
# ranks: none serially, some wherever the seam's transfers cross ranks.
function rotated_received(forest, scheds...)
    mine = sum(scheds) do sched
        sum(st -> st.remote === nothing ? 0 :
                  count(e -> e.key.orientation != 0, st.remote.recvlayout),
            sched.stages; init=0)
    end
    return sum(TreeAMR.allgather(forest.comm, mine))
end

# Pseudorandom data with variable `zero` set to zero, ghosts included.
function quad_data!(fs, zero)
    pseudorandom!(fs)
    for b in 1:nblocks(fs)
        blockview(fs, b, zero) .= 0
    end
    return fs
end

negzeros(forest, fs) = count(x -> iszero(x) && signbit(x), gathered(forest, fs.work))

function quad_sets(forest)
    fs = FieldSet(forest, 3; G=2, rotation=(1, -3, 2))
    a = FieldSet(forest, 2; G=2, centering=facecentered(2, 1), rotation=(-2, -1))
    b = FieldSet(forest, 2; G=2, centering=facecentered(2, 2), rotation=(2, 1))
    return fs, RotationPair(a, b)
end

function quad_fill!(forest, fs, pair)
    sched = GhostSchedule(fs, OPS4)
    pscheds = (GhostSchedule(pair.a, OPS4), GhostSchedule(pair.b, OPS4))
    fill_ghosts!(fs, sched; boundary=QUAD_HOOK)
    fill_ghosts!(pair, pscheds; boundary=QUAD_HOOK)
    return sched, pscheds
end

quad_digests(forest, fs, pair) =
    (digest(gathered(forest, fs.work)), digest(gathered(forest, pair.a.work)),
     digest(gathered(forest, pair.b.work)))

function quad_states(forest, sets...)
    return map(sets) do fs
        u = statevector(fs)
        gather!(u, fs)
        digest(gathered(forest, u))
    end
end

# A global list of points over `[-2.9, 2.9]^2`, three quarters of them
# beyond the seam, of which rank `r` queries its slice as in
# `interpolation_points`. (Not `φ` and `φ²` as there: their fractional
# parts sum to one, which would put every point on one diagonal.)
seam_points_all(n) = [(-2.9 + 5.8 * mod(j * (sqrt(5.0) - 1) / 2, 1.0),
                       -2.9 + 5.8 * mod(j * (sqrt(2.0) - 1), 1.0)) for j in 1:n]

function seam_points(n)
    xs = seam_points_all(n)
    weights = [(2, 0, 5, 1, 3)[r % 5 + 1] for r in 0:(NRANKS - 1)]
    cuts = [0; round.(Int, n .* cumsum(weights) ./ sum(weights))]
    return xs[(cuts[RANK + 1] + 1):cuts[RANK + 2]]
end

function rotating_case(tag)
    forest = forest_of((3, 3), 8; rotating=(1, 2), centre=(0.4, 0.5))
    emit(tag, "leaves", nleaves(forest), maxlevel(forest), digest(string(forest.leaves)))
    fs, pair = quad_sets(forest)
    quad_data!(fs, 3)
    quad_data!(pair.a, 2)
    quad_data!(pair.b, 2)
    sched, pscheds = quad_fill!(forest, fs, pair)
    emit(tag, "transfers", transfers(forest, sched), transfers(forest, pscheds[1]),
         transfers(forest, pscheds[2]))
    emit(tag, "filled", quad_digests(forest, fs, pair)...)
    emit(tag, "negzero", negzeros(forest, fs), negzeros(forest, pair.a),
         negzeros(forest, pair.b))
    emit("#", tag, "rotated received", rotated_received(forest, sched, pscheds...))

    # Refine along the low face of the first dimension, which conformity
    # carries to the low face of the second, and coarsen the finest
    # blocks off the seam.
    flags = map(1:nblocks(fs)) do b
        k = blockkey(fs, b)
        ext = block_extent(forest, k)
        onseam = ext[1][1] == 0 || ext[2][1] == 0
        level(k) < 2 && ext[1][1] == 0 && ext[2][1] < 2 ? Refine :
        level(k) == 2 && !onseam ? Coarsen : Keep
    end
    regridded("$tag.regrid", forest, (fs => sched, pair => pscheds); flags=flags,
              boundary=QUAD_HOOK)
    sched, pscheds = quad_fill!(forest, fs, pair)
    emit(tag, "refilled", quad_digests(forest, fs, pair)...)

    xs = seam_points(257)
    r = interpolate(fs, xs, Lagrange(4); derivs=((0, 0), (1, 0), (0, 1)), vars=[2, 3, 1])
    emit(tag, "interpolated", length(gathered(forest, r.excluded)),
         count(x -> x[1] < 0 || x[2] < 0, seam_points_all(257)),
         digest(gathered(forest, r.values)))

    # The checkpoint: the bare form, after the fill; loaded at this rank
    # count, the pair rebuilt from its two sets and filled again.
    dir = checkpoint_dir()
    path = joinpath(dir, "QC-n$NRANKS.h5")
    emit("QC", "saved", quad_states(forest, fs, pair.a, pair.b)...)
    save_checkpoint(path, forest; fieldsets=("u" => fs, "a" => pair.a, "b" => pair.b),
                    application="Quadrant" => 1, io=:all)
    loaded = quad_load(path, COMM)
    emit("QC", "loaded", quad_states(loaded...)...)
    lforest, lfs, lpair = loaded[1], loaded[2], RotationPair(loaded[3], loaded[4])
    quad_fill!(lforest, lfs, lpair)
    emit("QC", "refilled", quad_digests(lforest, lfs, lpair)...)
    RANK == 0 && touch(joinpath(dir, "QC-n$NRANKS.done"))
    rotating_cross("QC")
    return nothing
end

function quad_load(path, comm)
    ck = load_checkpoint(path; comm=comm)
    sets = ck.fieldsets
    return (ck.forest, sets["u"].fieldset, sets["a"].fieldset, sets["b"].fieldset)
end

# The rotating checkpoints of the runs at other rank counts, loaded at
# this one and, under MPI, at one rank over `MPI.COMM_SELF`: their states
# must be the saved ones. `#` lines, as in `checkpoint_cross`.
function rotating_cross(tag)
    dir = checkpoint_dir()
    counts = checkpoint_sources(dir, tag)
    names = filter(readdir(dir)) do name
        m = match(r"^(.*)-n(\d+)\.h5$", name)
        m === nothing && return false
        n = parse(Int, m[2])
        m[1] == tag && n != NRANKS && (counts === nothing || n in counts)
    end
    comms = USE_MPI ? ((NRANKS, COMM), (1, MPI.COMM_SELF)) : ((1, nothing),)
    for name in sort(names), (n, comm) in comms
        loaded = quad_load(joinpath(dir, name), comm)
        emit("#", replace(name, ".h5" => ""), "at", n, "loaded",
             quad_states(loaded...)...)
    end
    return nothing
end

# The quadrant wave, as `wave_case` runs it, on a single leaf at the axis
# — its own neighbor across the seam three times over — so that at two
# and three ranks only one rank has a block: the fill, the wave, a pair's
# fill, interpolation beyond the seam from rank 0 alone, regrids that
# give every rank blocks and take them away again, and a checkpoint.
function rotating_empty_case(tag)
    forest = Forest((1, 1); N=8, rotating=(1, 2), comm=COMM)
    empties() = count(iszero, TreeAMR.allgather(forest.comm, length(blockrange(forest))))
    emit("#", tag, "empty ranks", empties())
    fs = FieldSet(forest, 2; G=2, centering=vertexcentered(2), rotation=(1, 2))
    fill_by_coordinates!(QUAD_DATA, fs)
    sched = GhostSchedule(fs, OPS4)
    fill_ghosts!(fs, sched; boundary=QUAD_HOOK)
    emit(tag, "filled", digest(gathered(forest, fs.work)))
    u = statevector(fs)
    gather!(u, fs)
    rk4!(u, fs, sched, 0.2 * minimum_spacing(forest), 3, Val(2), Val(fs.G), QUAD_HOOK)
    emit(tag, "state", digest(gathered(forest, u)))
    scatter!(fs, u)
    reductions(tag, fs, u)
    _, pair = quad_sets(forest)
    fill_by_coordinates!(QUAD_DATA, pair.a)
    fill_by_coordinates!(QUAD_DATA, pair.b)
    pscheds = (GhostSchedule(pair.a, OPS4), GhostSchedule(pair.b, OPS4))
    fill_ghosts!(pair, pscheds; boundary=QUAD_HOOK)
    emit(tag, "pair", digest(gathered(forest, pair.a.work)),
         digest(gathered(forest, pair.b.work)))
    fill_ghosts!(fs, sched; boundary=QUAD_HOOK)
    pts = [(-0.95 + 1.9 * mod(j * 0.618034, 1.0), -0.95 + 1.9 * mod(j * 0.381966, 1.0))
           for j in 1:19]
    r = interpolate(fs, RANK == 0 ? pts : similar(pts, 0), Lagrange(4);
                    derivs=((0, 0), (0, 1)))
    emit(tag, "interpolated", digest(gathered(forest, r.values)))
    regridded("$tag.refine", forest, (fs => sched, pair => pscheds);
              flags=fill(Refine, length(blockrange(forest))), boundary=QUAD_HOOK)
    emit("#", tag, "empty ranks after refining", empties())
    sched = GhostSchedule(fs, OPS4)
    pscheds = (GhostSchedule(pair.a, OPS4), GhostSchedule(pair.b, OPS4))
    regridded("$tag.coarsen", forest, (fs => sched, pair => pscheds);
              flags=fill(Coarsen, length(blockrange(forest))), boundary=QUAD_HOOK)
    emit("#", tag, "empty ranks after coarsening", empties())
    path = joinpath(checkpoint_dir(), "$tag-n$NRANKS.h5")
    save_checkpoint(path, forest; fieldsets=("u" => fs, "a" => pair.a, "b" => pair.b),
                    application="QuadrantEmpty" => 1)
    loaded = quad_load(path, COMM)
    emit(tag, "checkpoint", nleaves(loaded[1]),
         quad_states(forest, fs, pair.a, pair.b) == quad_states(loaded...))
    return nothing
end

# --- checkpoints (step 6 of M7) --------------------------------------------

# Where the checkpoints go: `TREEAMR_CHECKPOINT_DIR`, which `mpi_tests.jl`
# sets to one directory for the serial run and every `mpiexec` run, so
# that each run can load what the runs before it wrote, at another rank
# count; otherwise a fresh directory, rank 0's, named to every rank.
function checkpoint_dir()
    dir = get(ENV, "TREEAMR_CHECKPOINT_DIR", "")
    isempty(dir) || return dir
    USE_MPI || return mktempdir()
    name = RANK == 0 ? collect(codeunits(mktempdir())) : UInt8[]
    return String(TreeAMR.allgatherv(TreeAMR.communicator(COMM), name))
end

# The tracked pulse as a chunked driver, as in `checkpoint_tests.jl`: a
# chunk is a few RK4 steps, the flags and a regrid, and the checkpoint
# goes at a chunk boundary, after the regrid, where the run holds nothing
# but the mesh, the owned points and `(t, chunk)`.
const CK_PULSE = moving_pulse((1.3, 1.4), 0.35)
const CK_HOOK = boundary_by_coordinates(CK_PULSE)

function ck_start(comm)
    forest = Forest((4, 3); N=8, comm=comm)
    fs = FieldSet(forest, 2; G=1, centering=vertexcentered(2))
    fill_by_coordinates!(CK_PULSE, fs)
    return (; forest, fs, t=0.0, chunk=0)
end

function ck_chunk(run; steps=3)
    (; forest, fs, t, chunk) = run
    sched = GhostSchedule(fs, OPS4)
    u = statevector(fs)
    gather!(u, fs)
    dt = 0.2 * minimum_spacing(forest)
    rk4!(u, fs, sched, dt, steps, Val(2), Val(fs.G), CK_HOOK)
    scatter!(fs, u)
    fill_ghosts!(fs, sched; boundary=CK_HOOK)
    regrid!(forest, fs => sched; flags=pulse_flags(fs, 2), buffer=2, boundary=CK_HOOK)
    return (; forest, fs, t=t + steps * dt, chunk=chunk + 1)
end

function ck_digests(run)
    u = statevector(run.fs)
    gather!(u, run.fs)
    return (digest(string(run.forest.leaves)), digest(gathered(run.forest, u)))
end

# The bare form, `name => fs`: `regrid!` has just filled the working
# array's owned points. The plain data carry the run state and an array
# of strings.
function ck_save(path, run; filters=(), io=:node)
    return save_checkpoint(path, run.forest; fieldsets=("pulse" => run.fs,),
                           application="PulseRestart" => 1, filters=filters, io=io,
                           data=(; t=run.t, chunk=run.chunk, σ=7 // 20,
                                 tags=["pulse", "", "vertex-centered"]))
end

function ck_restore(path, comm)
    ck = load_checkpoint(path; comm=comm)
    ck.data.tags == ["pulse", "", "vertex-centered"] && ck.data.σ === 7 // 20 ||
        error("the plain data did not come back exactly: $(ck.data)")
    return (; forest=ck.forest, fs=ck.fieldsets["pulse"].fieldset, t=ck.data.t,
            chunk=ck.data.chunk), ck.provenance
end

function ck_finish(run; chunks)
    while run.chunk < chunks
        run = ck_chunk(run)
    end
    return run
end

# One leaf per rank or fewer: a 1D cell-centered state on two leaves, so
# that at three ranks one rank holds no blocks when the file is written
# and when it is read.
function ck_small(comm)
    forest = Forest((2,); N=8, periodic=(true,), comm=comm)
    fs = FieldSet(forest, 1; G=2)
    fill_by_coordinates!((x, v) -> sin(π * x[1]) + x[1]^2 / 7, fs)
    return forest, fs
end

# The mesh refines in the first chunk and again in the second, so a
# checkpoint after the first is followed by a regrid that changes the
# mesh: a regrid that depended on something the file does not hold would
# show.
function checkpoint_case(tag; chunks=3, k=1)
    dir = checkpoint_dir()
    run = ck_finish(ck_start(COMM); chunks=chunks)
    emit(tag, "uninterrupted", ck_digests(run)...)
    final = nleaves(run.forest)
    # Saved after chunk `k`, everything dropped, and continued from each
    # file at this rank count: unfiltered with a part per rank, filtered
    # with two I/O groups (at three ranks, one of two ranks and one of
    # one), and with the default, a part per node, which on one node is
    # the one part inside the index.
    run = ck_finish(ck_start(COMM); chunks=k)
    emit(tag, "mesh", nleaves(run.forest), "then", final)
    emit(tag, "saved", ck_digests(run)...)
    plain = joinpath(dir, "$tag-n$NRANKS.h5")
    filtered = joinpath(dir, "$tag-n$NRANKS-filtered.h5")
    node = joinpath(dir, "$tag-n$NRANKS-node.h5")
    ck_save(plain, run; io=:all)
    ck_save(filtered, run; filters=(Shuffle(), Deflate(1)), io=2)
    ck_save(node, run)
    run = nothing
    for (name, path) in (("restarted", plain), ("restarted-filtered", filtered),
                         ("restarted-node", node))
        resumed, provenance = ck_restore(path, COMM)
        emit(tag, name, "loaded", ck_digests(resumed)...)
        emit(tag, name, "continued", ck_digests(ck_finish(resumed; chunks=chunks))...)
        emit("#", tag, name, "nranks", provenance.nranks, "nparts", provenance.nparts)
    end
    # The version-1 fixtures (`checkpoint_tests.jl`), loaded at this rank
    # count: their digests must be the serial run's.
    for name in ("plain", "filtered")
        ck = load_checkpoint(joinpath(@__DIR__, "fixtures", "checkpoint-v1-$name.h5");
                             comm=COMM, types=(Float32x2,))
        emit("V1", name, "loaded", digest(string(ck.forest.leaves)),
             digest(gathered(ck.forest, ck.fieldsets["u"].state)),
             digest(reinterpret(UInt8, gathered(ck.forest, ck.fieldsets["w"].state))),
             digest(string(ck.data)))
    end
    forest, fs = ck_small(COMM)
    u = statevector(fs)
    gather!(u, fs)
    emit(tag * "1", "saved", digest(gathered(forest, u)))
    save_checkpoint(joinpath(dir, "$(tag)1-n$NRANKS.h5"), forest;
                    fieldsets=("u" => (fs, u),), application="Small" => 1)
    ck = load_checkpoint(joinpath(dir, "$(tag)1-n$NRANKS.h5"); comm=COMM)
    emit(tag * "1", "loaded", digest(gathered(ck.forest, ck.fieldsets["u"].state)))
    emit("#", tag * "1", "empty ranks", count(TreeAMR.allgather(forest.comm,
                                                               nblocks(fs) == 0)))
    # Every file of this run is in place (each save returns on every rank
    # after the rename), which a run waiting to load them is told by an
    # empty marker file.
    RANK == 0 && touch(joinpath(dir, "$tag-n$NRANKS.done"))
    checkpoint_cross(tag; chunks=chunks)
    return nothing
end

# The rank counts whose files `checkpoint_cross` loads: those that
# `TREEAMR_CHECKPOINT_FROM` lists, once each run's marker is there, every
# rank waiting on its own so that none spins in a collective meanwhile;
# without the variable, every other rank count whose files are there.
function checkpoint_sources(dir, tag)
    from = get(ENV, "TREEAMR_CHECKPOINT_FROM", nothing)
    from === nothing && return nothing
    counts = parse.(Int, split(from))
    deadline = time() + parse(Float64, get(ENV, "TREEAMR_CHECKPOINT_WAIT", "900"))
    for n in counts
        marker = joinpath(dir, "$tag-n$n.done")
        while !isfile(marker)
            time() < deadline ||
                error("the checkpoints of the run at $n rank(s) did not appear: no $marker")
            sleep(0.2)
        end
    end
    return counts
end

# The files the other runs wrote, at other rank counts, loaded at this
# one and continued: a `#` line each, since which files exist depends on
# the order of the runs. Under MPI each is loaded a second time over
# `MPI.COMM_SELF`, every rank on its own, which is a load at one rank of
# MPI. Collective.
function checkpoint_cross(tag; chunks=3)
    dir = checkpoint_dir()
    counts = checkpoint_sources(dir, tag)
    names = filter(readdir(dir)) do name
        m = match(r"^(.*)-n(\d+)(-filtered|-node)?\.h5$", name)
        m === nothing && return false
        n = parse(Int, m[2])
        m[1] in (tag, tag * "1") && n != NRANKS && (counts === nothing || n in counts)
    end
    comms = USE_MPI ? ((NRANKS, COMM), (1, MPI.COMM_SELF)) : ((1, nothing),)
    for name in sort(names), (n, comm) in comms
        path = joinpath(dir, name)
        what = replace(name, ".h5" => "")
        if startswith(name, tag * "1")
            ck = load_checkpoint(path; comm=comm)
            emit("#", what, "at", n, "loaded",
                 digest(gathered(ck.forest, ck.fieldsets["u"].state)))
        else
            resumed, _ = ck_restore(path, comm)
            emit("#", what, "at", n, "loaded", ck_digests(resumed)...)
            emit("#", what, "at", n, "continued",
                 ck_digests(ck_finish(resumed; chunks=chunks))...)
        end
    end
    return nothing
end

# The files of the directory that belong to the checkpoint `path`: the
# index and every file named after it.
ck_files(path) = sort(filter(n -> n == basename(path) || startswith(n, basename(path) * "."),
                             readdir(dirname(path))))

# Whether no file was opened by more than one process during `f()`: every
# rank records the files it opens (a test hook of the HDF5 extension),
# and the records are gathered.
function opened_once(f)
    CKPT.OPEN_LOG[] = String[]
    try
        f()
    finally
        mine = unique(CKPT.OPEN_LOG[])
        CKPT.OPEN_LOG[] = nothing
        world = TreeAMR.communicator(COMM)
        all_ = split(String(TreeAMR.allgatherv(world, collect(codeunits(join(mine, "\n") *
                                                                       "\n")))), '\n';
                     keepempty=false)
        return allunique(all_) && !isempty(all_)
    end
end

# A refusal on some ranks, or arguments that differ between them, must be
# refused on every rank before the file is created, and leave the
# previous checkpoint at the path as it was.
function checkpoint_refusals()
    NRANKS > 1 || return nothing
    world = TreeAMR.communicator(COMM)
    function attempt(f)
        msg = try
            f()
            ""
        catch err
            err isa ArgumentError || rethrow()
            err.msg
        end
        return count(TreeAMR.allgather(world, !isempty(msg))), msg
    end
    dir = checkpoint_dir()
    path = joinpath(dir, "refused-n$NRANKS.h5")
    forest = Forest((4, 4); N=8, comm=COMM)
    fs = FieldSet(forest, 1; G=1)
    fill_by_coordinates!((x, v) -> x[1] - x[2], fs)
    save(; kwargs...) = save_checkpoint(path, forest; fieldsets=("u" => fs,),
                                        application="Refused" => 1, io=1, kwargs...)
    save(; data=(; t=1.0))
    n, msg = attempt(() -> save(; data=(; t=1.0, rank=RANK)))
    emit("# checkpoint data refused on", n, "of", NRANKS, "ranks:", msg)
    n, msg = attempt(() -> save_checkpoint(path, forest; fieldsets=("u" => fs,),
                                           application=(RANK == 1 ? "TreeAMR.jl" :
                                                        "Refused") => 1))
    emit("# checkpoint partial refused on", n, "of", NRANKS, "ranks:", msg)
    n, msg = attempt(() -> save(; filters=RANK == 1 ? (Deflate(1),) : ()))
    emit("# checkpoint layout refused on", n, "of", NRANKS, "ranks:", msg)
    # In the do-block, after the file is created: refused on every rank
    # before the item is written, the file closed and the partial removed.
    n, msg = attempt(() -> save_checkpoint(path, forest; fieldsets=("u" => fs,),
                                           application="Refused" => 1) do app
                         write_plain(app, "mine", RANK)
                     end)
    emit("# checkpoint write_plain refused on", n, "of", NRANKS, "ranks:", msg)
    intact = load_checkpoint(path; comm=COMM).data == (; t=1.0) &&
             !ispath(path * ".partial")
    emit("# checkpoint refusals left the file alone",
         all(TreeAMR.allgather(world, intact)))
    n, msg = attempt(() -> load_checkpoint(path; comm=COMM,
                                           fieldsets=RANK == 1 ? ("v",) : ("u",)))
    emit("# load layout refused on", n, "of", NRANKS, "ranks:", msg)
    n, msg = attempt(() -> load_checkpoint(joinpath(dir, "missing.h5"); comm=COMM))
    emit("# load missing refused on", n, "of", NRANKS, "ranks:", msg)
    # Damage only the last part's reader can see — one value of the last
    # block, changed by rank 0 alone in the last part file between the save
    # and the load — is refused by the checksums on every rank, which is
    # the agreement: the other parts are intact. This is the multi-node
    # corruption of step 6 made by hand; no file is shared any more, so
    # none can happen on its own.
    damaged = joinpath(dir, "damaged-n$NRANKS.h5")
    save_checkpoint(damaged, forest; fieldsets=("u" => fs,), application="Refused" => 1,
                    io=:all)
    world_barrier() = TreeAMR.allgather(world, true)
    parts = filter(n -> n != basename(damaged), ck_files(damaged))
    if RANK == 0
        lastpart = last(sort(parts; by=n -> parse(Int, split(n, '.')[end - 1])))
        HDF5.h5open(joinpath(dir, lastpart), "r+") do file
            data = file["TreeAMR.jl/fieldsets/u/data"]
            d = read(data)
            d[2, 3, 1, end] += 1
            data[:, :, :, :] = d
        end
    end
    world_barrier()
    n, msg = attempt(() -> load_checkpoint(damaged; comm=COMM))
    emit("# checkpoint damage refused on", n, "of", NRANKS, "ranks:", msg)
    # A part of another save in place of one of this save's, and a part
    # missing: both refused on every rank, before any data move.
    other = joinpath(dir, "other-n$NRANKS.h5")
    save_checkpoint(other, forest; fieldsets=("u" => fs,), application="Refused" => 1,
                    io=:all)
    save_checkpoint(damaged, forest; fieldsets=("u" => fs,), application="Refused" => 1,
                    io=:all)
    partof(path, j) = only(filter(n -> endswith(n, ".$j.h5"), ck_files(path)))
    if RANK == 0
        cp(joinpath(dir, partof(other, 1)), joinpath(dir, partof(damaged, 1)); force=true)
    end
    world_barrier()
    n, msg = attempt(() -> load_checkpoint(damaged; comm=COMM))
    emit("# checkpoint foreign part refused on", n, "of", NRANKS, "ranks:", msg)
    RANK == 0 && rm(joinpath(dir, partof(other, NRANKS - 1)))
    world_barrier()
    n, msg = attempt(() -> load_checkpoint(other; comm=COMM))
    emit("# checkpoint missing part refused on", n, "of", NRANKS, "ranks:", msg)
    # Orphans: a file of the part form for the index, from a save no index
    # names, is removed by the next save, and so are the previous save's
    # parts; files of other forms are left alone.
    orphans = joinpath(dir, "orphans-n$NRANKS.h5")
    keep = [basename(orphans) * ".notapart.h5", basename(orphans) * "." * "a"^31 * ".0.h5",
            basename(orphans) * "x." * "a"^32 * ".0.h5"]
    if RANK == 0
        touch(joinpath(dir, basename(orphans) * "." * "b"^32 * ".7.h5"))
        foreach(name -> touch(joinpath(dir, name)), keep)
    end
    world_barrier()
    save_checkpoint(orphans, forest; fieldsets=("u" => fs,), application="Refused" => 1,
                    io=:all)
    # Rank 0 removes the stale files after the commit, when the other ranks
    # have returned: they wait for it here before they look.
    world_barrier()
    first_parts = ck_files(orphans)
    save_checkpoint(orphans, forest; fieldsets=("u" => fs,), application="Refused" => 1,
                    io=:all)
    world_barrier()
    after = ck_files(orphans)
    # The index, its parts, and the two of `keep` named after the index.
    cleaned = length(after) == NRANKS + 3 &&
              !(basename(orphans) * "." * "b"^32 * ".7.h5" in after) &&
              isempty(intersect(setdiff(first_parts, [basename(orphans)], keep), after)) &&
              all(name -> isfile(joinpath(dir, name)), keep)
    emit("# checkpoint orphans removed", all(TreeAMR.allgather(world, cleaned)))
    # An I/O process that fails after its first write (a test hook): the
    # save is refused on every rank, the previous checkpoint still loads,
    # and none of the new parts, nor the partial index, is left.
    world_barrier()
    before = ck_files(orphans)
    CKPT.FAIL_PART[] = NRANKS - 1
    n, msg = try
        attempt(() -> save_checkpoint(orphans, forest; fieldsets=("u" => fs,),
                                      application="Refused" => 1, io=:all,
                                      data=(; t=2.0)))
    catch err
        # Not an ArgumentError: an I/O error, which `attempt` rethrows.
        count(TreeAMR.allgather(world, true)), sprint(showerror, err)
    finally
        CKPT.FAIL_PART[] = -1
    end
    emit("# checkpoint failed part on", n, "of", NRANKS, "ranks:", first(split(msg, '\n')))
    intact = ck_files(orphans) == before &&
             load_checkpoint(orphans; comm=COMM).data == (;)
    emit("# checkpoint failed part left the previous one", all(TreeAMR.allgather(world,
                                                                                  intact)))
    # No file opened by more than one process, saving with two I/O groups
    # and loading.
    once = joinpath(dir, "once-n$NRANKS.h5")
    saved = opened_once(() -> save_checkpoint(once, forest; fieldsets=("u" => fs,),
                                              application="Refused" => 1, io=2))
    loaded = opened_once(() -> load_checkpoint(once; comm=COMM))
    emit("# checkpoint each file opened by one process", saved, loaded)
    return nothing
end

# --- the cases --------------------------------------------------------------

const OPS4 = Operators(prolongation=4, restriction=4)

function main()
    emit("# ranks", NRANKS)
    # A rank without blocks through everything, at three ranks, ending in
    # a checkpoint.
    empty_rank_case("E2")
    # A rotating quadrant (M12): a set that turns into itself and a pair
    # through a fill, a regrid, interpolation and a checkpoint, loaded at
    # the other rank counts as well; and a single leaf at the axis, which
    # leaves every rank but one without blocks.
    rotating_case("Q2")
    rotating_empty_case("QE2")
    # Checkpoints: saved and loaded at this rank count, and the files of
    # the runs before this one loaded at it.
    checkpoint_case("C")
    checkpoint_refusals()
    return nothing
end

try
    main()
catch err
    # A rank that fails must not leave the others waiting in a
    # collective: take the whole job down.
    showerror(stderr, err, catch_backtrace())
    println(stderr)
    USE_MPI && MPI.Abort(MPI.COMM_WORLD, 1)
    rethrow()
end
