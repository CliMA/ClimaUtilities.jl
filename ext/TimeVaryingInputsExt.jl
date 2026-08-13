# Stencil-based implementation of the 2/3D TimeVaryingInputs: evaluation is organized as
# computing a stencil (two dates with available data and a weight) and applying it in one
# place, with the interpolation method and extrapolation condition only involved in the
# stencil computation.
module TimeVaryingInputsExt

import Dates
import Dates: DateTime

import ClimaCore
import ClimaCore: ClimaComms

import ClimaUtilities.Utils:
    isequispaced,
    wrap_time,
    bounding_dates,
    beginningofperiod,
    endofperiod,
    unique_periods

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

import ClimaUtilities.DataHandling
import ClimaUtilities.DataHandling:
    regridded_snapshot,
    regridded_snapshot!,
    available_dates,
    time_to_date,
    previous_date,
    next_date

import ClimaUtilities.TimeManager: ITime, date

struct AnalyticTimeVaryingInput{F <: Function} <:
       TimeVaryingInputs.AbstractTimeVaryingInput
    # func here has to be GPU-compatible (e.g., splines are not) and reasonably fast (e.g.,
    # no large allocations)
    func::F
end

# _kwargs... is needed to seamlessly support the other TimeVaryingInputs.
function TimeVaryingInputs.TimeVaryingInput(
    input::Function;
    method = nothing,
    _kwargs...,
)
    isnothing(method) ||
        @warn "Interpolation method is ignored for analytical functions"
    return AnalyticTimeVaryingInput(input)
end

function TimeVaryingInputs.evaluate!(
    dest,
    input::AnalyticTimeVaryingInput,
    time,
    args...;
    kwargs...,
)
    dest .= input.func(time, args...; kwargs...)
    return nothing
end

"""
    InterpolatingTimeVaryingInput23D

The constructor for InterpolatingTimeVaryingInput23D is not supposed to be used directly,
unless you know what you are doing. It is responsibility of the user-facing constructor
TimeVaryingInput() to perform checks and take care of GPU compatibility.
"""
struct InterpolatingTimeVaryingInput23D{
    DH,
    M <: AbstractInterpolationMethod,
    CC <: ClimaComms.AbstractCommsContext,
    R <: Tuple,
    RR,
    BI,
} <: AbstractTimeVaryingInput
    """Object that has all the information on how to deal with files, data, and so on.
    Having to deal with files, it lives on the CPU."""
    data_handler::DH

    """Interpolation method"""
    method::M

    """ClimaComms context"""
    context::CC

    """Range of times over which the interpolator is defined. range is always defined on
    the CPU."""
    range::R

    """Preallocated memory for storing regridded fields"""
    preallocated_regridded_fields::RR

    """Metadata computed once at construction and used by the interpolation stencils (e.g.,
    the dates that bound a repeat period). `nothing` when the method needs none."""
    bc_info::BI
end

"""
    _bc_info(data_handler, method)

Compute the interpolation metadata for `method` once, at construction time.
"""
_bc_info(data_handler, method::AbstractInterpolationMethod) =
    _bc_info(data_handler, extrapolation_bc(method))

_bc_info(data_handler, bc::Union{Throw, Flat}) = nothing

function _bc_info(data_handler, bc::PeriodicCalendar{Nothing})
    dt = DataHandling.dt(data_handler)
    return (;
        date_init = available_dates(data_handler)[begin],
        date_end = available_dates(data_handler)[end],
        dt = Dates.Millisecond(round(1_000 * dt)),
        dt_e = Dates.Millisecond(round((1_000 * dt) / 2)),
    )
end

function _bc_info(data_handler, bc::PeriodicCalendar)
    period, repeat_date = bc.period, bc.repeat_date
    date_init, date_end =
        bounding_dates(available_dates(data_handler), repeat_date, period)
    # dt is the gap between the end of the repeat period and its restart; dt_e is the gap
    # between the last date and the end of the repeat period (endofperiod returns the last
    # second before the next period, hence the extra second)
    dt_e = (endofperiod(date_end, period) + Dates.Second(1) - date_end)
    dt = (date_init + period - date_end)
    return (; date_init, date_end, dt, dt_e)
end

function TimeVaryingInputs.TimeVaryingInput(
    data_handler;
    method = LinearInterpolation(),
    context = ClimaComms.context(),
)
    available_times = DataHandling.available_times(data_handler)
    isempty(available_times) &&
        error("DataHandler does not contain temporal data")
    issorted(available_times) || error("Can only interpolate with sorted times")
    range = (available_times[begin], available_times[end])

    # LinearPeriodFilling needs two temporary fields to combine values across periods; the
    # other methods interpolate directly from the snapshots cached by the data handler
    _num_fields = method isa LinearPeriodFillingInterpolation ? 2 : 0
    preallocated_regridded_fields =
        ntuple(_ -> zeros(data_handler.target_space), _num_fields)

    return InterpolatingTimeVaryingInput23D(
        data_handler,
        method,
        context,
        range,
        preallocated_regridded_fields,
        _bc_info(data_handler, method),
    )
end

function TimeVaryingInputs.TimeVaryingInput(
    file_paths,
    varnames,
    target_space;
    method = LinearInterpolation(),
    start_date::Union{Dates.DateTime, Dates.Date} = Dates.DateTime(1979, 1, 1),
    regridder_type = nothing,
    regridder_kwargs = (),
    file_reader_kwargs = (),
    compose_function = identity,
    # DEPRECATED keyword arguments
    reference_date = nothing,
    t_start = nothing,
)
    if !isnothing(reference_date)
        start_date = reference_date
        Base.depwarn(
            "The keyword argument `reference_date` is deprecated. Use `start_date` instead.",
            :TimeVaryingInput,
        )
    end
    if !isnothing(t_start)
        Base.depwarn("`t_start` was removed will be ignored", :TimeVaryingInput)
    end

    # LinearPeriodFilling reads up to four distinct snapshots per evaluation, so the default
    # cache size of two would evict on every call
    cache_max_size = method isa LinearPeriodFillingInterpolation ? 4 : 2
    data_handler = DataHandling.DataHandler(
        file_paths,
        varnames,
        target_space;
        start_date,
        regridder_type,
        regridder_kwargs,
        file_reader_kwargs,
        compose_function,
        cache_max_size,
    )
    if extrapolation_bc(method) isa PeriodicCalendar{Nothing} &&
       !isequispaced(DataHandling.available_times(data_handler))
        error(
            "PeriodicCalendar() boundary condition cannot be used because data is defined at non uniform intervals of time",
        )
    end
    context = ClimaComms.context(target_space)
    return TimeVaryingInputs.TimeVaryingInput(data_handler; method, context)
end

"""
    in(time, itp::InterpolatingTimeVaryingInput23D)

Check if the given `time` is in the range of definition for `itp`.
"""
function Base.in(time, itp::InterpolatingTimeVaryingInput23D)
    return itp.data_handler.available_dates[begin] <=
           time <=
           itp.data_handler.available_dates[end]
end

function Base.in(time::Number, itp::InterpolatingTimeVaryingInput23D)
    return Base.in(time_to_date(itp.data_handler, time), itp)
end

"""
    evaluate!(dest, itp::InterpolatingTimeVaryingInput23D, time)

Write to `dest` the result of interpolating `itp` at the given `time`.
"""
function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    args...;
    kwargs...,
)
    _evaluate!(dest, itp, _normalize_time(itp, time))
    return nothing
end

"""
    _normalize_time(itp::InterpolatingTimeVaryingInput23D, time)

Convert `time` to the `DateTime` used internally for all interpolation logic.
"""
_normalize_time(itp::InterpolatingTimeVaryingInput23D, time::DateTime) = time
_normalize_time(itp::InterpolatingTimeVaryingInput23D, time::Number) =
    Dates.Millisecond(round(1_000 * time)) + itp.data_handler.start_date
_normalize_time(itp::InterpolatingTimeVaryingInput23D, time::ITime) = date(time)
_normalize_time(itp::InterpolatingTimeVaryingInput23D, time::Dates.Date) =
    DateTime(time)

function _evaluate!(dest, itp::InterpolatingTimeVaryingInput23D, time::DateTime)
    _evaluate!(dest, itp, time, itp.method)
    return nothing
end

# All stencil functions return (date0, date1, coeff), where date0 and date1 are dates with
# available data and coeff is the weight in
#   dest = (1 - coeff) * data(date0) + coeff * data(date1).
# A stencil with date0 == date1 means "copy the snapshot at date0": it is applied with a
# direct copy and no arithmetic, so NaNs and exact values pass through unchanged.

"""
    _apply_stencil!(dest, itp, date0, date1, coeff)

Write to `dest` the combination of the snapshots at `date0` and `date1` weighted by `coeff`.
"""
function _apply_stencil!(dest, itp, date0, date1, coeff)
    if date0 == date1
        regridded_snapshot!(dest, itp.data_handler, date0)
    else
        # The snapshots are read straight from the data handler cache, so the only
        # broadcast is the one that combines them; the weight is converted to the field
        # eltype so GPUs do not compute the broadcast in double precision
        field0 = regridded_snapshot(itp.data_handler, date0)
        field1 = regridded_snapshot(itp.data_handler, date1)
        weight = eltype(dest)(coeff)
        dest .= (1 - weight) .* field0 .+ weight .* field1
    end
    return nothing
end

function _evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time::DateTime,
    method::Union{NearestNeighbor, LinearInterpolation},
)
    date0, date1, coeff = _stencil(itp, time, method, extrapolation_bc(method))
    _apply_stencil!(dest, itp, date0, date1, coeff)
    return nothing
end

"""
    _stencil(itp, time, method, extrapolation_bc)

Return the stencil for `time` given the interpolation `method` and `extrapolation_bc`.
"""
function _stencil(itp, time, method, ::Throw)
    time in itp || error("TimeVaryingInput does not cover time $time")
    return _interior_stencil(itp, time, method)
end

function _stencil(itp, time, method, ::Flat)
    dates = available_dates(itp.data_handler)
    # The boundaries are checked with >= and <=, so evaluating exactly at a boundary copies
    # the boundary snapshot without going through the interior stencil
    time >= dates[end] && return (dates[end], dates[end], 0.0)
    time <= dates[begin] && return (dates[begin], dates[begin], 0.0)
    return _interior_stencil(itp, time, method)
end

# PeriodicCalendar applies to every time, not just out-of-range ones: with a period and a
# repeat_date it filters the data down to that period, so all times are wrapped before
# interpolating
function _stencil(itp, time, method::LinearInterpolation, ::PeriodicCalendar)
    (; date_init, date_end, dt) = itp.bc_info
    time = wrap_time(time, date_init, date_end + dt)
    # Wrapped times past date_end fall in the gap between the last and first data points
    time > date_end && return (date_end, date_init, (time - date_end) / dt)
    return _interior_stencil(itp, time, method)
end

function _stencil(itp, time, method::NearestNeighbor, ::PeriodicCalendar)
    (; date_init, date_end, dt, dt_e) = itp.bc_info
    time = wrap_time(time, date_init, date_end + dt)
    # Wrapped times in the gap past date_end are attributed to date_end up to dt_e away,
    # and to date_init (where the period restarts) beyond that
    if time > date_end
        (time - date_end) <= dt_e && return (date_end, date_end, 0.0)
        return (date_init, date_init, 0.0)
    end
    return _interior_stencil(itp, time, method)
end

"""
    _interior_stencil(itp, time, method)

Return the stencil for `time` within the range of the available dates.
"""
function _interior_stencil(itp, time, ::LinearInterpolation)
    # A time falling exactly on an available date copies that snapshot directly (this is
    # also triggered by LinearPeriodFilling)
    insorted(time, available_dates(itp.data_handler)) &&
        return (time, time, 0.0)
    date0 = previous_date(itp.data_handler, time)
    date1 = next_date(itp.data_handler, time)
    return (date0, date1, (time - date0) / (date1 - date0))
end

function _interior_stencil(itp, time, ::NearestNeighbor)
    # A time falling exactly on an available date (including the last one, which has no
    # next date) is its own nearest neighbor
    insorted(time, available_dates(itp.data_handler)) &&
        return (time, time, 0.0)
    date0 = previous_date(itp.data_handler, time)
    date1 = next_date(itp.data_handler, time)
    # The tie at the midpoint goes to the earlier date
    (time - date0) <= (date1 - time) && return (date0, date0, 0.0)
    return (date1, date1, 0.0)
end

include("time_varying_inputs_linearperiodfilling.jl")

"""
    close(time_varying_input::TimeVaryingInputs.AbstractTimeVaryingInput)

Close files associated to the `time_varying_input`.
"""
function Base.close(
    time_varying_input::TimeVaryingInputs.AbstractTimeVaryingInput,
)
    return nothing
end

"""
    close(time_varying_input::InterpolatingTimeVaryingInput23D)

Close files associated to the `time_varying_input`.
"""
function Base.close(time_varying_input::InterpolatingTimeVaryingInput23D)
    Base.close(time_varying_input.data_handler)
    return nothing
end

end
