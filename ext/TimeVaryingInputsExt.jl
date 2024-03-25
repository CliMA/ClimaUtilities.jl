module TimeVaryingInputsExt

import Dates

import ClimaCore
import ClimaCore: ClimaComms
import ClimaCore: DeviceSideContext
import ClimaCore.Fields: Adapt, CUDA

import ClimaUtilities.Utils: searchsortednearest, linear_interpolation
import ClimaUtilities.TimeVaryingInputs
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, AbstractTimeVaryingInput
import ClimaUtilities.TimeVaryingInputs: NearestNeighbor, LinearInterpolation

import ClimaUtilities.DataHandling
import ClimaUtilities.DataHandling:
    DataHandler, previous_time, next_time, regridded_snapshot, available_times

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
    return InterpolatingTimeVaryingInput23D(
        data_handler,
        method,
        context,
        range,
    )
end

function TimeVaryingInputs.TimeVaryingInput(
    file_path::AbstractString,
    varname::AbstractString,
    target_space::ClimaCore.Spaces.AbstractSpace;
    method = LinearInterpolation(),
    reference_date::Dates.DateTime = Dates.DateTime(1979, 1, 1),
    t_start::AbstractFloat = 0.0,
    regridder_type = :TempestRegridder,
)
    data_handler = DataHandling.DataHandler(
        file_path,
        varname,
        target_space;
        reference_date,
        t_start,
        regridder_type,
    )
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
    time in itp || error("TimeVaryingInput does not cover time $time")
    TimeVaryingInputs.evaluate!(dest, itp, time, itp.method)
    return nothing
end

function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    ::NearestNeighbor,
    args...;
    kwargs...,
)
    t0, t1 =
        previous_time(itp.data_handler, time), next_time(itp.data_handler, time)

    # The closest regridded_snapshot could be either the previous or the next one
    if (time - t0) <= (t1 - time)
        dest .= regridded_snapshot(itp.data_handler, t0)
    else
        dest .= regridded_snapshot(itp.data_handler, t1)
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

    t0, t1 =
        previous_time(itp.data_handler, time), next_time(itp.data_handler, time)
    coeff = (time - t0) / (t1 - t0)
    dest .=
        (1 - coeff) .* regridded_snapshot(itp.data_handler, t0) .+
        coeff .* regridded_snapshot(itp.data_handler, t1)
    return nothing
end

end
