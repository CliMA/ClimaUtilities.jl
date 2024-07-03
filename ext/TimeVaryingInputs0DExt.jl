module TimeVaryingInputs0DExt

import ClimaCore
import ClimaCore: ClimaComms
import ClimaCore: DeviceSideContext
import ClimaCore.Fields: Adapt

import ClimaUtilities.Utils:
    searchsortednearest, linear_interpolation, wrap_time, isequispaced
import ClimaUtilities.TimeVaryingInputs:
    AbstractInterpolationMethod, AbstractTimeVaryingInput
import ClimaUtilities.TimeVaryingInputs:
    NearestNeighbor, LinearInterpolation, Throw, Flat, PeriodicCalendar
import ClimaUtilities.TimeVaryingInputs: extrapolation_bc

import ClimaUtilities.TimeVaryingInputs

"""
    InterpolatingTimeVaryingInput0D

The constructor for InterpolatingTimeVaryingInput0D is not supposed to be used directly, unless you
know what you are doing. The constructor does not perform any check and does not take care of
GPU compatibility. It is responsibility of the user-facing constructor TimeVaryingInput() to do so.

`times` and `vales` may have different float types, but they must be the same length, and we
assume that they have been sorted to be monotonically increasing in time, without repeated
values for the same timestamp.
"""
struct InterpolatingTimeVaryingInput0D{
    AA1 <: AbstractArray,
    AA2 <: AbstractArray,
    M <: AbstractInterpolationMethod,
    CC <: ClimaComms.AbstractCommsContext,
    R <: Tuple,
} <: AbstractTimeVaryingInput
    # AA1 and AA2 could be different because of different FTs

    """Independent coordinate"""
    times::AA1

    """Variable"""
    vals::AA2

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
function Base.in(time, itp::InterpolatingTimeVaryingInput0D)
    return itp.range[1] <= time <= itp.range[2]
end


# GPU compatibility
function Adapt.adapt_structure(to, itp::InterpolatingTimeVaryingInput0D)
    times = Adapt.adapt_structure(to, itp.times)
    vals = Adapt.adapt_structure(to, itp.vals)
    method = Adapt.adapt_structure(to, itp.method)
    range = Adapt.adapt_structure(to, itp.range)
    # On a GPU, we have a "ClimaCore.DeviceSideContext"
    InterpolatingTimeVaryingInput0D(
        times,
        vals,
        method,
        DeviceSideContext(),
        range,
    )
end

function TimeVaryingInputs.evaluate!(
    destination,
    itp::InterpolatingTimeVaryingInput0D,
    time,
    args...;
    kwargs...,
)
    if extrapolation_bc(itp.method) isa Throw
        time in itp || error("TimeVaryingInput does not cover time $time")
    end
    TimeVaryingInputs.evaluate!(
        ClimaComms.device(itp.context),
        parent(destination),
        itp,
        time,
        itp.method,
    )

    return nothing
end

function TimeVaryingInputs.evaluate!(
    device::ClimaComms.AbstractCPUDevice,
    destination,
    itp::InterpolatingTimeVaryingInput0D,
    time,
    args...;
    kwargs...,
)
    TimeVaryingInputs.evaluate!(parent(destination), itp, time, itp.method)
    return nothing
end

function TimeVaryingInputs.TimeVaryingInput(
    times::AbstractArray,
    vals::AbstractArray;
    method = LinearInterpolation(),
    context = ClimaComms.context(),
)
    issorted(times) || error("Can only interpolate with sorted times")
    length(times) == length(vals) ||
        error("times and vals have different lengths")

    if extrapolation_bc(method) isa PeriodicCalendar && !isequispaced(times)
        error(
            "PeriodicCalendar() boundary condition cannot be used because data is defined at non uniform intervals of time",
        )
    end

    # When device is CUDADevice, ArrayType will be a CUDADevice, so that times and vals get
    # copied to the GPU.
    ArrayType = ClimaComms.array_type(ClimaComms.device(context))

    range = (times[begin], times[end])
    return InterpolatingTimeVaryingInput0D(
        ArrayType(times),
        ArrayType(vals),
        method,
        context,
        range,
    )
end

function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput0D,
    time,
    ::NearestNeighbor,
)
    # Nearest neighbor interpolation: just pick the values corresponding to the entry in
    # itp.times that is closest to the given time.
    if extrapolation_bc(itp.method) isa Flat
        t_init, t_end = itp.range
        if time >= t_end
            dest .= itp.vals[end]
        else
            time <= t_init
            dest .= itp.vals[begin]
        end
        return nothing
    elseif extrapolation_bc(itp.method) isa PeriodicCalendar
        t_init, t_end = itp.range
        dt = itp.times[begin + 1] - itp.times[begin]
        time = wrap_time(time, t_init, t_end; extend_past_t_end = true, dt)
        # Now time is between t_init and t_end + dt. We are doing nearest neighbor
        # interpolation here, and when time >= t_end + 0.5dt we need to use t_init instead
        # of t_end as neighbor.
        time >= t_end + 0.5dt && (time = t_init)
    end

    index = searchsortednearest(itp.times, time)

    dest .= itp.vals[index]

    return nothing
end

"""
    evaluate!(
        dest,
        itp::InterpolatingTimeVaryingInput0D,
        time,
        ::LinearInterpolation,
        )

Write to `dest` the result of a linear interpolation of `itp` on the given `time`.
"""
function TimeVaryingInputs.evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput0D,
    time,
    ::LinearInterpolation,
)
    if extrapolation_bc(itp.method) isa Flat
        t_init, t_end = itp.range
        if time >= t_end
            dest .= itp.vals[end]
        else
            time <= t_init
            dest .= itp.vals[begin]
        end
        return nothing
    elseif extrapolation_bc(itp.method) isa PeriodicCalendar
        t_init, t_end = itp.range
        dt = itp.times[begin + 1] - itp.times[begin]
        time = wrap_time(time, t_init, t_end; extend_past_t_end = true, dt)
        # We have to handle separately the edge case where the desired time is past t_end.
        # In this case, we know that t_end <= time <= t_end + dt and we have to do linear
        # interpolation between t_init and t_end. In this case, y0 = vals[end], y1 =
        # vals[begin], t1 - t0 = dt, and time - t0 = time - t_end
        if time > t_end
            @. dest =
                itp.vals[end] +
                (itp.vals[begin] - itp.vals[end]) / dt * (time - t_end)
            return nothing
        end
    end

    indep_vars = itp.times
    indep_value = time
    dep_vars = itp.vals
    dest .= linear_interpolation(indep_vars, dep_vars, indep_value)
    return nothing
end
end
