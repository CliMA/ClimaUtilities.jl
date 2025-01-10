export ITime, counter, period, epoch, date, seconds

# ITime needs to support ratios too because the timestepper deals with stages,
# which are fractions of a basic unit.
const IntegerOrRatio = Union{Integer, Rational}

"""
    ITime ("Integer Time")

`ITime` is an integer (quantized) time.

`ITime` can be thought of as counting clock cycles (`counter`), with each tick
having a fixed duration (`period`).

Another way to think about this is that this is time with units.

`ITime` can also represent fractions of a cycle. It is recommended to stick with
integer times as much as possible. Fractions of a cycle cannot be converted to
dates.

This type is currently using Dates, but one of the design goals is to try to be
as agnostic as possible with respect to this so that in the future in will be
possible to use a different calendar.

When using Dates, the minimum unit of time that can be represented is 1
nanosecond. The maximum unit of time is determined by the maximum integer number
that can be represented.

Overflow occurs at `68 year * (1 Second / dt)` for Int32 and `300 gigayear * (1
Second / dt)` for Int64.

# Fields
- `counter::INT`: The number of clock cycles.
- `period::DT`: The duration of each cycle.
- `epoch::EPOCH`: An optional start date.
"""
struct ITime{
    INT <: IntegerOrRatio,
    DT,
    EPOCH <: Union{Nothing, Dates.DateTime},
}
    counter::INT
    period::DT
    epoch::EPOCH

    function ITime(counter, period, epoch)
        if counter isa Rational && counter.den == 1
            return new{typeof(counter.num), typeof(period), typeof(epoch)}(
                counter.num,
                period,
                epoch,
            )
        else
            return new{typeof(counter), typeof(period), typeof(epoch)}(
                counter,
                period,
                epoch,
            )
        end
    end
end

"""
    ITime(counter::IntegerOrRatio; period::Dates.FixedPeriod = Dates.Second(1), epoch = nothing)

Construct an `ITime` from a counter, a period, and an optional start date.

If the `epoch` is provided as a `Date`, it is converted to a `DateTime`.
"""
function ITime(
    counter::IntegerOrRatio;
    period::Dates.FixedPeriod = Dates.Second(1),
    epoch = nothing,
)
    # Convert epoch to DateTime if it is not nothing (from, e.g., Date)
    isnothing(epoch) || (epoch = Dates.DateTime(epoch))
    return ITime(counter, period, epoch)
end

"""
    seconds(t::ITime)

Return the time represented by `t` in seconds, as a floating-point number.
"""
function seconds(t::ITime)
    return float(t)
end

# Accessors
"""
    counter(t::ITime)

Return the counter of the `ITime` `t`.
"""
function counter(t::ITime)
    return t.counter
end

"""
    period(t::ITime)

Return the period of the `ITime` `t`.
"""
function period(t::ITime)
    return t.period
end

"""
    epoch(t::ITime)

Return the start date of the `ITime` `t`.
"""
function epoch(t::ITime)
    return t.epoch
end

function date(t::ITime{<:IntegerOrRatio, <:Dates.FixedPeriod, Nothing})
    error("Time does not have epoch information")
end

function date(t::ITime{<:Rational})
    # For Rational counters, we truncate at millisecond (which is the time
    # resolution in Dates any way)
    period_ms = Dates.toms(period(t))

    # Compute time in ms rounding it off to the nearest Millisecond
    time_ms = Int(round(float(counter(t) * period_ms)))
    return epoch(t) + Dates.Millisecond(time_ms)
end

"""
    date(t::ITime)

Return the date associated with `t`. If the time is fractional round it to millisecond.

For this to work, `t` has to have a `epoch`
"""
function date(t::ITime)
    return epoch(t) + counter(t) * period(t)
end

"""
    DateTime(t::ITime)

Convert an `ITime` to a `DateTime`.
"""
function Dates.DateTime(t::ITime)
    return date(t)
end

"""
    ITime(t; epoch = nothing)

Construct an `ITime` from a number `t` representing a time interval.

The function attempts to find a `Dates.FixedPeriod` such that `t` can be
represented as an integer multiple of that period.

If `t` is approximately zero, it defaults to a period of 1 second.
"""
function ITime(t; epoch = nothing)
    # If it is zero, assume seconds
    isapprox(t, 0) && return ITime(0, Dates.Second(1), epoch)

    # Promote t to Float64 to avoid loss of precision
    t = Float64(t)
    periods = [
        Dates.Week,
        Dates.Day,
        Dates.Hour,
        Dates.Minute,
        Dates.Second,
        Dates.Millisecond,
        Dates.Microsecond,
        Dates.Nanosecond,
    ]
    for period in periods
        period_ns = Dates.tons(period(1))
        t_int = 1_000_000_000 / period_ns * t
        if isinteger(t_int)
            return ITime(Int(t_int), period(1), epoch)
        end
    end
    error("Cannot represent $t as integer multiple of a Dates.FixedPeriod")
end

function Base.show(io::IO, time::ITime)
    # Hack to pretty print fractional times. We cannot just use Dates to print
    # them because they cannot be nicely converted to Periods, instead of
    # reconstruct the string from the type name and the value (obtained my
    # multiplying the counter and the number of units in the period)
    value = counter(time) * period(time).value
    plural_s = abs(value) != 1 ? "s" : ""
    unit = lowercase(string(nameof(typeof(period(time))))) * plural_s

    print(io, "$value $unit ")
    # Add date, if available
    if !isnothing(epoch(time)) && counter(time) isa Integer
        print(io, "($(date(time))) ")
    end
    print(io, "[counter = $(counter(time)), period = $(period(time))")
    # Add start date, if available
    if !isnothing(epoch(time))
        print(io, ", epoch = $(epoch(time))")
    end
    print(io, "]")
end

"""
    promote(ts::ITime...)

Promote a tuple of `ITime` instances to a common type.

This function determines a common `epoch` and `period` for all the input
`ITime` instances and returns a tuple of new `ITime` instances with the common
type.  It throws an error if the start dates are different.
"""
function Base.promote(ts::ITime...)
    common_epoch = find_common_epoch(ts...)

    # Determine the common period
    common_period = reduce(gcd, (period(t) for t in ts))

    # Promote each ITime instance by computing the scaling factor needed
    return map(
        t -> ITime(
            counter(t) * typeof(t.counter)(div(period(t), common_period)),
            common_period,
            common_epoch,
        ),
        ts,
    )
end

"""
    find_common_epoch(ts::ITime...)

Find a common epoch of `ts` if one exists.
"""
function find_common_epoch(ts::ITime...)
    epochs = (epoch(t) for t in ts if !isnothing(epoch(t)))
    common_epoch = reduce(_unique_epochs, epochs, init = nothing)
    return common_epoch
end

"""
    _unique_epochs(epoch1, epoch2)

Return an epoch if it is unique or an error otherwise.
"""
function _unique_epochs(epoch1, epoch2)
    if isnothing(epoch1)
        return epoch2
    elseif epoch1 == epoch2
        return epoch2
    else
        return error("Cannot find common epoch")
    end
end

"""
    Base.:(:)(start::ITime, step::ITime, stop::ITime)

Range operator. `start:step:stop` constructs a range from start to stop with a
step size equal to step.
"""
function Base.:(:)(start::ITime, step::ITime, stop::ITime)
    start, step, stop = promote(start, step, stop)
    common_epoch = find_common_epoch(start, step, stop)
    return (
        ITime(count, period = start.period, epoch = common_epoch) for
        count in (start.counter):(step.counter):(stop.counter)
    )
end

"""
    Base.mod(x::ITime, y::ITime)

Return the counter of `x` modulo counter of `y` after promote `x` and `y` to the
same period and epoch.
"""
function Base.mod(x::ITime, y::ITime)
    x, y = promote(x, y)
    reminder = mod(x.counter, y.counter)
    return ITime(reminder, period = x.period, epoch = x.epoch)
end

"""
    Base.:(%)(x::ITime, y::ITime)

Return the counter of `x` modulo counter of `y` after promote `x` and `y` to the
same period and epoch.
"""
function Base.:(%)(x::ITime, y::ITime)
    return mod(x, y)
end


macro itime_unary_op(op)
    return esc(
        quote
            Base.$op(t::T) where {T <: ITime} =
                ITime($op(t.counter), t.period, t.epoch)
        end,
    )
end

macro itime_binary_op(op)
    return esc(
        quote
            function Base.$op(t1::T1, t2::T2) where {T1 <: ITime, T2 <: ITime}
                t1p, t2p = promote(t1, t2)
                ITime(
                    $op(t1p.counter, t2p.counter),
                    t1p.period,
                    t1p.epoch,
                )
            end
        end,
    )
end

macro itime_binary_op_notype(op)
    return esc(
        quote
            function Base.$op(t1::T1, t2::T2) where {T1 <: ITime, T2 <: ITime}
                t1p, t2p = promote(t1, t2)
                $op(t1p.counter, t2p.counter)
            end
        end,
    )
end

@itime_unary_op abs
@itime_unary_op -

@itime_binary_op +
@itime_binary_op -

Base.isnan(t::ITime) = Base.isnan(t.counter)

@itime_binary_op_notype isless
@itime_binary_op_notype ==
@itime_binary_op_notype isequal
@itime_binary_op_notype isapprox
@itime_binary_op_notype div
@itime_binary_op_notype //
Base.:/(t1::T1, t2::T2) where {T1 <: ITime, T2 <: ITime} = t1 // t2

# Multiplication/division by numbers
Base.div(t::T1, num::IntegerOrRatio) where {T1 <: ITime} =
    ITime(div(t.counter, num), t.period, t.epoch)
function Base.://(t::T1, num::IntegerOrRatio) where {T1 <: ITime}
    new_counter_rational = t.counter // num
    new_counter =
        new_counter_rational.den == 1 ? new_counter_rational.num :
        new_counter_rational
    ITime(new_counter, t.period, t.epoch)
end
Base.:/(t::T1, num::IntegerOrRatio) where {T1 <: ITime} = t // num
Base.:*(num::IntegerOrRatio, t::T) where {T <: ITime} =
    ITime(num * t.counter, t.period, t.epoch)
Base.:*(t::T, num::IntegerOrRatio) where {T <: ITime} =
    ITime(num * t.counter, t.period, t.epoch)

# Pay attention to the units here! zero and one are not symmetric
Base.one(t::T) where {T <: ITime} = 1
Base.oneunit(t::T) where {T <: ITime} = ITime(eltype(t.counter)(1), t.period, t.epoch)
Base.zero(t::T) where {T <: ITime} = ITime(eltype(t.counter)(0), t.period, t.epoch)

"""
    float(t::ITime)

Convert an `ITime` to a floating-point number representing the time in seconds.
"""
function Base.float(t::T) where {T <: ITime}
    if VERSION >= v"1.11"
        return Dates.seconds(t.period) * t.counter
    else
        return Dates.tons(t.period) / 1_000_000_000 * t.counter
    end
end

# Behave as a scalar when broadcasted
Base.Broadcast.broadcastable(t::ITime) = Ref(t)
