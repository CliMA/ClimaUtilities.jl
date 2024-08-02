module Utils

import Dates: DatePeriod, Date, DateTime, Year, Month, Week, Day, Second
import Dates: year, month, week, dayofweek, day

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
    wrap_time(time, t_init, t_end)

Return `time` assuming periodicity so that `t_init <= time < t_end`.

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
"""
function wrap_time(time, t_init, t_end)
    period = t_end - t_init
    return t_init + mod(time - t_init, period)
end

"""
    beginningofperiod(date::Date, period::DatePeriod)

Return the beginning of the `period` in `date`

For example, if `date` is 03/05/2022 and `period` is `Year`, return 01/01/2022 at 00:00. If
period is `Month`, return 01/05/2022 at 00:00.

Examples
========
```jldoctest
julia> using Dates
julia> beginningofperiod(Date(1993, 11, 19), Year(1))
1993-01-01T00:00:00

julia> beginningofperiod(Date(1993, 11, 19), Month(1))
1993-11-01T00:00:00

julia> beginningofperiod(Date(1993, 11, 19), Week(1))
1993-11-15T00:00:00

julia> beginningofperiod(Date(1993, 11, 19), Day(1))
1993-11-19T00:00:00
```
"""
function beginningofperiod(date::Union{Date, DateTime}, period::DatePeriod)
    if period isa Year
        return DateTime(year(date), 1, 1)
    elseif period isa Month
        return DateTime(year(date), month(date), 1, 0, 0)
    elseif period isa Week
        return DateTime(date - Day(dayofweek(date) - 1))
    elseif period isa Day
        return DateTime(Date(date))
    else
        error("Unsupported period type")
    end
end

"""
    endofperiod(date::Union{Date, DateTime}, period::DatePeriod)

Return the end of the `period` in `date`.

For example, if `date` is 03/05/2022 and `period` is `Year`, return 31/12/2022 at 23:59:59.
If period is `Month`, return 31/05/2022 at 23:59:59.

Examples
========

```jldoctest
julia> using Dates
julia> endofperiod(Date(1993, 11, 19), Year(1))
1993-12-31T23:59:59

julia> endofperiod(Date(1993, 11, 19), Month(1))
1993-11-30T23:59:59

julia> endofperiod(Date(1993, 11, 19), Week(1))
1993-11-21T23:59:59

julia> endofperiod(Date(1993, 11, 19), Day(1))
1993-11-19T23:59:59
```
"""
function endofperiod(date::Union{Date, DateTime}, period::DatePeriod)
    if period isa Year
        return DateTime(year(date), 12, 31, 23, 59, 59)
    elseif period isa Month
        if month(date) == 12
            return DateTime(year(date), 12, 31, 23, 59, 59)
        else
            return DateTime(year(date), month(date) + 1, 1) - Second(1)
        end
    elseif period isa Week
        return DateTime(
            year(date),
            month(date),
            day(date) + 7 - dayofweek(date),
            23,
            59,
            59,
        )
    elseif period isa Day
        return DateTime(year(date), month(date), day(date), 23, 59, 59)
    else
        error("Unsupported period type")
    end
end

"""
    bounding_dates(dates, target_date::Union{Date, DateTime}, period::DatePeriod)

Identify bounding dates within `dates` that share the same `period` as `target_date`.

An example will make clear what this function really does:

For example, if `dates` is 01/01/2022, 01/01/2023, 01/02/2023, 05/05/2023, 10/10/2024,
`target date` is 01/01/2023, and period is `Year`, the function returns 01/01/2023 and
05/05/2023. We obtained this by extracting the `Year` from `target_date` and finding the
largest and smallest dates with that year within `dates`.

This function is used by other functions that have to be aware of periods. For example,
`PeriodicCalendar` implements an extrapolation boundary condition that allows users to
repeat one year from a file that might contain several years (in this case, `dates` would be
all the available dates, `target_date` would be any date in the year to be simulated, and
period one year).

Examples
========


```jldoctest
julia> using Dates
julia> dates = [Date(1993, 8, 13),
                Date(1993, 8, 18),
                Date(1993, 11, 19),
                Date(1994, 1, 1),
                Date(1998, 1, 17),
                ]
julia> bounding_dates(dates, Date(1993, 1, 1), Year(1))
(DateTime("1993-08-13"), DateTime("1993-11-19T23:59:59"))

julia> bounding_dates(dates, Date(1993, 1, 1), Month(1))
(DateTime("1993-08-13"), DateTime("1993-08-18T23:59:59"))
```
"""
function bounding_dates(
    dates,
    target_date::Union{Date, DateTime},
    period::DatePeriod,
)
    period_start = beginningofperiod(target_date, period)
    period_end = endofperiod(target_date, period)
    dates_in_period = filter(date -> period_start <= date <= period_end, dates)
    # TODO: In theory, we could also support just having one date (for the purpose of
    # PeriodicCalendar). But it is a little annoying, so this is left for future work (if
    # needed)
    length(dates_in_period) >= 2 ||
        error("$(target_date) not in given dates for given period")
    return first(dates_in_period), last(dates_in_period)
end

end
