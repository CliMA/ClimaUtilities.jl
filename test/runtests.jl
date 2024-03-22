using SafeTestsets

# Performance and code quality tests
@safetestset "Aqua tests" begin
    include("aqua.jl")
end

# Unit tests
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
