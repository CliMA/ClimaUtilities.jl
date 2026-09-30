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

include("column_spaces.jl")

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
# Note that the values in `column_segment` are not necessarily unique, which
# allows for reusing the same forcing data for multiple columns.
#
# With this struct, it is not necessary to use the same times across all of the
# data for each column. However, this forces all the data to have the
# same z axis. This is accomplished by preprocessing the data by interpolating
# along the z direction for each column.

# To support this on GPU, each thread does a binary search along the time
# dimension. On CPU, the search is done once per column and reused for every
# level.
#
# At this point of time, there is no support for data that do not fit in memory.

"""
    RaggedInterpolatingTimeVaryingInput

A time varying input that supports time series of column data, each on its own
time axis, which are stored contiguously with offsets.

The times of each segment are `ITime`s, floats, or `DateTime`s. The data of
every segment are on the levels of the space. Data on other levels must be
interpolated first.
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

The keyword argument `column_segment` maps columns to segments: column `c` of
`space`, in the order of `ClimaCore.Fields.field2array`, reads segment
`column_segment[c]`, so several columns can share a segment. The keyword
argument `method` sets the interpolation in time. The keyword argument `epoch`
is the date at which the simulation time is zero. It is required when the times
are `DateTime`s, and must match the epoch of `ITime`s that have one.

With `PeriodicCalendar()`, every segment repeats over its own length.
"""
function TimeVaryingInputs.TimeVaryingInput(
    segment_times::AbstractVector{<:AbstractVector},
    segment_vals::AbstractVector{<:AbstractMatrix},
    space::ColumnSpace;
    column_segment::AbstractVector{<:Integer} = eachindex(segment_times),
    method::AbstractInterpolationMethod = LinearInterpolation(),
    epoch = nothing,
)
    length(segment_times) == length(segment_vals) || error(
        "segment_times and segment_vals have different lengths ($(length(segment_times)) and $(length(segment_vals)))",
    )
    # arr is a vector when there is no vertical component of the space
    arr = ClimaCore.Fields.field2array(ClimaCore.Fields.zeros(space))
    num_levels, num_columns = ndims(arr) == 1 ? (1, length(arr)) : size(arr)
    length(column_segment) == num_columns || error(
        "column_segment has $(length(column_segment)) entries, but the space has $num_columns columns. If column_segment is not passed in, there must be one segment per column",
    )
    all(in(eachindex(segment_times)), column_segment) ||
        error("column_segment refers to a segment that does not exist")
    for (s, (times, vals)) in enumerate(zip(segment_times, segment_vals))
        _check_dims(times, vals)
        size(vals, 1) == num_levels || error(
            "vals of segment $s has $(size(vals, 1)) rows, but the space has $num_levels levels",
        )
        length(times) >= 2 || error("Segment $s needs at least two times")
    end

    segment_times = _promote_times(segment_times, epoch)
    segment_times = [_validated_times(times, method) for times in segment_times]
    used_times = segment_times[unique(column_segment)]
    if extrapolation_bc(method) isa PeriodicCalendar{Nothing}
        spans =
            [t[end] - t[begin] + t[begin + 1] - t[begin] for t in used_times]
        all(isapprox(first(spans)), spans) ||
            @warn "Segments have different periods; PeriodicCalendar() repeats each one over its own length"
    end

    FT = ClimaCore.Spaces.undertype(space)
    AT = ClimaComms.array_type(ClimaComms.device(space))
    used_times = segment_times[unique(column_segment)]
    return RaggedInterpolatingTimeVaryingInput(
        AT(reduce(vcat, segment_times)),
        AT(cumsum([1; length.(segment_times)])),
        AT(Matrix{FT}(reduce(hcat, segment_vals))),
        AT(Vector{Int}(column_segment)),
        method,
        (maximum(first.(used_times)), minimum(last.(used_times))),
    )
end

"""
    _promote_times(segment_times, epoch)

Bring the times of all segments to one element type: `ITime`s are promoted to a
common period and to `epoch` when it is given, `DateTime`s become `ITime`s
counted from `epoch`, and numbers are promoted to a common type.
"""
function _promote_times(segment_times, epoch)
    if all(times -> eltype(times) <: ITime, segment_times)
        ref = reduce(first ∘ promote, Iterators.flatten(segment_times))
        # Check user supplied epoch match the epoch of the ITimes
        if !isnothing(epoch)
            isnothing(ref.epoch) ||
                ref.epoch == DateTime(epoch) ||
                error(
                    "epoch ($epoch) does not match the epoch of the times ($(ref.epoch))",
                )
            ref = ITime(ref.counter, ref.period, DateTime(epoch))
        end
        return [first.(promote.(times, Ref(ref))) for times in segment_times]
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
        isnothing(epoch) ||
            @warn "epoch is not used since the times are numbers"
        FT = promote_type(eltype.(segment_times)...)
        return [convert(Vector{FT}, times) for times in segment_times]
    end
    return error(
        "All segments must have times of one kind: ITime, number, or DateTime",
    )
end

"""
    in(time, itp::RaggedInterpolatingTimeVaryingInput)

Check if `time` is in the range covered by every segment that a column of `itp`
reads.
"""
function Base.in(time, itp::RaggedInterpolatingTimeVaryingInput)
    time = _normalize_time(itp.range, time)
    return itp.range[1] <= time <= itp.range[2]
end

"""
    evaluate!(dest::Fields.Field, itp::RaggedInterpolatingTimeVaryingInput, time)

Write to `dest` the result of interpolating every column of `itp` at the given
`time`. `dest` must have the levels and columns of the space `itp` was built
for.
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
    return _evaluate!(
        arr,
        itp,
        _normalize_time(itp.range, time),
        ClimaComms.device(axes(dest)),
    )
end

"""
    _evaluate!(arr, itp::RaggedInterpolatingTimeVaryingInput, time, device)

Interpolate the data in `itp` at the given `time` and write to `arr`.
"""
function _evaluate!(arr, itp::RaggedInterpolatingTimeVaryingInput, time, device)
    bc = extrapolation_bc(itp.method)
    if bc isa Throw
        if !(time in itp)
            offsets, times = Array(itp.offsets), Array(itp.times)
            column_segment = Array(itp.column_segment)
            column = findfirst(column_segment) do s
                !(times[offsets[s]] <= time <= times[offsets[s + 1] - 1])
            end
            error(
                "Column $column of TimeVaryingInput reads segment $(column_segment[column]), which does not cover time $time",
            )
        end
        # Throw() can't compile on GPU, so we use Flat() instead. Both should not
        # lead to different results since there is no extrapolation given the
        # check above
        bc = Flat()
    end
    _interpolate!(arr, itp, time, bc, device)
    return nothing
end

"""
    _interpolate!(arr, itp::RaggedInterpolatingTimeVaryingInput, time, bc, device)

Write to `arr` the value of `itp` at `time` on every level and column, using
`bc` outside the times of each column's segment.

On CPU, the stencil of each column is computed once and used for all of its
levels. On other devices, every level of every column is computed in its own
thread.
"""
function _interpolate!(arr, itp, time, bc, ::ClimaComms.AbstractCPUDevice)
    for c in axes(arr, 2)
        j1, j2, w = _segment_stencil(itp, itp.column_segment[c], time, bc)
        @inbounds for k in axes(arr, 1)
            y1, y2 = itp.vals[k, j1], itp.vals[k, j2]
            arr[k, c] = y1 + (y2 - y1) * w
        end
    end
    return nothing
end

function _interpolate!(arr, itp, time, bc, ::ClimaComms.AbstractDevice)
    arr .= _point.(Ref(itp), CartesianIndices(arr), time, Ref(bc))
    return nothing
end

"""
    _segment_stencil(itp::RaggedInterpolatingTimeVaryingInput, s, time, bc)

Return the stencil `(j1, j2, w)` of segment `s` of `itp` at `time`, where `j1`
and `j2` are columns of `itp.vals`, using `bc` outside the times of the segment.
"""
@inline function _segment_stencil(itp, s, time, bc)
    seg = itp.offsets[s]:(itp.offsets[s + 1] - 1)
    times = view(itp.times, seg)
    (i1, i2, w) =
        times[begin] <= time <= times[end] ?
        _interior_stencil(time, times, itp.method) :
        _boundary_stencil(time, times, bc, itp.method)
    return (seg[i1], seg[i2], w)
end

"""
    _point(itp::RaggedInterpolatingTimeVaryingInput, I::CartesianIndex, time, bc)

Value of `itp` at `time` on the level and column given by `I`, using `bc`
outside the times of the column's segment.
"""
@inline function _point(itp, I::CartesianIndex, time, bc)
    k, c = Tuple(I)
    j1, j2, w = _segment_stencil(itp, itp.column_segment[c], time, bc)
    y1, y2 = itp.vals[k, j1], itp.vals[k, j2]
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
    num_segments = length(itp.offsets) - 1
    1 <= s <= num_segments ||
        error("Segment $s does not exist; there are $num_segments segments")
    first_node, next_node = Array(itp.offsets[s:(s + 1)])
    return Array(itp.times[first_node:(next_node - 1)])
end

Base.close(::RaggedInterpolatingTimeVaryingInput) = nothing

end
