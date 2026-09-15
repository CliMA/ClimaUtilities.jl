module TimeVaryingInputsRaggedExt

import Dates
import Dates: DateTime

import ClimaCore
import ClimaCore: ClimaComms
import ClimaCore.Fields: Adapt

import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod,
    AbstractTimeVaryingInput,
    LinearInterpolation,
    Throw,
    Flat,
    PeriodicCalendar,
    extrapolation_bc
import ClimaUtilities.TimeManager: ITime
import ..TimeVaryingInputs0DExt:
    _check_dims,
    _validated_times,
    _normalize_time,
    _interior_stencil,
    _boundary_stencil

# The core requirement of the RaggedInterpolatingTimeVaryingInput is to
# support linear interpolation across time of time series data of multiple
# columns that may not necessarily share the same time axis. Furthermore, this
# computation should be done on GPU and potentially the data may not fit in
# memory.
#
# We store all the times in a vector and the time series data in a matrix by
# concatenation. In addition, we also store an offset vector to determine which
# data belong to which column. For example, consider two time series with times
# 0, 6, and 12 hours for the first one and times 0, 4, 8 and 12 hours for the
# second one. If we are interpolating to a point space with two points, this
# would look like
#
#     times          = [0, 6, 12, 0, 4, 8, 12]
#     offsets        = [1, 4, 8]
#     vals           = [a1 a2 a3 b1 b2 b3 b4]
#     column_segment = [1, 2]
#
# Note that the values in `column_segment` are not necessarily unique which
# allow for reusing the same forcing data for multiple columns.
#
# With this struct, it is not necessary to use the same times across all of the
# data for each of the column. However, this forces all the data to have the
# same z axis. This is accomplished by preprocessing the data by interpolating
# along the z direction for each column.

# To support this on GPU, each thread do a binary search along the time
# dimension.
#
# At this point of time, there is no support for data that do not fit in memory.

"""
    RaggedInterpolatingTimeVaryingInput

A time varying input that support time series data of column data, each on its
own time axis, which are stored contiguously with offsets.

As in `InterpolatingTimeVaryingInput0D`, `times` are `ITime`s, floats, or dates.
The time series data must be on the same z axis.
"""
struct RaggedInterpolatingTimeVaryingInput{
    AA1 <: AbstractVector,
    AA2 <: AbstractVector{Int},
    AA3 <: AbstractMatrix,
    AA4 <: AbstractVector{Int},
    M <: AbstractInterpolationMethod,
    R <: Tuple,
} <: AbstractTimeVaryingInput
    """Times of all segments; segment `s` is
    `times[offsets[s]:(offsets[s + 1] - 1)]`"""
    times::AA1

    """First node of each segment, followed by `length(times) + 1`"""
    offsets::AA2

    """Values on the levels of the space, one column per node"""
    vals::AA3

    """Segment read by each column of the destination"""
    column_segment::AA4

    """Interpolation method"""
    method::M

    """Intersection of the segments' ranges; always on the CPU, used by `in`"""
    range::R
end

Adapt.@adapt_structure RaggedInterpolatingTimeVaryingInput

"""
    TimeVaryingInput(segment_times, segment_vals, space; column_segment, method, epoch)

Construct an input with one time series per segment for the columns of `space`.

`segment_times[s]` is a strictly increasing vector of `ITime`s, floats, or
`DateTime`s (all segments of one kind), and `segment_vals[s]` a matrix of size
(number of levels of `space`, number of times).

With `PeriodicCalendar()`, every segment repeats over its own length.
"""
function TimeVaryingInputs.TimeVaryingInput(
    segment_times::AbstractVector{<:AbstractVector},
    segment_vals::AbstractVector{<:AbstractMatrix},
    space::ClimaCore.Spaces.AbstractSpace;
    column_segment::AbstractVector{<:Integer} = eachindex(segment_times),
    method::AbstractInterpolationMethod = LinearInterpolation(),
    epoch = nothing,
)
    length(segment_times) == length(segment_vals) || error(
        "segment_times ($segment_times) and segment_vals ($segment_vals) have different lengths",
    )
    # arr is a vector when there is no vertical component of the space
    arr = ClimaCore.Fields.field2array(ClimaCore.Fields.zeros(space))
    num_levels, num_columns = ndims(arr) == 1 ? (1, length(arr)) : size(arr)
    length(column_segment) == num_columns || error(
        "column_segment has $(length(column_segment)) entries, but the space has $num_columns columns",
    )
    all(in(eachindex(segment_times)), column_segment) ||
        error("column_segment refers to a segment that does not exist")
    for (times, vals) in zip(segment_times, segment_vals)
        _check_dims(times, vals)
        size(vals, 1) == num_levels || error(
            "vals has $(size(vals, 1)) rows, but the space has $num_levels levels",
        )
        length(times) >= 2 || error("Each segment needs at least two times")
    end

    segment_times = _promote_times(segment_times, epoch)
    segment_times = [_validated_times(times, method) for times in segment_times]
    if extrapolation_bc(method) isa PeriodicCalendar{Nothing}
        spans =
            [t[end] - t[begin] + t[begin + 1] - t[begin] for t in segment_times]
        all(s -> isapprox(s, first(spans)), spans) ||
            @warn "Segments have different periods; PeriodicCalendar() repeats each one over its own length"
    end

    FT = ClimaCore.Spaces.undertype(space)
    AT = ClimaComms.array_type(ClimaComms.device(space))
    return RaggedInterpolatingTimeVaryingInput(
        AT(reduce(vcat, segment_times)),
        AT(cumsum([1; length.(segment_times)])),
        AT(Matrix{FT}(reduce(hcat, segment_vals))),
        AT(Vector{Int}(column_segment)),
        method,
        (maximum(first.(segment_times)), minimum(last.(segment_times))),
    )
end

"""
    _promote_times(segment_times, epoch)

Bring the times of all segments to one element type: `ITime`s are promoted to a
common period and epoch, `DateTime`s become `ITime`s counted from `epoch`, and
numbers are left as they are.
"""
function _promote_times(segment_times, epoch)
    if all(times -> eltype(times) <: ITime, segment_times)
        ref = reduce(
            (t1, t2) -> first(promote(t1, t2)),
            Iterators.flatten(segment_times),
        )
        return [
            [first(promote(t, ref)) for t in times] for times in segment_times
        ]
    elseif all(times -> eltype(times) <: DateTime, segment_times)
        isnothing(epoch) &&
            error("epoch is required when times are given as DateTime")
        # Dates.Millisecond(9223372036569600000) |> Dates.Week gives
        # 15250284452 weeks, so using a period of Dates.Millisecond will not
        # lead to integer overflow
        to_itime(d) = ITime(
            Dates.value(d - DateTime(epoch));
            period = Dates.Millisecond(1),
            epoch,
        )
        return [to_itime.(times) for times in segment_times]
    elseif all(times -> eltype(times) <: Number, segment_times)
        return segment_times
    end
    return error(
        "All segments must have times of one kind: ITime, number, or DateTime",
    )
end

"""
    in(time, itp::RaggedInterpolatingTimeVaryingInput)

Check if `time` is in the range covered by every segment of `itp`.
"""
function Base.in(time, itp::RaggedInterpolatingTimeVaryingInput)
    time = _normalize_time(itp.range, time)
    return itp.range[1] <= time <= itp.range[2]
end

"""
    evaluate!(dest::Fields.Field, itp::RaggedInterpolatingTimeVaryingInput, time)

Write to `dest` the result of interpolating every column of `itp` at the given
`time`. `dest` must be on the space `itp` was built for.
"""
function TimeVaryingInputs.evaluate!(
    dest::ClimaCore.Fields.Field,
    itp::RaggedInterpolatingTimeVaryingInput,
    time,
    args...;
    kwargs...,
)
    arr = ClimaCore.Fields.field2array(dest)
    arr = ndims(arr) == 1 ? reshape(arr, 1, :) : arr
    size(arr) == (size(itp.vals, 1), length(itp.column_segment)) ||
        error("dest is not defined on the space the input was built for")
    return _evaluate!(arr, itp, _normalize_time(itp.range, time))
end

# Function barrier as in the 0D input. Throw is determined on the host because
# the kernel cannot raise the error of _boundary_stencil.
"""
    _evaluate!(arr, itp::RaggedInterpolatingTimeVaryingInput, time)

Interpolate the data in `intp` at the given `time` and write to `arr`.

This is a function barrier for `evaluate!`.
"""
function _evaluate!(arr, itp::RaggedInterpolatingTimeVaryingInput, time)
    bc = extrapolation_bc(itp.method)
    if bc isa Throw && !(time in itp)
        offsets, times = Array(itp.offsets), Array(itp.times)
        segment = findfirst(
            s -> !(times[offsets[s]] <= time <= times[offsets[s + 1] - 1]),
            1:(length(offsets) - 1),
        )
        error("Segment $segment of TimeVaryingInput does not cover time $time")
    end
    # Throw() can't compile on GPU, so we use Flat() instead
    # Both should not lead to different results since there is no extrapolation
    # given the check above
    bc = Flat()
    arr .= _point.(Ref(itp), CartesianIndices(arr), time, Ref(bc))
    return nothing
end

"""
    _point(itp::RaggedInterpolatingTimeVaryingInput, I::CartesianIndex, time, bc)

Value of `itp` at `time` on the level and column given by `I`, using `bc`
outside the times of the column's segment.
"""
@inline function _point(itp, I::CartesianIndex, time, bc)
    k, c = Tuple(I)
    s = itp.column_segment[c]
    seg = itp.offsets[s]:(itp.offsets[s + 1] - 1)
    times = view(itp.times, seg)
    (i1, i2, w) =
        times[begin] <= time <= times[end] ?
        _interior_stencil(time, times, itp.method) :
        _boundary_stencil(time, times, bc, itp.method)
    y1, y2 = itp.vals[k, seg[i1]], itp.vals[k, seg[i2]]
    return y1 + (y2 - y1) * w
end

"""
    segment_times(itp::RaggedInterpolatingTimeVaryingInput, s)

Return the times of segment `s` of `itp`.
"""
function TimeVaryingInputs.segment_times(
    itp::RaggedInterpolatingTimeVaryingInput,
    s::Integer,
)
    offsets = Array(itp.offsets)
    return Array(itp.times[offsets[s]:(offsets[s + 1] - 1)])
end

Base.close(::RaggedInterpolatingTimeVaryingInput) = nothing

end
