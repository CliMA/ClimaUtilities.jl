"""
    CallbackManager

This module facilitates calendar functions and temporal interpolations
of data.
"""
module CallbackManager

import Dates

export HourlyCallback,
    MonthlyCallback,
    Monthly,
    EveryTimestep,
    trigger_callback!,
    to_datetime,
    strdate_to_datetime,
    datetime_to_strdate

"""
    AbstractCallback
"""
abstract type AbstractCallback end

"""
    HourlyCallback{FT}

This is a callback type that triggers at intervals of 1h or multiple hours.
"""
@kwdef struct HourlyCallback{FT} <: AbstractCallback
    """ Time interval at which the callback is triggered. """
    dt::FT = FT(1) # hours
    """ Function to be called at each trigger. """
    func::Function = do_nothing
    """ Reference date when the callback should be called. """
    ref_date::Array = [Dates.DateTime(0)]
    """ Whether the callback is active. """
    active::Bool = false
    """ Data to be passed to the callback function. """
    data::Array = []
end

"""
    MonthlyCallback{FT}

This is a callback type that triggers at intervals of 1 month or multiple months.
"""
@kwdef struct MonthlyCallback{FT} <: AbstractCallback
    """ Time interval at which the callback is triggered. """
    dt::FT = FT(1) # months
    """ Function to be called at each trigger. """
    func::Function = do_nothing
    """ Reference date for the callback. """
    ref_date::Array = [Dates.DateTime(0)]
    """ Whether the callback is active. """
    active::Bool = false
    """ Data to be passed to the callback function. """
    data::Array = []
end

"""
    dt_cb(cb::HourlyCallback)
    dt_cb(cb::MonthlyCallback)

This function returns the time interval for the callback.
"""
dt_cb(cb::HourlyCallback) = Dates.Hour(cb.dt)
dt_cb(cb::MonthlyCallback) = Dates.Month(cb.dt)


"""
    AbstractFrequency

This is an abstract type for the frequency of a callback function.
"""
abstract type AbstractFrequency end
struct Monthly <: AbstractFrequency end
struct EveryTimestep <: AbstractFrequency end

"""
    trigger_callback!(callback, date_current)

If the callback is active and the current date is equal to or later than the
"next call" reference date/time, call the callback function and increment the
next call date based on the callback frequency. Otherwise, do nothing and leave
the next call  date unchanged.

Note that the collection of data in `callback.data` must match the types, number,
and orderof arguments expected by `callback.func`.
"""
function trigger_callback!(callback::HourlyCallback, date_current)
    if callback.active && date_current >= callback.ref_date[1]
        callback.func(callback.data...)
        callback.ref_date[1] += Dates.Hour(1)
    end
end

function trigger_callback!(callback::MonthlyCallback, date_current)
    if callback.active && date_current >= callback.ref_date[1]
        callback.func(callback.data...)
        callback.ref_date[1] += Dates.Month(1)
    end
end

"""
    to_datetime(date)

Convert a `DateTime`-like object (e.g. `DateTimeNoLeap`) to a `DateTime`.
We need this since some data files we use contain
`DateTimeNoLeap` objects for dates, which can't be used for math with `DateTime`s.
The `DateTimeNoLeap` type uses the Gregorian calendar without leap years, while
the `DateTime` type uses Gregorian calendar with leap years.

For consistency, all input data files should have dates converted to `DateTime`
before being used in a simulation.

This function is similar to `reinterpret` in CFTime.jl.

# Arguments
- `date`: `DateTime`-like object to be converted to `DateTime`
"""
function to_datetime(date)
    return Dates.DateTime(
        Dates.year(date),
        Dates.month(date),
        Dates.day(date),
        Dates.hour(date),
        Dates.minute(date),
        Dates.second(date),
        Dates.millisecond(date),
    )
end

"""
    strdate_to_datetime(strdate::String)

Convert from String ("YYYYMMDD") to Date format,
required by the official AMIP input files.
"""
strdate_to_datetime(strdate::String) = Dates.DateTime(
    parse(Int, strdate[1:4]),
    parse(Int, strdate[5:6]),
    parse(Int, strdate[7:8]),
)

"""
    datetime_to_strdate(datetime::Dates.DateTime)

Convert from DateTime to String ("YYYYMMDD") format.
"""
datetime_to_strdate(datetime::Dates.DateTime) =
    string(lpad(Dates.year(datetime), 4, "0")) *
    string(string(lpad(Dates.month(datetime), 2, "0"))) *
    string(lpad(Dates.day(datetime), 2, "0"))


end # module CallbackManager
