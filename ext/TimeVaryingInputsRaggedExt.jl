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
    PeriodicCalendar,
    extrapolation_bc
import ClimaUtilities.TimeManager: ITime
import ..TimeVaryingInputs0DExt: _check_dims, _validated_times, _normalize_time

"""
    InterpolatingTimeVaryingInputRagged

One time series per segment, each on its own time axis, stored contiguously
with CSR-style offsets. Every column of the destination reads the segment given
by `column_segment`, so several columns can share one segment.

As in `InterpolatingTimeVaryingInput0D`, `times` are `ITime`s or floats.
"""
struct InterpolatingTimeVaryingInputRagged{
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

# evaluate! captures the struct in a kernel, so its arrays must be adapted
Adapt.@adapt_structure InterpolatingTimeVaryingInputRagged

"""
    TimeVaryingInput(segment_times, segment_vals, space; column_segment, method, epoch)

Construct an input with one time series per segment for the columns of `space`.

`segment_times[s]` is a strictly increasing vector of `ITime`s, floats, or
`DateTime`s (all segments of one kind), and `segment_vals[s]` a matrix of size
(number of levels of `space`, number of times). Column `c` of
`ClimaCore.Fields.field2array` reads segment `column_segment[c]`, by default
segment `c`.

`ITime`s are promoted to a common period and epoch across segments. `DateTime`s
become `ITime`s counted from `epoch`, which is required in that case. With
`PeriodicCalendar()`, every segment repeats over its own length.
"""
function TimeVaryingInputs.TimeVaryingInput(
    segment_times::AbstractVector{<:AbstractVector},
    segment_vals::AbstractVector{<:AbstractMatrix},
    space::ClimaCore.Spaces.AbstractSpace;
    column_segment::AbstractVector{<:Integer} = eachindex(segment_times),
    method::AbstractInterpolationMethod = LinearInterpolation(),
    epoch = nothing,
)
    length(segment_times) == length(segment_vals) ||
        error("segment_times and segment_vals have different lengths")
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

    segment_times = _common_times(segment_times, epoch)
    segment_times = [_validated_times(times, method) for times in segment_times]
    if extrapolation_bc(method) isa PeriodicCalendar{Nothing}
        spans = [
            t[end] - t[begin] + t[begin + 1] - t[begin] for t in segment_times
        ]
        all(s -> isapprox(s, first(spans)), spans) ||
            @warn "Segments have different periods; PeriodicCalendar() repeats each one over its own length"
    end

    FT = ClimaCore.Spaces.undertype(space)
    AT = ClimaComms.array_type(ClimaComms.device(space))
    return InterpolatingTimeVaryingInputRagged(
        AT(reduce(vcat, segment_times)),
        AT(cumsum([1; length.(segment_times)])),
        AT(Matrix{FT}(reduce(hcat, segment_vals))),
        AT(Vector{Int}(column_segment)),
        method,
        (maximum(first.(segment_times)), minimum(last.(segment_times))),
    )
end

"""
    _common_times(segment_times, epoch)

Bring the times of all segments to one element type: `ITime`s are promoted to a
common period and epoch, `DateTime`s become `ITime`s counted from `epoch`, and
numbers are left as they are.
"""
function _common_times(segment_times, epoch)
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
    in(time, itp::InterpolatingTimeVaryingInputRagged)

Check if `time` is in the range covered by every segment of `itp`.
"""
function Base.in(time, itp::InterpolatingTimeVaryingInputRagged)
    time = _normalize_time(itp.range, time)
    return itp.range[1] <= time <= itp.range[2]
end

"""
    segment_times(itp::InterpolatingTimeVaryingInputRagged, s)

Return the times of segment `s` of `itp`.
"""
function TimeVaryingInputs.segment_times(
    itp::InterpolatingTimeVaryingInputRagged,
    s::Integer,
)
    offsets = Array(itp.offsets)
    return Array(itp.times[offsets[s]:(offsets[s + 1] - 1)])
end

Base.close(::InterpolatingTimeVaryingInputRagged) = nothing

end
