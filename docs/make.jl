using Documenter
using Mongoose

makedocs(
    modules = [Mongoose],
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://AbrJA.github.io/Mongoose.jl",
    ),
    pages = [
        "Introduction" => "index.md",
        "Examples" => "examples.md",
        "API" => "api.md",
    ],
    repo = Remotes.GitHub("AbrJA", "Mongoose.jl"),
    sitename = "Mongoose.jl",
    authors = "Abraham Jaimes"
)

deploydocs(
    repo = "github.com/AbrJA/Mongoose.jl",
    push_preview = true
)
