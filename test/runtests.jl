using SafeTestsets

# Performance and code quality tests
@safetestset "Aqua tests" begin
    include("aqua.jl")
end

# Unit tests
@safetestset "Utils tests" begin
    include("utils.jl")
end

@safetestset "TimeManager tests" begin
    include("timemanager.jl")
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
