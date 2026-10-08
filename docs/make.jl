using Documenter
using TreeAMR
using TreeIOHDF5

DocMeta.setdocmeta!(TreeIOHDF5, :DocTestSetup, :(using TreeAMR, TreeIOHDF5);
                    recursive=true)

makedocs(;
    sitename="TreeIOHDF5.jl",
    modules=[TreeIOHDF5],
    pages=["Home" => "index.md", "API reference" => "api.md"],
)

deploydocs(; repo="github.com/eschnett/TreeIOHDF5.jl.git")
