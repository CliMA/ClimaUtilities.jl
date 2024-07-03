module Utils
"""
    searchsortednearest(a, x)

Find the index corresponding to the nearest value to `x` in `a`.
"""
function searchsortednearest(a, x)
    i = searchsortedfirst(a, x)
    if i == 1            # x <= a[1]
        return i
    elseif i > length(a) # x > a[end]
        return length(a)
    elseif a[i] == x     # x is one of the elements
        return i
    else                 # general case
        return abs(a[i] - x) < abs(a[i - 1] - x) ? i : i - 1
    end
end


"""
    linear_interpolation(indep_vars, dep_vars, indep_value)

Carries out linear interpolation to obtain a value at
location `indep_value`, using a independent variable
1-d vector `indep_vars` and a dependent variable
1-d vector `dep_vars`.

If the `indep_value` is outside the range of `indep_vars`, this
returns the endpoint value closest.
"""
function linear_interpolation(indep_vars, dep_vars, indep_value)
    N = length(indep_vars)
    id = searchsortedfirst(indep_vars, indep_value)
    indep_value in indep_vars && return dep_vars[id]
    if id == 1
        dep_vars[begin]
    elseif id == N + 1
        dep_vars[end]
    else
        id_prev = id - 1
        x0, x1 = indep_vars[id_prev], indep_vars[id]
        y0, y1 = dep_vars[id_prev], dep_vars[id]
        y0 + (y1 - y0) / (x1 - x0) * (indep_value - x0)
    end
end

"""
    isequispaced(v; tol::Real = sqrt(eps(eltype(v)))

Check if the vector `v` has uniform spacing between its elements within a given tolerance
`tol`.

# Arguments
- `v::AbstractVector{<:Number}`: A vector of numerical values.
- `tol::Real`: A tolerance value to account for floating-point precision errors (default is
  `sqrt(eps(eltype(v)))`).

# Returns

- `Bool`: Returns `true` if the vector is equispaced within the given tolerance, `false`
  otherwise.

# Example

```jldoctest
julia> v1 = [1, 2, 3, 4, 5];
julia> isequispaced(v1)
true

julia> v2 = [1, 2, 4, 8, 16];
julia> isequispaced(v2)
false

julia> v3 = [1.0, 2.0, 3.0, 4.0, 5.0];
julia> isequispaced(v3)
true

julia> v4 = [1.0, 2.0, 3.1, 4.0, 5.0];
julia> isequispaced(v4)
false
```
"""
function isequispaced(
    v;
    tol = eltype(v) <: AbstractFloat ? sqrt(eps(eltype(v))) : eps(),
)
    length(v) < 2 && return true
    diffs = diff(v)
    return all(abs(d - diffs[begin]) < tol for d in diffs)
end

"""
    wrap_time(time, t_init, t_end; extend_past_t_end = false, dt = nothing)

Return `time` assuming periodicity so that `t_init <= time < t_end`.

Two modes are available:

When `extend_past_t_end` is true, wrap time at `t_end + dt` instead of `t_end`. This is
often used when time is a calendar date. For example, if `t_init = 15 Jan` and `t_end = 15
Dec`, and `dt = 1 Month`, one typically wants to identify `t_init = t_end + 1 Month`.

To better understand the difference, consider the examples below.

> Note: pay attention to the floating point representation! Sometimes it will lead to
  unexpected results.

Examples
========

With `extend_past_t_end = false`:

```jldoctest
julia> t_init = 0.1; t_end = 1.0;
julia> wrap_time(0.1, t_init, t_end)
0.1

julia> wrap_time(0.5, t_init, t_end)
0.5

julia> wrap_time(0.8, t_init, t_end)
0.8

julia> wrap_time(1.0, t_init, t_end)
0.1

julia> wrap_time(1.6, t_init, t_end)
0.7

julia> wrap_time(2.2, t_init, t_end)
0.4

# Floating points, 1.9 should be identified with 0.1, but
julia> wrap_time(1.9, t_init, t_end)
0.9999999999999998
```

With `extend_past_t_end = true`:

```jldoctest
julia> t_init = 0.1; t_end = 1.0; extend_past_t_end = true; dt = 0.1
julia> wrap_time(0.1, t_init, t_end; extend_past_t_end, dt)
0.1

julia> wrap_time(0.5, t_init, t_end; extend_past_t_end, dt)
0.5

julia> wrap_time(0.8, t_init, t_end; extend_past_t_end, dt)
0.8

julia> wrap_time(1.0, t_init, t_end; extend_past_t_end, dt)
1.0

julia> wrap_time(1.1, t_init, t_end; extend_past_t_end, dt)
0.1

julia> wrap_time(1.6, t_init, t_end; extend_past_t_end, dt)
0.6

julia> wrap_time(2.2, t_init, t_end; extend_past_t_end, dt)
0.2000000000000001
```
"""
function wrap_time(time, t_init, t_end; extend_past_t_end = false, dt = nothing)
    extend_past_t_end &&
        isnothing(dt) &&
        error("dt required with extend_past_t_end = true")
    if extend_past_t_end
        t_end = t_end + dt
        return wrap_time(time, t_init, t_end; extend_past_t_end = false)
    end
    period = t_end - t_init
    return t_init + mod(time - t_init, period)
end

end
