using Documenter, Example, Literate
using ClimaUtilities

# TODO fill in once we have doc pages
pages = Any[]

mathengine = MathJax(
    Dict(
        :TeX => Dict(
            :equationNumbers => Dict(:autoNumber => "AMS"),
            :Macros => Dict(),
        ),
    ),
)
format = Documenter.HTML(
    prettyurls = !isempty(get(ENV, "CI", "")),
    collapselevel = 1,
    mathengine = mathengine,
)

makedocs(
    sitename = "ClimaUtilities.jl",
    authors = "CliMA Utilities Developers",
    format = format,
    pages = pages,
    checkdocs = :exports,
    doctest = true,
    strict = false,
    clean = true,
    modules = [ClimaUtilities],
)

deploydocs(
    repo = "github.com/CliMA/ClimaUtilities.jl.git",
    target = "build",
    push_preview = true,
    devbranch = "main",
    forcepush = true,
)
