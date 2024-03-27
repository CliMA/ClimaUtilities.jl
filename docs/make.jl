using Documenter
using ClimaUtilities

# Load everything to load extensions
import Interpolations
import ClimaComms
import ClimaCore
import NCDatasets
import ClimaCoreTempestRemap

pages = [
    "Overview" => "index.md",
    "ClimaArtifacts" => "climaartifacts.md",
    "Space and Time Inputs" => "inputs.md",
    "FileReaders" => "filereaders.md",
    "DataHandling" => "datahandling.md",
    "Regridders" => "regridders.md",
    "TimeManager" => "timemanager.md",
]

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
    modules = [
        ClimaUtilities,
        Base.get_extension(ClimaUtilities, :ClimaArtifactsExt),
        Base.get_extension(ClimaUtilities, :DataHandlingExt),
        Base.get_extension(ClimaUtilities, :InterpolationsRegridderExt),
        Base.get_extension(ClimaUtilities, :NCFileReaderExt),
        Base.get_extension(ClimaUtilities, :SpaceVaryingInputsExt),
        Base.get_extension(ClimaUtilities, :TempestRegridderExt),
        Base.get_extension(ClimaUtilities, :TimeVaryingInputs0DExt),
        Base.get_extension(ClimaUtilities, :TimeVaryingInputsExt),
    ],
)

deploydocs(
    repo = "github.com/CliMA/ClimaUtilities.jl.git",
    target = "build",
    push_preview = true,
    devbranch = "main",
    forcepush = true,
)
