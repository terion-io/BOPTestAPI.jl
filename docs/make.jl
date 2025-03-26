using Documenter, BOPTestAPI

makedocs(sitename="BOPTestAPI.jl", modules = [BOPTestAPI])

deploydocs(
    repo = "github.com/terion-io/BOPTestAPI.jl.git",
    # push_preview = true,
)