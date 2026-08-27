function _period_difference(date_left, date_right, period::Dates.DatePeriod)
    return beginningofperiod(date_right, period) -
           beginningofperiod(date_left, period)
end

function _move_date_to_period(date, target_period, period::Dates.DatePeriod)
    return date + _period_difference(date, target_period, period)
end

_dates_in_period(dates, period_start, period::Dates.DatePeriod) = view(
    dates,
    searchsortedfirst(dates, period_start):searchsortedlast(
        dates,
        endofperiod(period_start, period),
    ),
)

function _interpolable_range(
    dates_period_left,
    dates_period_right,
    period::Dates.DatePeriod,
)
    allequal(beginningofperiod(d, period) for d in dates_period_left) ||
        error("dates in dates_period_left belongs to different periods")
    allequal(beginningofperiod(d, period) for d in dates_period_right) ||
        error("dates in dates_period_right belongs to different periods")
    offset = _period_difference(
        first(dates_period_left),
        first(dates_period_right),
        period,
    )
    return max(
        minimum(dates_period_left),
        minimum(dates_period_right) - offset,
    ),
    min(maximum(dates_period_left), maximum(dates_period_right) - offset)
end

function _evaluate!(
    dest,
    itp::InterpolatingTimeVaryingInput23D,
    time,
    method::LinearPeriodFillingInterpolation,
)
    if !(time in itp)
        date0, _, _ =
            _boundary_stencil(time, itp.data_handler, extrapolation_bc(method))
        dest .= regridded_snapshot(itp.data_handler, date0)
        return nothing
    end
    period = method.period
    available_periods =
        unique_periods(available_dates(itp.data_handler), period)
    if beginningofperiod(time, period) in available_periods
        _evaluate!(dest, itp, time, LinearInterpolation())
        return nothing
    end
    date0, date1, w, submethod =
        _period_filling_stencil(time, itp, available_periods, method)
    scratch =
        submethod isa LinearPeriodFillingInterpolation ?
        itp.preallocated_regridded_fields[2] :
        itp.preallocated_regridded_fields[1]
    _evaluate!(dest, itp, date0, submethod)
    _evaluate!(scratch, itp, date1, submethod)
    dest .= dest .+ (scratch .- dest) .* w
    return nothing
end

function _period_filling_stencil(
    time,
    itp::InterpolatingTimeVaryingInput23D,
    available_periods,
    method::LinearPeriodFillingInterpolation,
)
    period = method.period
    dates = available_dates(itp.data_handler)
    target_period = beginningofperiod(time, period)

    index_right = searchsortedfirst(available_periods, target_period)
    period_left, period_right =
        available_periods[index_right - 1], available_periods[index_right]
    dates_period_left = _dates_in_period(dates, period_left, period)
    dates_period_right = _dates_in_period(dates, period_right, period)

    time_in_period_left = _move_date_to_period(time, period_left, period)
    time_in_period_right = _move_date_to_period(time, period_right, period)

    min_interpolable, max_interpolable =
        _interpolable_range(dates_period_left, dates_period_right, period)

    if min_interpolable <= time_in_period_left <= max_interpolable
        w = (target_period - period_left) / (period_right - period_left)
        return (
            time_in_period_left,
            time_in_period_right,
            w,
            LinearInterpolation(),
        )
    end

    if time_in_period_left >= maximum(dates_period_left) ||
       time_in_period_right >= maximum(dates_period_right)
        date0 = _move_date_to_period(max_interpolable, target_period, period)
        date1 = _move_date_to_period(
            min_interpolable,
            target_period + period,
            period,
        )
    elseif minimum(dates_period_left) >= time_in_period_left ||
           minimum(dates_period_right) >= time_in_period_right
        date0 = _move_date_to_period(
            max_interpolable,
            target_period + period,
            period,
        )
        date1 = _move_date_to_period(min_interpolable, target_period, period)
    else
        error("We should not be here!")
    end
    return (date0, date1, (time - date0) / (date1 - date0), method)
end
