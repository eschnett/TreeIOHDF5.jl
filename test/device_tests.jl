# Checkpoints of field sets on a device backend.
#
# The CPU backend always; a device as well when `TREEAMR_TEST_BACKEND` is
# `cuda` or `metal` and that package is in the environment, as in
# TreeAMR's `gpu_tests.jl`:
#
#     TREEAMR_TEST_BACKEND=metal julia --project=<env> test/runtests.jl

using KernelAbstractions: CPU, get_backend, supports_float64

const GPU_NAME = lowercase(get(ENV, "TREEAMR_TEST_BACKEND", ""))

if GPU_NAME == "cuda"
    using CUDA
elseif GPU_NAME == "metal"
    using Metal
elseif !isempty(GPU_NAME)
    error("TREEAMR_TEST_BACKEND must be \"cuda\" or \"metal\", got \"$GPU_NAME\"")
end

const BACKENDS = let out = Any[("CPU", CPU(), (Float64, Float32))]
    device = GPU_NAME == "cuda" ? (CUDA.functional() ? CUDABackend() : nothing) :
             GPU_NAME == "metal" ? (Metal.functional() ? MetalBackend() : nothing) :
             nothing
    if device === nothing
        isempty(GPU_NAME) ||
            @info "TREEAMR_TEST_BACKEND=$GPU_NAME is not functional here; CPU only"
    else
        types = supports_float64(device) ? (Float64, Float32) : (Float32,)
        push!(out, (GPU_NAME, device, types))
    end
    out
end

@testset "$bname: a checkpoint round-trips through the device: T=$T" for
        (bname, backend, types) in BACKENDS, T in types
    # M9a on a device. A save copies the state vector to the host, and a
    # load reads into a host buffer and uploads it; neither may change a
    # bit, and a file written from a device loads on the CPU as well as
    # on the device, since nothing in it depends on the backend. Both
    # forms of a field set are saved: `(fs, u)`, and the bare set, which
    # gathers on the device first. The comparison is of bytes on the host.
    forest = Forest((2, 2); N=8, periodic=(true, true),
                    extents=ntuple(_ -> (zero(T), one(T)), 2))
    refine!(forest, forest.leaves[1])
    balance!(forest)
    four = T(4)
    f = (x, v) -> sin(four * x[1]) * cos(four * x[2]) + oftype(x[1], v)
    fs = FieldSet{T}(forest, 2; G=2, backend=backend)
    fill_by_coordinates!(f, fs)
    u = statevector(fs)
    gather!(u, fs)
    path = joinpath(mktempdir(), "device.h5")
    save_checkpoint(path, forest; fieldsets=("u" => (fs, u), "w" => fs),
                    application="Device" => 1)
    ops = Operators(prolongation=4, restriction=4)
    fill_ghosts!(fs, GhostSchedule(fs, ops))
    want = reinterpret(UInt8, Array(u))
    for bk in (CPU(), backend)
        ck = load_checkpoint(path; backend=bk)
        @test ck.forest.leaves == forest.leaves
        for name in ("u", "w")
            loaded, v = ck.fieldsets[name].fieldset, ck.fieldsets[name].state
            @test typeof(get_backend(v)) === typeof(bk)
            @test typeof(get_backend(loaded.work)) === typeof(bk)
            @test reinterpret(UInt8, Array(v)) == want
            # The ghost fill on the loaded set, on the backend it was
            # loaded to, reproduces the original's on the same backend.
            if typeof(bk) === typeof(backend)
                fill_ghosts!(loaded, GhostSchedule(loaded, ops))
                @test reinterpret(UInt8, vec(Array(loaded.work))) ==
                      reinterpret(UInt8, vec(Array(fs.work)))
            end
        end
    end
end
