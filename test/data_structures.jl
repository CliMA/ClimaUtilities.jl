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

@testset "get with default value" begin
    cache = DataStructures.LRUCache{String, Int}(max_size = 3)

    # Test cache hits (key in dict)
    get!(cache, "a", 1)
    get!(cache, "b", 2)
    @test get(cache, "a", 3) == 1
    @test cache.priority == ["b", "a"]

    # check cache miss (key not in dict)
    @test get(cache, "c", 3) == 3
    @test get(cache, "c", 2) == 2
    @test cache.priority == ["b", "a"]
end

@testset "get with default callable" begin
    cache = DataStructures.LRUCache{String, Int}(max_size = 3)

    # Test cache hits (key in dict)
    get!(cache, "a", 1)
    get!(cache, "b", 2)
    @test get(() -> 3, cache, "a") == 1
    @test cache.priority == ["b", "a"]

    # # check cache miss (key not in dict)
    @test get(() -> 3, cache, "c") == 3
    @test get(() -> 2, cache, "c") == 2
    @test cache.priority == ["b", "a"]
end

@testset "haskey LRU" begin
    cache = DataStructures.LRUCache{String, Int}(max_size = 3)

    # Test haskey if key exists
    get!(cache, "a", 1)
    get!(cache, "b", 2)
    @test haskey(cache, "a") == true
    # Check haskey doesnt mutate priority
    @test cache.priority == ["a", "b"]
    # Test if key does not exist
    @test haskey(cache, "c") == false
    @test cache.priority == ["a", "b"]

    # Test if key added
    get!(cache, "c", 3)
    @test haskey(cache, "c") == true
end

@testset "copy LRU" begin
    cache1 = DataStructures.LRUCache{String, Vector{Int64}}(max_size = 3)
    get!(cache1, "a", [1])
    get!(cache1, "b", [2])

    # test copy for equivalence
    cache2 = copy(cache1)
    @test cache2.priority == cache1.priority
    @test cache2.cache == cache1.cache
    @test cache2.max_size == cache1.max_size

    # check that copying object not just reference
    get!(cache1, "c", [3])
    @test cache2 != cache1

    # check that it is shallow copying
    cache2 = copy(cache1)
    push!(get!(cache1, "a", [1]), 1)
    @test cache2.cache == cache1.cache
    @test cache2.priority != cache1.priority
    @test cache2.priority == ["a", "b", "c"]
end

@testset "deepcopy" begin
    cache1 =
        DataStructures.LRUCache{String, Vector{Vector{Int64}}}(max_size = 3)
    get!(cache1, "a", [[1]])
    get!(cache1, "b", [[2]])

    # test copy for equivalence
    cache2 = deepcopy(cache1)
    @test cache2.priority == cache1.priority
    @test cache2.cache == cache1.cache
    @test cache2.max_size == cache1.max_size

    # test that copying object not just reference
    get!(cache1, "c", [[3]])
    @test cache2 != cache1

    # test that it is deep copying
    cache2 = deepcopy(cache1)
    push!(getindex(get!(cache1, "a", [[1]]), 1), 1)
    @test cache2.cache != cache1.cache
    @test cache1.priority == ["b", "c", "a"]
    @test cache2.priority == ["a", "b", "c"]
end
@testset "empty LRU" begin
    cache = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache, "a", 1)
    get!(cache, "b", 2)

    # test that it is returning a new empty LRUcache
    empty_cache = empty(cache)
    @test empty_cache != cache
    # test that if not specified, key and value types are copied
    @test empty_cache.cache == Dict{String, Int64}()
    @test typeof(empty_cache.cache) == typeof(Dict{String, Int64}())
    @test empty_cache.priority == []
    @test empty_cache.max_size == cache.max_size

    # test empty if a second arg is given
    empty_cache = empty(cache, Char)
    @test empty_cache.cache == Dict{String, Char}()
    @test typeof(empty_cache.cache) == typeof(Dict{String, Char}())
    @test typeof(empty_cache.priority) == Vector{String}

    # test empty if two args are given
    empty_cache = empty(cache, Int64, String)
    @test empty_cache.cache == Dict{Int64, String}()
    @test typeof(empty_cache.cache) == typeof(Dict{Int64, String}())
    @test typeof(empty_cache.priority) == Vector{Int64}
end

@testset "empty! LRU" begin
    cache = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache, "a", 1)
    get!(cache, "b", 2)

    # test that it is returning a new empty LRUcache
    cache_reference_copy = cache
    empty!(cache)
    @test cache_reference_copy == cache
    @test cache.cache == Dict{String, Int64}()
    @test typeof(cache.cache) == typeof(Dict{String, Int64}())
    @test cache.priority == []
end

@testset "empty! LRU" begin
    cache = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache, "a", 1)
    get!(cache, "b", 2)

    # test that it is returning a new empty LRUcache
    cache_reference_copy = cache
    empty!(cache)
    @test cache_reference_copy == cache
    @test cache.cache == Dict{String, Int64}()
    @test typeof(cache.cache) == typeof(Dict{String, Int64}())
    @test cache.priority == []
end

@testset "pop! LRU" begin
    cache = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache, "a", 1)
    get!(cache, "b", 2)
    get!(cache, "c", 3)

    # test that it deletes and returns mapping for key if in cache
    @test pop!(cache, "b") == 2
    @test cache.cache == Dict{String, Int64}("a" => 1, "c" => 3)
    @test cache.priority == ["a", "c"]

    # test that popping key that doesn't exist without specifying default
    # throws error
    @test_throws KeyError pop!(cache, "b")

    # test that default returned if key not in cache
    @test pop!(cache, "b", 5) == 5
end

@testset "delete! LRU" begin
    cache = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache, "a", 1)
    get!(cache, "b", 2)
    get!(cache, "c", 3)

    # test when key in cache, that it deletes and returns the cache
    delete!(cache, "b")
    @test cache.cache == Dict{String, Int64}("a" => 1, "c" => 3)
    @test cache.priority == ["a", "c"]

    # test that deleting key that isnt in cache just returns the cache
    delete!(cache, "b")
    @test cache.cache == Dict{String, Int64}("a" => 1, "c" => 3)
    @test cache.priority == ["a", "c"]
end


@testset "merge LRU" begin
    cache1 = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache1, "a", 1)
    get!(cache1, "b", 2)
    cache2 = DataStructures.LRUCache{String, Int64}(max_size = 3)
    get!(cache1, "a", 3)
    get!(cache1, "c", 4)

    # test merging two LRUcaches throws error
    @test_throws ErrorException merge(cache1, cache2)
end
