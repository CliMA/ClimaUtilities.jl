module TimeVaryingInputsExt

import Dates

import ClimaUtilities.Utils:
    isequispaced,
    wrap_time,
    bounding_dates,
    beginningofperiod,
    endofperiod,
    unique_periods

import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, AbstractTimeVaryingInput
import ClimaUtilities.TimeVaryingInputs:
    NearestNeighbor,
    LinearInterpolation,
    LinearPeriodFillingInterpolation,
    Throw,
    Flat,
    PeriodicCalendar
import ClimaUtilities.TimeVaryingInputs: extrapolation_bc

import ClimaUtilities.DataHandling
import ClimaUtilities.DataHandling:
    regridded_snapshot, available_dates, time_to_date, previous_date, next_date


import ClimaUtilities.TimeManager: ITime, date

# Ideally, we should be able to split off the analytic part in a different
# extension, but precompilation stops working when we do so

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

The constructor for InterpolatingTimeVaryingInput23D is not supposed to be used directly, unless you
know what you are doing. The constructor does not perform any check and does not take care of
GPU compatibility. It is responsibility of the user-facing constructor TimeVaryingInput() to do so.
"""
struct InterpolatingTimeVaryingInput23D{
    DH,
    M <: AbstractInterpolationMethod,
    RR,
} <: AbstractTimeVaryingInput
    """Object that has all the information on how to deal with files, data, and so on.
       Having to deal with files, it lives on the CPU."""
    data_handler::DH

    """Interpolation method"""
    method::M

    """Preallocated memory used by LinearPeriodFillingInterpolation"""
    preallocated_regridded_fields::RR
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


function TimeVaryingInputs.TimeVaryingInput(
    data_handler;
    method = LinearInterpolation(),
    context = nothing,
)
    available_times = DataHandling.available_times(data_handler)
    isempty(available_times) &&
        error("DataHandler does not contain temporal data")
    issorted(available_times) || error("Can only interpolate with sorted times")
    if extrapolation_bc(method) isa PeriodicCalendar{Nothing} &&
       !isequispaced(available_times)
        error(
            "PeriodicCalendar() boundary condition cannot be used because data is defined at non uniform intervals of time",
        )
    end

    # LinearPeriodFillingInterpolation needs one field for each level of nesting
    _num_fields = method isa LinearPeriodFillingInterpolation ? 2 : 0
    preallocated_regridded_fields =
        ntuple(_ -> zeros(data_handler.target_space), _num_fields)

    return InterpolatingTimeVaryingInput23D(
        data_handler,
        method,
        preallocated_regridded_fields,
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
    ########### DEPRECATED ###############
    reference_date = nothing,
    t_start = nothing,
    ########### DEPRECATED ###############
)
    ########### DEPRECATED ###############
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
    ########### DEPRECATED ###############

    data_handler = DataHandling.DataHandler(
        file_paths,
        varnames,
        target_space;
        start_date,
        regridder_type,
        regridder_kwargs,
        file_reader_kwargs,
        compose_function,
    )
    return TimeVaryingInputs.TimeVaryingInput(data_handler; method)
end

function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    args...;
    kwargs...,
)
    _evaluate!(dest, itp, _normalize_time(itp, time), itp.method)
    return nothing
end

"""
    _normalize_time(itp::InterpolatingTimeVaryingInput23D, time)

Convert `time` to a date. A number is the number of seconds since the start date.
"""
_normalize_time(itp, time) = time
_normalize_time(itp, time::Number) =
    Dates.Millisecond(round(1_000 * time)) + itp.data_handler.start_date
_normalize_time(itp, time::ITime) = date(time)

function _time_range_dt_dt_e(itp::InterpolatingTimeVaryingInput23D)
    return _time_range_dt_dt_e(itp, extrapolation_bc(itp.method))
end

function _time_range_dt_dt_e(
    itp::InterpolatingTimeVaryingInput23D,
    extrapolation_bc::PeriodicCalendar{Nothing},
)
    # DataHandling.dt would check again that the times are equispaced, which is slow
    times = DataHandling.available_times(itp.data_handler)
    dt = times[begin + 1] - times[begin]
    return itp.data_handler.available_dates[begin],
    itp.data_handler.available_dates[end],
    Dates.Millisecond(round(1_000 * dt)),
    Dates.Millisecond(round((1_000 * dt) / 2))
end

function _time_range_dt_dt_e(
    itp::InterpolatingTimeVaryingInput23D,
    extrapolation_bc::PeriodicCalendar,
)
    period, repeat_date = extrapolation_bc.period, extrapolation_bc.repeat_date

    date_init, date_end =
        bounding_dates(available_dates(itp.data_handler), repeat_date, period)
    # Suppose date_init date_end are 15/01/23 and 14/12/23
    # dt_e is endofperiod(14/12/23) - 14/12/23
    # dt is 15/01/23 + period - 14/12/23
    # if period = 1 Year, dt_e = 17 days (in seconds)

    # We have to add 1 Second because endofperiod(date_end, period) returns the very last
    # second before the next period
    dt_e = (endofperiod(date_end, period) + Dates.Second(1) - date_end)
    dt = (date_init + period - date_end)
    return date_init, date_end, dt, dt_e
end

"""
    _interpolation_times_periodic_calendar(time, itp::InterpolatingTimeVaryingInput23D)

Return time, t_init, t_end, dt, dt_e.

Implementation details
======================

Okay, how are we implementing PeriodicCalendar?

There are two modes, one with provided `period` and `repeat_date`, and the other without.
When it comes to implementation, we reduce the first case to the second one. So, let's start
by looking at the second case, then, we will look at how we reduce it to the first one.

In the second case, we have `t_init`, `t_end`, and a `dt`. `t_init`, `t_end` define the earliest and
latest data we are going to use and are in units of simulation time. `dt` is so that `t_init =
t_end + dt`. We are also given a `dt_e` so that, for interpolation purposes, we attribute
points that are within `t_end + dt_e` to `t_end`, and points that are beyond that to `t_init`. For
equispaced timeseries, `dt_e = 0.5dt`.

Once we have all of this, we can wrap the given time to be within `t_init` and `t_end + dt`. For
all the cases where the wrapped time is between `t_init` and `t_end`, the function can use the
standard interpolation scheme, so, the only case we have to worry about is when the wrapped
time is between `t_end` and `t_end + dt`. We handle this case manually by working explicitly
with `dt_e`.

Now, let us reduce the case where we are given dates and a period.

Let us look at an example, suppose we have data defined at these dates

16/12/22, 15/01/23 ...,  14/12/23, 13/12/24

and we want to repeat the year 2023. period will be `Dates.Year` and `repeat_date` will be
01/01/2023 (or any date in the year 2023)

First, we identify the bounding dates that correspond to the given period that has to be
repeated. We can assume that dates are sorted. In this case, this will be 15/01/23 and
14/12/23. Then, we translate this into simulation time and compute `dt` and `dt_e`. That's it!
"""
function _interpolation_times_periodic_calendar(
    time,
    itp::InterpolatingTimeVaryingInput23D,
)
    t_init, t_end, dt, dt_e = _time_range_dt_dt_e(itp)
    time = wrap_time(time, t_init, t_end + dt)
    return time, t_init, t_end, dt, dt_e
end

# All stencil functions return (date1, date2, w), so that the interpolated value is
# (1 - w) * y1 + w * y2, where y1 and y2 are the snapshots at date1 and date2

"""
    _evaluate!(dest, itp::InterpolatingTimeVaryingInput23D, time, method)

Write to `dest` the value of `itp` at `time` interpolated with `method`.
"""
function _evaluate!(dest, itp, time, method)
    date1, date2, w = _stencil(itp, time, method, extrapolation_bc(method))
    y1 = regridded_snapshot(itp.data_handler, date1)
    if date1 == date2
        dest .= y1
    else
        y2 = regridded_snapshot(itp.data_handler, date2)
        dest .= (1 - w) .* y1 .+ w .* y2
    end
    return nothing
end

"""
    _stencil(itp::InterpolatingTimeVaryingInput23D, time, method, extrapolation_bc)

Return the stencil for `time` given `method` and its `extrapolation_bc`.
"""
function _stencil(itp, time, method, bc)
    time in itp && return _interior_stencil(itp, time, method)
    return _boundary_stencil(itp, time, bc)
end

function _stencil(itp, time, method, ::PeriodicCalendar)
    time, t_init, t_end, dt, dt_e =
        _interpolation_times_periodic_calendar(time, itp)
    time <= t_end && return _interior_stencil(itp, time, method)
    return _gap_stencil(time, t_init, t_end, dt, dt_e, method)
end

"""
    _interior_stencil(itp::InterpolatingTimeVaryingInput23D, time, method)

Return the stencil for `time` within the range of the available dates.
"""
function _interior_stencil(itp, time, ::LinearInterpolation)
    date1 = previous_date(itp.data_handler, time)
    date1 == time && return (date1, date1, 0.0)
    date2 = next_date(itp.data_handler, time)
    return (date1, date2, (time - date1) / (date2 - date1))
end

function _interior_stencil(itp, time, ::NearestNeighbor)
    date1 = previous_date(itp.data_handler, time)
    date1 == time && return (date1, date1, 0.0)
    date2 = next_date(itp.data_handler, time)
    nearest = time - date1 <= date2 - time ? date1 : date2
    return (nearest, nearest, 0.0)
end

"""
    _boundary_stencil(itp::InterpolatingTimeVaryingInput23D, time, extrapolation_bc)

Return the stencil for `time` outside the range of the available dates.
"""
function _boundary_stencil(itp, time, ::Throw)
    return error("TimeVaryingInput does not cover time $time")
end

function _boundary_stencil(itp, time, ::Flat)
    dates = available_dates(itp.data_handler)
    boundary_date = clamp(time, dates[begin], dates[end])
    return (boundary_date, boundary_date, 0.0)
end

"""
    _gap_stencil(time, t_init, t_end, dt, dt_e, method)

Return the stencil for `time` between `t_end` and `t_end + dt`, which is `t_init` repeated.
"""
function _gap_stencil(time, t_init, t_end, dt, dt_e, ::LinearInterpolation)
    return (t_end, t_init, (time - t_end) / dt)
end

function _gap_stencil(time, t_init, t_end, dt, dt_e, ::NearestNeighbor)
    nearest = time - t_end <= dt_e ? t_end : t_init
    return (nearest, nearest, 0.0)
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
