module TimeVaryingInputs0DExt

import Dates: DateTime

import ClimaCore
import ClimaCore: ClimaComms

import ClimaUtilities.Utils: searchsortednearest, wrap_time, isequispaced
import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod,
    AbstractTimeVaryingInput,
    NearestNeighbor,
    LinearInterpolation,
    LinearPeriodFillingInterpolation,
    Throw,
    Flat,
    PeriodicCalendar,
    extrapolation_bc
import ClimaUtilities.TimeManager: ITime, date

"""
    InterpolatingTimeVaryingInput0D

The constructor for InterpolatingTimeVaryingInput0D is not supposed to be used directly,
unless you know what you are doing.

`times` and `values` may have different types. `values` is either a vector with a single
value per time, which represents a time series for a single point, or a matrix of size
(number of points, number of times), which represents a time series for each point. If
`values` is a vector, the interpolated value is broadcast to every point of the destination
and if `values` is a matrix, the interpolated values are written element-wise into a
destination of matching length.

We assume `times` has been sorted to be strictly increasing in time. `times` can have
elements of type `ITime` or float.
"""
struct InterpolatingTimeVaryingInput0D{
    AA1 <: AbstractArray,
    AA2 <: AbstractArray,
    M <: AbstractInterpolationMethod,
    R <: Tuple,
} <: AbstractTimeVaryingInput
    # AA1 and AA2 could be different because of different FTs

    """Independent coordinate"""
    times::AA1

    """Variable"""
    vals::AA2

    """Interpolation method"""
    method::M

    """Range of times over which the interpolator is defined. range is always defined on the
    CPU. Used by the in() function."""
    range::R
end

const InterpolatingTimeVaryingMultiPoint =
    InterpolatingTimeVaryingInput0D{<:AbstractArray, <:AbstractMatrix}

function TimeVaryingInputs.TimeVaryingInput(
    times::AbstractArray,
    vals::AbstractVector;
    context = nothing,
    method::AbstractInterpolationMethod = LinearInterpolation(),
)
    ########### DEPRECATED ###############
    if !isnothing(context)
        Base.depwarn(
            "The keyword argument `context` is no longer required for TimeVaryingInputs. It will be removed.",
            :TimeVaryingInput,
        )
    end
    ########### DEPRECATED ###############

    _check_dims(times, vals)
    times = _validated_times(times, method)
    range = (times[begin], times[end])
    return InterpolatingTimeVaryingInput0D(
        copy(times),
        copy(vals),
        method,
        range,
    )
end

"""
    TimeVaryingInput(times, vals::AbstractMatrix, space; method = LinearInterpolation())

Construct a per-point time-varying input (`InterpolatingTimeVaryingMultiPoint`) from a
matrix of size (number of points, number of times) which represents one time series per
point of `space`.

`space` must be purely horizontal or have exactly one vertical level. Rows of `vals` must
follow the order of the points in `ClimaCore.Fields.field2array`. It is the caller's
responsibility to ensure that this is correct. `evaluate!` writes one value per point into
the destination.
"""
function TimeVaryingInputs.TimeVaryingInput(
    times::AbstractArray,
    vals::AbstractMatrix,
    space::ClimaCore.Spaces.AbstractSpace;
    method::AbstractInterpolationMethod = LinearInterpolation(),
)
    arr = ClimaCore.Fields.field2array(ClimaCore.Fields.zeros(space))
    # field2array returns a vector for purely horizontal spaces and a matrix
    # whose size is number of vertical levels by number of columns otherwise
    num_levels = ndims(arr) == 1 ? 1 : size(arr, 1)
    num_levels == 1 ||
        error("TimeVaryingInput needs a space with a single vertical level")
    _check_dims(times, vals)
    size(vals, 1) == length(arr) || error(
        "vals has $(size(vals, 1)) rows, but the space has $(length(arr)) points",
    )
    times = _validated_times(times, method)
    device_vals = ClimaComms.array_type(ClimaComms.device(space))(vals)
    return InterpolatingTimeVaryingInput0D(
        copy(times),
        device_vals,
        method,
        (times[begin], times[end]),
    )
end

"""
    _check_dims(times, vals)

Check that `times` and `vals` have compatible sizes along the time axis, which
is the last axis of `vals`.
"""
function _check_dims(times, vals::AbstractVector)
    length(times) == length(vals) ||
        error("times and vals have different lengths")
    return nothing
end

function _check_dims(times, vals::AbstractMatrix)
    length(times) == size(vals, 2) ||
        error("times and the last dimension of vals have different lengths")
    return nothing
end

"""
    _validated_times(times, method)

Check that `times` is sorted and compatible with `method`, promoting `ITime`s
to a common epoch and period when needed and return the validated times.
"""
function _validated_times(times, method)
    issorted(times, lt = <=) ||
        error("Can only interpolate with strictly increasing times")

    if method isa LinearPeriodFillingInterpolation
        error(
            "LinearPeriodFillingInterpolation is not supported when the input data is 1D",
        )
    end
    if eltype(times) <: ITime
        if !all(
            t ->
                t.period == first(times).period &&
                t.epoch == first(times).epoch,
            times,
        )
            # Promote if times do not all have same epoch and period to avoid
            # promoting during the simulation
            times = [promote(times...)...]
        elseif !(eltype(times) <: ITime{<:Any, <:Any, Nothing})
            all(d -> d.epoch == first(times).epoch, times) || error(
                "TimeVaryingInputs cannot be used when the data is defined at `ITime`(s) with differing epochs",
            )
        end
    end
    if extrapolation_bc(method) isa PeriodicCalendar{Nothing}
        if !isequispaced(eltype(times) <: ITime ? float.(times) : times)
            error(
                "PeriodicCalendar() boundary condition cannot be used because data is defined at non uniform intervals of time",
            )
        end
    elseif extrapolation_bc(method) isa PeriodicCalendar
        error(
            "PeriodicCalendar(period) is not supported when the input data is 1D",
        )
    end
    return times
end

"""
    in(time, itp::InterpolatingTimeVaryingInput0D)

Check if the given `time` is in the range of definition for `itp`.
"""
function Base.in(time, itp::InterpolatingTimeVaryingInput0D)
    return itp.range[1] <= time <= itp.range[2]
end

"""
    _normalize_time(itp::InterpolatingTimeVaryingInput0D, time)

Convert `time` to the time type used by `itp.times`.
"""
_normalize_time(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray{<:Number}},
    time::Number,
) = time
_normalize_time(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray{<:Number}},
    time::ITime,
) = eltype(itp.range)(float(time))
_normalize_time(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray{<:Number}},
    time::DateTime,
) = error(
    "Cannot evaluate InterpolatingTimeVaryingInput0D with times as numbers and inputs as DateTime",
)
_normalize_time(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray{<:ITime}},
    time::ITime,
) = time
_normalize_time(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray{<:ITime}},
    time::Number,
) = first(promote(ITime(time), itp.range[1]))
function _normalize_time(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray{<:ITime}},
    time::DateTime,
)
    epoch = date(itp.range[1])
    elapsed = time - epoch
    return ITime(elapsed.value; period = typeof(elapsed)(1), epoch)
end

# All stencil functions return (i1, i2, w), where w is the normalized distance
# from i1 toward i2, so that val = vals[i1] + (vals[i2] - vals[i1]) * w and
# w = 0 yields vals[i1] exactly.

"""
    _weight(time, t1, t2)

Normalized distance of `time` from `t1` toward `t2`.
"""
@inline _weight(time, t1, t2) = float(time - t1) / float(t2 - t1)

"""
    _zero_weight(time, times)

Zero of the weight type used for `time` and `times`.
"""
@inline function _zero_weight(time, times)
    FT = Base.promote_op(_weight, typeof(time), eltype(times), eltype(times))
    isconcretetype(FT) && return zero(FT)
    return zero(_weight(time, times[begin], times[end]))
end

"""
    _stencil(itp::InterpolatingTimeVaryingInput0D, time)

Return the appropriate stencil for `time` given `itp`.
"""
@inline function _stencil(itp::InterpolatingTimeVaryingInput0D, time)
    time in itp && return _interior_stencil(time, itp.times, itp.method)
    return _boundary_stencil(
        time,
        itp.times,
        extrapolation_bc(itp.method),
        itp.method,
    )
end

"""
    _interior_stencil(time, times, method)

Return the stencil for `time` within the range of `times`.

A `time` that falls exactly on a data point returns that point with zero weight.
"""
@inline function _interior_stencil(time, times, ::LinearInterpolation)
    id = searchsortedfirst(times, time)
    times[id] == time && return (id, id, _zero_weight(time, times))
    return (id - 1, id, _weight(time, times[id - 1], times[id]))
end

@inline function _interior_stencil(time, times, ::NearestNeighbor)
    id = searchsortednearest(times, time)
    return (id, id, _zero_weight(time, times))
end

"""
    _boundary_stencil(time, times, extrapolation_bc, method)

Return the stencil for `time` outside the range of `times` given the
`extrapolation_bc` and `method`.
"""
@inline function _boundary_stencil(time, times, ::Throw, method)
    return error("TimeVaryingInput does not cover time $time")
end

@inline function _boundary_stencil(time, times, ::Flat, method)
    left, right = firstindex(times), lastindex(times)
    w = _zero_weight(time, times)
    return time < times[left] ? (left, left, w) : (right, right, w)
end

@inline function _boundary_stencil(time, times, ::PeriodicCalendar, method)
    t_init, t_end = times[begin], times[end]
    dt = times[begin + 1] - times[begin]
    time = wrap_time(time, t_init, t_end + dt)
    time <= t_end && return _interior_stencil(time, times, method)
    return _gap_stencil(time, times, t_end, dt, method)
end

"""
    _gap_stencil(time, times, t_end, dt, method)

Return the stencil for a wrapped `time` in the gap `(t_end, t_end + dt)` between
the last and first data points of a periodic input.
"""
@inline function _gap_stencil(time, times, t_end, dt, ::LinearInterpolation)
    w = float(time - t_end) / float(dt)
    return (lastindex(times), firstindex(times), w)
end

@inline function _gap_stencil(time, times, t_end, dt, ::NearestNeighbor)
    w = _zero_weight(time, times)
    time >= t_end + 0.5dt && return (firstindex(times), firstindex(times), w)
    return (lastindex(times), lastindex(times), w)
end

"""
    _value_at_time_index(itp::InterpolatingTimeVaryingInput0D, index)

Value of `itp` at time index `index` where `index` refers to the time axis of
`vals` which is a number if `vals` is a vector or a column view if `vals` is a
matrix.
"""
@inline _value_at_time_index(
    itp::InterpolatingTimeVaryingInput0D{<:AbstractArray, <:AbstractVector},
    index,
) = itp.vals[index]
@inline _value_at_time_index(itp::InterpolatingTimeVaryingMultiPoint, index) =
    view(itp.vals, :, index)

"""
    evaluate!(dest, itp::InterpolatingTimeVaryingInput0D, time)

Write to `dest` the result of interpolating `itp` at the given `time`.
"""
function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput0D,
    time,
    args...;
    kwargs...,
)
    return _evaluate!(dest, itp, _normalize_time(itp, time))
end

"""
    evaluate!(dest::Fields.Field, itp::InterpolatingTimeVaryingMultiPoint, time)

Write to the `field2array` view of `dest` the result of interpolating `itp` at
the given `time`.
"""
function TimeVaryingInputs.evaluate!(
    dest::ClimaCore.Fields.Field,
    itp::InterpolatingTimeVaryingMultiPoint,
    time,
    args...;
    kwargs...,
)
    # field2array is either a 1 by number of columns matrix or a vector
    # We handle both cases by passing it to vec first
    return TimeVaryingInputs.evaluate!(
        vec(ClimaCore.Fields.field2array(dest)),
        itp,
        time,
        args...;
        kwargs...,
    )
end

# Function barrier because _normalize_time is type unstable when time is a
# `Number` and times are `ITime`s
function _evaluate!(dest, itp::InterpolatingTimeVaryingInput0D, time)
    (i1, i2, w) = _stencil(itp, time)
    y1 = _value_at_time_index(itp, i1)
    y2 = _value_at_time_index(itp, i2)
    @. dest = y1 + (y2 - y1) * w
    return nothing
end

end
