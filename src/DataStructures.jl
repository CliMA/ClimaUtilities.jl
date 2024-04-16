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
