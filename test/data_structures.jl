using Test
import ClimaUtilities.DataStructures

@testset "Construct LRUCache" begin
    cache = DataStructures.LRUCache{Int, Int}(max_size = 10)
    @test isempty(cache.cache)
    @test isempty(cache.priority)
    @test cache.max_size == 10
end

@testset "get! with default value" begin
    cache = DataStructures.LRUCache{String, Int}(max_size = 3)

    # Test adding new values (cache misses)
    @test get!(cache, "a", 1) == 1
    @test cache.priority == ["a"]
    @test get!(cache, "b", 2) == 2
    @test cache.priority == ["a", "b"]
    get!(cache, "c", 3)
    @test cache.priority == ["a", "b", "c"]

    # Test updating existing values (cache hits)
    @test get!(cache, "a", 4) == 1
    @test cache.priority == ["b", "c", "a"]

    # Test enforcing size limit
    get!(cache, "d", 5)
    @test cache.priority == ["c", "a", "d"]
    @test length(cache.priority) == length(keys(cache.cache)) == cache.max_size
end

@testset "get! with default callable" begin
    cache = DataStructures.LRUCache{String, Int}(max_size = 3)

    # Test adding new values (cache misses)
    @test get!(() -> 1, cache, "a") == 1
    @test cache.priority == ["a"]
    @test get!(() -> 2, cache, "b") == 2
    @test cache.priority == ["a", "b"]
    get!(() -> 3, cache, "c")
    @test cache.priority == ["a", "b", "c"]

    # Test updating existing values (cache hits)
    @test get!(() -> 4, cache, "a") == 1
    @test cache.priority == ["b", "c", "a"]

    # Test enforcing size limit
    get!(() -> 5, cache, "d")
    @test cache.priority == ["c", "a", "d"]
    @test length(cache.priority) == length(keys(cache.cache)) == cache.max_size
end
