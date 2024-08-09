module TimeVaryingInputsExt

import Dates

import ClimaCore
import ClimaCore: ClimaComms
import ClimaCore: DeviceSideContext
import ClimaCore.Fields: Adapt

import ClimaUtilities.Utils:
    searchsortednearest,
    linear_interpolation,
    isequispaced,
    wrap_time,
    bounding_dates,
    endofperiod,
    period_to_seconds_float
import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, AbstractTimeVaryingInput
import ClimaUtilities.TimeVaryingInputs:
    NearestNeighbor, LinearInterpolation, Throw, Flat, PeriodicCalendar
import ClimaUtilities.TimeVaryingInputs: extrapolation_bc

import ClimaUtilities.DataHandling
import ClimaUtilities.DataHandling:
    DataHandler,
    previous_time,
    next_time,
    regridded_snapshot!,
    available_times,
    available_dates,
    date_to_time

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
    CC <: ClimaComms.AbstractCommsContext,
    R <: Tuple,
    RR,
} <: AbstractTimeVaryingInput
    """Object that has all the information on how to deal with files, data, and so on.
       Having to deal with files, it lives on the CPU."""
    data_handler::DH

    """Interpolation method"""
    method::M

    """ClimaComms context"""
    context::CC

    """Range of times over which the interpolator is defined. range is always defined on the
    CPU. Used by the in() function."""
    range::R

    """Preallocated memory for storing regridded fields"""
    preallocated_regridded_fields::RR
end

"""
    in(time, itp::InterpolatingTimeVaryingInput23D)

Check if the given `time` is in the range of definition for `itp`.
"""
function Base.in(time, itp::InterpolatingTimeVaryingInput23D)
    return itp.range[1] <= time <= itp.range[2]
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

    # TODO: Generalize the number of _regridded_fields depending on the interpolation
    # stencil
    preallocated_regridded_fields =
        (zeros(data_handler.target_space), zeros(data_handler.target_space))

    return InterpolatingTimeVaryingInput23D(
        data_handler,
        method,
        context,
        range,
        preallocated_regridded_fields,
    )
end

function TimeVaryingInputs.TimeVaryingInput(
    file_path::AbstractString,
    varname::AbstractString,
    target_space::ClimaCore.Spaces.AbstractSpace;
    method = LinearInterpolation(),
    reference_date::Dates.DateTime = Dates.DateTime(1979, 1, 1),
    t_start::AbstractFloat = 0.0,
    regridder_type = nothing,
    regridder_kwargs = (),
    file_reader_kwargs = (),
)
    data_handler = DataHandling.DataHandler(
        file_path,
        varname,
        target_space;
        reference_date,
        t_start,
        regridder_type,
        regridder_kwargs,
        file_reader_kwargs,
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

function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    args...;
    kwargs...,
)
    if extrapolation_bc(itp.method) isa Throw
        time in itp || error("TimeVaryingInput does not cover time $time")
    end
    if extrapolation_bc(itp.method) isa Flat
        t_init, t_end = itp.range
        if time >= t_end
            regridded_snapshot!(dest, itp.data_handler, t_end)
        else
            time <= t_init
            regridded_snapshot!(dest, itp.data_handler, t_init)
        end
    else
        TimeVaryingInputs.evaluate!(dest, itp, time, itp.method)
    end
    return nothing
end

function _time_range_dt_dt_e(itp::InterpolatingTimeVaryingInput23D)
    return _time_range_dt_dt_e(itp, extrapolation_bc(itp.method))
end

function _time_range_dt_dt_e(
    itp::InterpolatingTimeVaryingInput23D,
    extrapolation_bc::PeriodicCalendar{Nothing},
)
    isequispaced(DataHandling.available_times(itp.data_handler)) || error(
        "PeriodicCalendar() boundary condition cannot be used because data is defined at non uniform intervals of time",
    )     # Here for good measure
    dt = DataHandling.dt(itp.data_handler)
    return itp.range[begin], itp.range[end], dt, dt / 2
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

    t_init, t_end = date_to_time(itp.data_handler, date_init),
    date_to_time(itp.data_handler, date_end)
    # We have to add 1 Second because endofperiod(date_end, period) returns the very last
    # second before the next period
    dt_e =
        (endofperiod(date_end, period) + Dates.Second(1) - date_end) |>
        period_to_seconds_float
    dt = (date_init + period - date_end) |> period_to_seconds_float
    return t_init, t_end, dt, dt_e
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

function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    ::NearestNeighbor,
    args...;
    kwargs...,
)
    if extrapolation_bc(itp.method) isa PeriodicCalendar
        time, t_init, t_end, _, dt_e =
            _interpolation_times_periodic_calendar(time, itp)

        # Now time is between t_init and t_end + dt. We are doing nearest neighbor
        # interpolation here, and when time >= t_end + dt_e we need to use t_init instead of
        # t_end as neighbor.

        # TODO: It would be nice to handle this edge case directly instead of copying the
        # code
        if (time - t_end) <= dt_e
            regridded_snapshot!(dest, itp.data_handler, t_end)
        else
            regridded_snapshot!(dest, itp.data_handler, t_init)
        end
        return nothing
    end

    t0, t1 =
        previous_time(itp.data_handler, time), next_time(itp.data_handler, time)

    # The closest regridded_snapshot could be either the previous or the next one
    if (time - t0) <= (t1 - time)
        regridded_snapshot!(dest, itp.data_handler, t0)
    else
        regridded_snapshot!(dest, itp.data_handler, t1)
    end
    return nothing
end

function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    ::LinearInterpolation,
    args...;
    kwargs...,
)
    # Linear interpolation is:
    # y = y0 + (y1 - y0) * (time - t0) / (t1 - t0)
    #
    # Define coeff = (time - t0) / (t1 - t0)
    #
    # y = (1 - coeff) * y0 + coeff * y1

    if extrapolation_bc(itp.method) isa PeriodicCalendar
        time, t_init, t_end, dt, _ =
            _interpolation_times_periodic_calendar(time, itp)

        # We have to handle separately the edge case where the desired time is past t_end.
        # In this case, we know that t_end <= time <= t_end + dt and we have to do linear
        # interpolation between t_init and t_end. In this case, y0 = regridded_field(t_end),
        # y1 = regridded_field(t_init), t1 - t0 = dt, and time - t0 = time - t_end

        # TODO: It would be nice to handle this edge case directly instead of copying the
        # code
        if time > t_end
            field_t0, field_t1 = itp.preallocated_regridded_fields
            regridded_snapshot!(field_t0, itp.data_handler, t_end)
            regridded_snapshot!(field_t1, itp.data_handler, t_init)
            coeff = (time - t_end) / dt
            dest .= (1 - coeff) .* field_t0 .+ coeff .* field_t1
            return nothing
        end
    end

    # We have to consider the edge case where time is precisely the last available_time.
    # This is relevant also because it can be triggered by LinearPeriodFilling
    if time in DataHandling.available_times(itp.data_handler)
        regridded_snapshot!(dest, itp.data_handler, time)
    else
        t0, t1 = previous_time(itp.data_handler, time),
        next_time(itp.data_handler, time)
        coeff = (time - t0) / (t1 - t0)

        field_t0, field_t1 = itp.preallocated_regridded_fields
        regridded_snapshot!(field_t0, itp.data_handler, t0)
        regridded_snapshot!(field_t1, itp.data_handler, t1)

        dest .= (1 - coeff) .* field_t0 .+ coeff .* field_t1
    end
    return nothing
end

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
