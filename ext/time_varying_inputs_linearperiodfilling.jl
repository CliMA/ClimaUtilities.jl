# This file is included in TimeVaryingInputsExt.jl and implements
# LinearPeriodFillingInterpolation on top of the stencil machinery defined there.

"""
    _period_difference(date_left, date_right, period::Dates.DatePeriod)

Return the difference in periods (in `Dates.Period`) from `date_right` to `date_left`.

For example, with `period = Year(1)`, the difference between 18/08/1995 and 17/01/1997 is 2
years.
"""
function _period_difference(date_left, date_right, period::Dates.DatePeriod)
    return beginningofperiod(date_right, period) -
           beginningofperiod(date_left, period)
end

"""
    _extract_period(date, period::Dates.DatePeriod)

Return the beginning of the period that contains `date`.
"""
function _extract_period(date, period::Dates.DatePeriod)
    return beginningofperiod(date, period)
end

"""
    _neighboring_period_indices(date, available_periods, period::Dates.DatePeriod)

Return the indices in `available_periods` of the two periods that neighbor `date`.
"""
function _neighboring_period_indices(
    date,
    available_periods,
    period::Dates.DatePeriod,
)
    index_period_right =
        findfirst(d -> d >= beginningofperiod(date, period), available_periods)
    return index_period_right - 1, index_period_right
end

"""
    _move_date_to_period(date, target_period, period::Dates.DatePeriod)

Return the date equivalent to `date` in the `target_period`.

For example, moving 07/03/1987 to the period of 1995 (with `period = Year(1)`) returns
07/03/1995.
"""
function _move_date_to_period(date, target_period, period::Dates.DatePeriod)
    period_offset = _period_difference(date, target_period, period)
    return date + period_offset
end

"""
    _date_in_range(date, left, right)

Check if `date` is between `left` and `right`.
"""
function _date_in_range(date, left, right)
    return left <= date <= right
end

"""
    _interpolable_range(dates_period_left, dates_period_right, period)

Find the two dates that bound the interpolable region, returned in `period_left`.

The interpolable region is where interpolation can be immediately performed in both
periods, because both have data before and after (the equivalent of) any date in it.
"""
function _interpolable_range(
    dates_period_left,
    dates_period_right,
    period::Dates.DatePeriod,
)
    if length(unique(beginningofperiod.(dates_period_left, period))) != 1
        error("dates in dates_period_left belongs to different periods")
    end
    if length(unique(beginningofperiod.(dates_period_right, period))) != 1
        error("dates in dates_period_right belongs to different periods")
    end

    period_offset = _period_difference(
        first(dates_period_left),
        first(dates_period_right),
        period,
    )
    dates_period_right_moved_to_left = dates_period_right .- period_offset

    largest_first_date = maximum([
        minimum(dates_period_left),
        minimum(dates_period_right_moved_to_left),
    ])
    smallest_last_date = minimum([
        maximum(dates_period_left),
        maximum(dates_period_right_moved_to_left),
    ])

    return largest_first_date, smallest_last_date
end

function _bc_info(data_handler, method::LinearPeriodFillingInterpolation)
    period = method.period
    dates = available_dates(data_handler)
    available_periods = unique_periods(dates, period)
    dates_in_period = [
        filter(d -> p <= d <= endofperiod(p, period), dates) for
        p in available_periods
    ]
    interpolable_ranges = [
        _interpolable_range(
            dates_in_period[index],
            dates_in_period[index + 1],
            period,
        ) for index in 1:(length(available_periods) - 1)
    ]
    return (; available_periods, dates_in_period, interpolable_ranges)
end

"""
    _evaluate_interior_linear!(dest, itp, time)

Write to `dest` the linear interpolation of `itp` at `time`, assuming `time` is within the
range of the available dates.
"""
function _evaluate_interior_linear!(dest, itp, time)
    date0, date1, coeff = _interior_stencil(itp, time, LinearInterpolation())
    _apply_stencil!(dest, itp, date0, date1, coeff)
    return nothing
end

function _evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time::DateTime,
    method::LinearPeriodFillingInterpolation,
)
    # LinearPeriodFilling only supports Throw and Flat (its constructor rejects
    # PeriodicCalendar), and the period-filling logic assumes an in-range time, so boundary
    # conditions are handled first
    bc = extrapolation_bc(method)
    if bc isa Throw
        time in itp || error("TimeVaryingInput does not cover time $time")
    elseif bc isa Flat
        dates = available_dates(itp.data_handler)
        if time >= dates[end]
            regridded_snapshot!(dest, itp.data_handler, dates[end])
            return nothing
        elseif time <= dates[begin]
            regridded_snapshot!(dest, itp.data_handler, dates[begin])
            return nothing
        end
    end
    _evaluate_period_filling!(dest, itp, time, method)
    return nothing
end

"""
    _bracketing_dates(time_in_left, time_in_right, dates_left, dates_right,
                      min_interpolable, max_interpolable, target_period, period)

Return `(date_pre, date_post)` bracketing a date that falls outside the interpolable
region, built by moving the region boundaries to the periods around `target_period`.
"""
function _bracketing_dates(
    time_in_left,
    time_in_right,
    dates_left,
    dates_right,
    min_interpolable,
    max_interpolable,
    target_period,
    period,
)
    if time_in_left >= maximum(dates_left) ||
       time_in_right >= maximum(dates_right)
        # Later than the interpolable region: from its end in the target period to its
        # start in the next one
        date_pre = _move_date_to_period(max_interpolable, target_period, period)
        date_post = _move_date_to_period(
            min_interpolable,
            target_period + period,
            period,
        )
    elseif minimum(dates_left) >= time_in_left ||
           minimum(dates_right) >= time_in_right
        # Earlier than the interpolable region: from its end in the previous period to its
        # start in the target period. This is the same line the branch above draws for
        # dates late in the previous period, so the interpolation is continuous across
        # period boundaries.
        date_pre = _move_date_to_period(
            max_interpolable,
            target_period - period,
            period,
        )
        date_post =
            _move_date_to_period(min_interpolable, target_period, period)
    else
        error("We should not be here!")
    end
    return date_pre, date_post
end

"""
    _evaluate_period_filling!(dest, itp, time, method)

Write to `dest` the period-filling linear interpolation of `itp` at `time`.

When the period of `time` has data, this is plain linear interpolation. Otherwise, the
equivalent dates in the two neighboring periods with data are each linearly interpolated,
and the two results are combined with a weight given by the position of the target period
between them. When the equivalent dates fall outside the interpolable region (so one of the
two periods has no data on both sides of them), the target is first bracketed between two
dates in interpolable regions and the interpolation recurses on those.
"""
function _evaluate_period_filling!(
    dest,
    itp,
    time::DateTime,
    method::LinearPeriodFillingInterpolation,
)
    period = method.period
    (; available_periods, dates_in_period, interpolable_ranges) = itp.bc_info

    if _extract_period(time, period) in available_periods
        _evaluate_interior_linear!(dest, itp, time)
        return nothing
    end

    # time is in range (boundary conditions are handled by the caller), so it always has
    # neighboring periods on both sides
    index_left, index_right =
        _neighboring_period_indices(time, available_periods, period)
    period_left = available_periods[index_left]
    period_right = available_periods[index_right]
    min_interpolable, max_interpolable = interpolable_ranges[index_left]

    tmp_field1, tmp_field2 = itp.preallocated_regridded_fields

    time_in_left_period = _move_date_to_period(time, period_left, period)
    in_interpolable_region =
        _date_in_range(time_in_left_period, min_interpolable, max_interpolable)

    # Both branches compute y = y_pre * (1 - weight) + y_post * weight in a single fused
    # broadcast, with the weight converted to the field eltype so GPUs do not compute in
    # double precision
    if in_interpolable_region
        date_pre = _move_date_to_period(time, period_left, period)
        date_post = _move_date_to_period(time, period_right, period)
        # The weight is the position of the target period between the two neighboring
        # periods (e.g., interpolating 1987 from 1985 and 1995 gives 2/10)
        offset_periods_left = beginningofperiod(time, period) - period_left
        period_offset = period_right - period_left
        weight = eltype(dest)(offset_periods_left / period_offset)

        _evaluate_interior_linear!(dest, itp, date_pre)
        _evaluate_interior_linear!(tmp_field1, itp, date_post)
        dest .= (1 - weight) .* dest .+ weight .* tmp_field1
    else
        date_pre, date_post = _bracketing_dates(
            time_in_left_period,
            _move_date_to_period(time, period_right, period),
            dates_in_period[index_left],
            dates_in_period[index_right],
            min_interpolable,
            max_interpolable,
            _extract_period(time, period),
            period,
        )
        weight = eltype(dest)((time - date_pre) / (date_post - date_pre))

        _evaluate_period_filling!(dest, itp, date_pre, method)
        _evaluate_period_filling!(tmp_field2, itp, date_post, method)
        dest .= (1 - weight) .* dest .+ weight .* tmp_field2
    end
    return nothing
end
