using SafeTestsets

# Performance and code quality tests
@safetestset "Aqua tests" begin
    include("aqua.jl")
end

# Unit tests
@safetestset "TimeManager tests" begin
    include("timemanager.jl")
end
