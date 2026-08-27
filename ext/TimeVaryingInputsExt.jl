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
    regridded_snapshot, available_dates, previous_date, next_date

import ClimaUtilities.TimeManager: ITime, date

struct AnalyticTimeVaryingInput{F <: Function} <: AbstractTimeVaryingInput
    func::F
end

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

struct InterpolatingTimeVaryingInput23D{
    DH,
    M <: AbstractInterpolationMethod,
    RR,
} <: AbstractTimeVaryingInput
    data_handler::DH
    method::M
    preallocated_regridded_fields::RR
end

_to_date(itp, time) = time
_to_date(itp, time::ITime) = date(time)
_to_date(itp, time::Number) =
    Dates.Millisecond(round(1_000 * time)) + itp.data_handler.start_date

function Base.in(time, itp::InterpolatingTimeVaryingInput23D)
    dates = available_dates(itp.data_handler)
    return dates[begin] <= _to_date(itp, time) <= dates[end]
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
    preallocated_regridded_fields = ntuple(
        _ -> zeros(data_handler.target_space),
        method isa LinearPeriodFillingInterpolation ? 2 : 0,
    )
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
    _evaluate!(dest, itp, _to_date(itp, time), itp.method)
    return nothing
end

function _evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    method::Union{NearestNeighbor, LinearInterpolation},
)
    date0, date1, w = _stencil(itp, time, method)
    if date0 == date1
        dest .= regridded_snapshot(itp.data_handler, date0)
    else
        field0 = regridded_snapshot(itp.data_handler, date0)
        field1 = regridded_snapshot(itp.data_handler, date1)
        dest .= field0 .+ (field1 .- field0) .* w
    end
    return nothing
end

function _stencil(itp::InterpolatingTimeVaryingInput23D, time, method)
    bc = extrapolation_bc(method)
    if bc isa PeriodicCalendar
        date_init, date_end, dt, dt_e = _period_bounds(itp.data_handler, bc)
        time = wrap_time(time, date_init, date_end + dt)
        time > date_end &&
            return _gap_stencil(time, date_init, date_end, dt, dt_e, method)
    elseif !(time in itp)
        return _boundary_stencil(time, itp.data_handler, bc)
    end
    return _interior_stencil(time, itp.data_handler, method)
end

function _interior_stencil(time, data_handler, method)
    date0 = previous_date(data_handler, time)
    date0 == time && return (date0, date0, 0.0)
    return _bracket_stencil(time, date0, next_date(data_handler, time), method)
end

_bracket_stencil(time, date0, date1, ::LinearInterpolation) =
    (date0, date1, (time - date0) / (date1 - date0))
_bracket_stencil(time, date0, date1, ::NearestNeighbor) =
    (time - date0) <= (date1 - time) ? (date0, date0, 0.0) : (date1, date1, 0.0)

_boundary_stencil(time, data_handler, ::Throw) =
    error("TimeVaryingInput does not cover time $time")

function _boundary_stencil(time, data_handler, ::Flat)
    dates = available_dates(data_handler)
    date = clamp(time, dates[begin], dates[end])
    return (date, date, 0.0)
end

function _period_bounds(data_handler, ::PeriodicCalendar{Nothing})
    dates = available_dates(data_handler)
    dt = dates[begin + 1] - dates[begin]
    dt_e = Dates.Millisecond(round(Int, Dates.value(dt) / 2))
    return dates[begin], dates[end], dt, dt_e
end

function _period_bounds(data_handler, bc::PeriodicCalendar)
    date_init, date_end =
        bounding_dates(available_dates(data_handler), bc.repeat_date, bc.period)
    dt = date_init + bc.period - date_end
    dt_e = endofperiod(date_end, bc.period) + Dates.Second(1) - date_end
    return date_init, date_end, dt, dt_e
end

_gap_stencil(time, date_init, date_end, dt, dt_e, ::LinearInterpolation) =
    (date_end, date_init, (time - date_end) / dt)
_gap_stencil(time, date_init, date_end, dt, dt_e, ::NearestNeighbor) =
    (time - date_end) <= dt_e ? (date_end, date_end, 0.0) :
    (date_init, date_init, 0.0)

include("time_varying_inputs_linearperiodfilling.jl")

function Base.close(time_varying_input::AbstractTimeVaryingInput)
    return nothing
end

function Base.close(time_varying_input::InterpolatingTimeVaryingInput23D)
    Base.close(time_varying_input.data_handler)
    return nothing
end

end
