"""
    DataStructures

The `DataStructures` module implements useful data structures.

Currently, we have implemented a Least Recently Used (LRU) cache. The cache is
implemented as a dictionary with a maximum size. When the cache is full, the
least recently used item is removed to make space for the new item.

Within ClimaUtilities, the LRU cache is used by the `FileReaders` module to
store files that are currently open, and by the `DataHandler` module to store
regridded fields.
"""
module DataStructures

import Base: Callable

export LRUCache

struct LRUCache{K, V}
    """The cache itself, containing key-value pairs of information."""
    cache::Dict{K, V}

    """The maximum number of key-value pairs in the cache."""
    max_size::Int

    """A list of keys, ordered by their last access time, which serves as a
    priority queue for the cache. Note that another data structure could be
    more efficient here, but a built-in vector is sufficient given that
    the cache is not expected to be very large."""
    priority::Vector{K}
end

"""
    LRUCache{K, V}(; max_size::Int = 128) where {K, V}

Construct an empty `LRUCache` with a maximum size of `max_size`.
"""
function LRUCache{K, V}(; max_size::Int = 128) where {K, V}
    return LRUCache{K, V}(Dict{K, V}(), max_size, Vector{K}())
end

"""
    Base.get!(cache::LRUCache{K, V}, key::K, default::V) where {K, V}

Get the value associated with `key` in `cache`. If the key is not in the
cache, add it with the value `default`. In any case, update the key's priority
and make sure the cache doesn't exceed its maximum size.
"""
function Base.get!(cache::LRUCache{K, V}, key::K, default::V) where {K, V}
    _update_priority!(cache, key)
    _enforce_size!(cache)
    return get!(cache.cache, key, default)
end

"""
    Base.get!(default::Callable, cache::LRUCache{K, V}, key::K) where {K, V}

Get the value associated with `key` in `cache`. If the key is not in the
cache, add it with the value `default()`. In any case, update the key's priority
and make sure the cache doesn't exceed its maximum size.

This method is intended to be used with `do` block syntax.
"""
function Base.get!(
    default::Callable,
    cache::LRUCache{K, V},
    key::K,
) where {K, V}
    _update_priority!(cache, key)
    _enforce_size!(cache)
    return get!(default, cache.cache, key)
end

"""
    Base.get(cache::LRUCache{K, V}, key::K, default::V)

Get the value associated with `key` in `cache`. If the key is not in the
cache, return the `default`. If the `key` is in `cache`, update the key's priority.
"""
function Base.get(cache::LRUCache{K, V}, key::K, default::V) where {K, V}
    if haskey(cache, key)
        _update_priority!(cache, key)
    end
    return get(cache.cache, key, default)
end

"""
    Base.get(default::Callable, cache::LRUCache{K, V}, key::K)

Get the value associated with `key` in `cache`. If the key is not in the
cache, return the `default`. In any case, update the key's priority.
"""
function Base.get(default::Callable, cache::LRUCache{K, V}, key::K) where {K, V}
    if haskey(cache, key)
        _update_priority!(cache, key)
    end
    return get(default, cache.cache, key)
end

"""
    Base.haskey(cache::LRUCache{K, V}, key::K)
Determine if the `key` has a mapping in the `cache` and return
true if it is and false if it is not. 
"""
function Base.haskey(cache::LRUCache{K, V}, key::K) where {K, V}
    return haskey(cache.cache, key)
end

"""
    Base.copy(cache::LRUCache{K, V})

Creates a shallow copy of `cache`.
"""
function Base.copy(cache::LRUCache{K, V}) where {K, V}
    return LRUCache{K, V}(
        copy(cache.cache),
        cache.max_size,
        copy(cache.priority),
    )
end

"""
    Base.deepcopy(cache::LRUCache{K, V})

Creates a deep copy of `cache`.
"""
function Base.deepcopy(cache::LRUCache{K, V}) where {K, V}
    return LRUCache{K, V}(
        deepcopy(cache.cache),
        cache.max_size,
        deepcopy(cache.priority),
    )
end


"""
    Base.empty(cache::LRUCache{K, V}, [key_type::DataType=], [value_type::DataType=V])

Creates an empty `LRUCache` with the same `max_size` as the input that has keys of type 
`key_type` and values of type `value_type`. The second and third arguments are
optional and default to the input's keytype and valuetype. If only one of the two type is specified,
it is assumed to be the `value_type` and `key_type` is defaulted to the key type of the input.
"""
function Base.empty(
    cache::LRUCache{K, V},
    key_type::DataType = K,
    value_type::DataType = V,
) where {K, V}
    return LRUCache{key_type, value_type}(max_size = cache.max_size)
end

function Base.empty(
    cache::LRUCache{K, V},
    value_type::DataType = V,
) where {K, V}
    return LRUCache{K, value_type}(max_size = cache.max_size)
end

"""
    Base.empty!(cache::LRUCache{K, V})

Removes all key/value mappings from the input, empties the priority list, and then returns the emptied input
"""
function Base.empty!(cache::LRUCache{K, V}) where {K, V}
    empty!(cache.cache)
    empty!(cache.priority)
    return cache
end

"""
    Base.pop!(cache::LRUCache{K, V}, key::K, [default::V])

If a mapping for `key` exists in `cache`, delete the mapping and return the `value`. 
If the `key` does not exist, then return `default` or throw an error if `default` is not specified
"""
function Base.pop!(cache::LRUCache{K, V}, key::K, default::V) where {K, V}
    value = pop!(cache.cache, key, default)
    filter!(k -> k != key, cache.priority)
    return value
end

function Base.pop!(cache::LRUCache{K, V}, key::K) where {K, V}
    value = pop!(cache.cache, key)
    filter!(k -> k != key, cache.priority)
    return value
end

"""
    Base.delete!(cache::LRUCache{K, V}, key::K)

Delete mapping for key, if it is cache, and return the LRUcache
"""
function Base.delete!(cache::LRUCache{K, V}, key::K) where {K, V}
    value = delete!(cache.cache, key)
    filter!(k -> k != key, cache.priority)
    return value
end

"""
   Base.merge(cache_1::LRUCache{K1, V1}, cache_2::LRUCache{K2, V2})

Delete mapping for key, if it is cache, and return the LRUcache
"""
function Base.merge(
    cache_1::LRUCache{K1, V1},
    cache_2::LRUCache{K2, V2},
) where {K1, V1, K2, V2}
    throw(ErrorException("Merge not implemented for LRUCache"))
    return
end


"""
    _update_priority!(cache, key)

Update the priority of `key` in `cache` to reflect its most recent access.
"""
function _update_priority!(cache, key)
    # Remove the key if it's already in the priority queue
    filter!(k -> k != key, cache.priority)
    # Add the key to the end of the priority queue
    push!(cache.priority, key)
    return
end

"""
    _enforce_size!(cache::LRUCache{K, V})

Remove the least recently used items from `cache` until its size is
less than or equal to `cache.max_size`.
"""
function _enforce_size!(cache::LRUCache{K, V}) where {K, V}
    if length(cache.priority) > cache.max_size
        key = popfirst!(cache.priority)
        delete!(cache.cache, key)
    end
end


end # module
