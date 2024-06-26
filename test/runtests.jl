using SafeTestsets
using Pkg

Pkg.Artifacts.ensure_all_artifacts_installed(
    joinpath(@__DIR__, "Artifacts.toml"),
)

# Performance and code quality tests
@safetestset "Aqua tests" begin
    include("aqua.jl")
end

# Unit tests
@safetestset "Utils tests" begin
    include("utils.jl")
end

@safetestset "OutputPathGenerator tests" begin
    include("output_path_generator.jl")
end

@safetestset "TimeManager tests" begin
    include("timemanager.jl")
end

@safetestset "DataStructures tests" begin
    include("data_structures.jl")
end

@safetestset "FileReaders tests" begin
    include("file_readers.jl")
end

@safetestset "Regridders tests" begin
    include("regridders.jl")
end

@safetestset "DataHandling tests" begin
    include("data_handling.jl")
end

@safetestset "SpaceVaryingInputs tests" begin
    include("space_varying_inputs.jl")
end

@safetestset "TimeVaryingInputs tests" begin
    include("time_varying_inputs.jl")
end

@safetestset "ClimaArtifacts tests" begin
    include("clima_artifacts.jl")
end
