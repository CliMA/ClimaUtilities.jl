module OnlineLogging

import Dates

"""
    WallTimeInfo

Hold information about wall time.
"""
struct WallTimeInfo
    """How many times the `update!` function has been called on this object. `update!` is
    intended to be call at the end of every timestep with a callback. This field is
    primarily used to exclude compilation from the timings."""
    n_calls::Base.RefValue{Int}
    """Wall time of the previous call to update `WallTimeInfo`."""
    t_wall_last::Base.RefValue{Float64}
    # We don't save t_wall_init, but ∑Δt_wall because we want to avoid including the
    # compilation time in here. update_progress_reporter! will skip the first couple of
    # steps
    """Sum of elapsed walltime all the calls to `_update!`"""
    ∑Δt_wall::Base.RefValue{Float64}
    """Simulation time at previous call to `_update!`"""
    t_simulation_last::Base.RefValue{Float64}
    """The `n_calls` after which the first call to `_update!` will be included in the overall
    timing measurements, if the simulation time is also past `first_update_after_t_simulation`."""
    first_update_after_n_calls::Int
    """The simulation time after which the first call to `_update!` will be included in the
    overall timing measurements, if the number of calls is also past `first_update_after_n_calls`."""
    first_update_after_t_simulation::Float64
end

"""
    WallTimeInfo(;
        first_update_after_n_calls = 2,
        first_update_after_t_simulation = typemin(Float64))
    )

Constructor for `WallTimeInfo` struct. The default value for `first_update_after_n_calls` is
set to 2 to exclude the first sim step, even when called once before the first step.
"""
function WallTimeInfo(;
    first_update_after_n_calls = 2,
    first_update_after_t_simulation = typemin(Float64),
)
    n_calls = Ref(0)
    t_wall_last = Ref(-1.0)
    ∑Δt_wall = Ref(0.0)
    t_simulation_last = Ref(-1.0)
    return WallTimeInfo(
        n_calls,
        t_wall_last,
        ∑Δt_wall,
        t_simulation_last,
        first_update_after_n_calls,
        first_update_after_t_simulation,
    )
end
"""
    _update!(wt::WallTimeInfo)

Update the timing information stored in the `WallTimeInfo` struct `wt`, and return
the wall time per step for the current measurement.

This function tracks the wall time elapsed since the last call to `update!`. It handles the
initial calls specially to exclude compilation time from the overall timing measurements.
Measurements are only included in the overall timing after both of the following conditions are met:
1. The number of calls to `_update!` exceeds `wt.first_update_after_n_calls`.
2. The current simulation time exceeds `wt.first_update_after_t_simulation`.
"""
function _update!(wt::WallTimeInfo, integrator)
    wt.n_calls[] += 1
    t = float(integrator.t)
    t_start, _ = float.(integrator.sol.prob.tspan)
    should_record_measurement =
        wt.n_calls[] > wt.first_update_after_n_calls &&
        t > wt.first_update_after_t_simulation
    Δt_wall = time() - wt.t_wall_last[]
    dt = float(integrator.dt)
    n_steps_this_measurement = ceil(Int, (t - wt.t_simulation_last[]) / dt)
    wall_time_per_step_this_measurement = Δt_wall / n_steps_this_measurement
    # The first recorded measurement is scaled to account for the steps before  
    # All the other calls are included without any special operation.
    if should_record_measurement
        # the first time we record a measurement we compensate for the skipped measurements
        # by estimating how long they would have taken without the compilation time, and adding
        # that to the total wall time.
        if wt.∑Δt_wall[] == 0.0
            simulation_time_since_last =
                float(integrator.t) - wt.t_simulation_last[]
            # account for steps before previous call to _update
            simulation_time_missed = wt.t_simulation_last[] - t_start
            # estimate the walltime the steps during the skipped measurements would have taken
            # if there was no compilation by scaling the latest measurement
            estimated_walltime_missed_without_compilation =
                (simulation_time_missed / simulation_time_since_last) * Δt_wall
            Δt_wall += estimated_walltime_missed_without_compilation
        end
        wt.∑Δt_wall[] += Δt_wall
    end

    wt.t_simulation_last[] = float(integrator.t)
    wt.t_wall_last[] = time()
    return wall_time_per_step_this_measurement
end

"""
    report_walltime(wt::WallTimeInfo, integrator)

Report the current progress and estimated completion time of a simulation.

This function calculates and displays various timing statistics based on the provided
`WallTimeInfo` (`wt`) and the `integrator` state. It estimates the remaining wall time,
total simulation time, and simulated time per real-time unit.

Prints a summary of the simulation progress to the console, including:

- `simulation_time`: The current simulated time.
- `n_steps_completed`: The number of completed steps.
- `wall_time_per_step`: Average wall time per simulation step. You should expect this to be
                        unreliable until the number of completed steps is large.
- `wall_time_total`: Estimated total wall time for the simulation. You should expect this to be
                     unreliable until the number of completed steps is large.
- `wall_time_remaining`: Estimated remaining wall time. You should expect this to be
                         unreliable until the number of completed steps is large.
- `wall_time_spent`: Total wall time spent so far.
- `percent_complete`: Percentage of the simulation completed.
- `estimated_sypd`: Estimated simulated years per day (or simulated days per day if sypd is
                    very small). You should expect this to be unreliable until the number of
                    completed steps is large.
- `instantaneous_sypd`: Simulated years per day (or simulated days per day if sypd is very
                        small) for the most recent measurement.
- `date_now`: The current date and time.
- `estimated_finish_date`: The estimated date and time of simulation completion. You should
                           expect this to be unreliable until the number of completed steps
                           is large.

!!! note

    Average quantities and simulated-years-per-day are computed by taking the total time
    elapsed (minus initial compilation) and dividing by the number of steps completed. You
    should expect them to fluctuate heavily and to be unreliable until the number of steps
    become large. "Large" is defined by your problem: for example, the code has to go
    through all the callbacks and diagnostics a few times before stabilizing (and this is
    different for different simulations).

## Arguments:

* `wt::WallTimeInfo`:  A struct containing wall time information.
* `integrator`: The integrator object containing simulation state information, including the
                 current time `t`, timestep `dt`. It also have to have time span `tspan`
                 in `integrator.sol.prob.tspan`.

## How to use `report_walltime`

`report_walltime` is intended to be used as a callback executed at the end of a simulation
step. The callback can be called with an arbitrary schedule, so that reporting can be
customized.

### Example

Suppose we want to report progress every 10 steps in a `SciMLBase`-type of integrator.
```julia
import ClimaUtilities.OnlineLogging: WallTimeInfo, report_progress
import SciMLBase

# Prepare the WallTimeInfo
walltime_info = WallTimeInfo()

# Define schedule, a boolean function that takes the integrator
every10steps(u, t, integrator) = mod(integrator.step, 10) == 0

# Define the callback, we use `let` to make this a little faster
report = let wt = walltime_info
     (integrator) -> report_progress(wt, integrator)
end
report_callback = SciMLBase.DiscreteCallback(every10steps, report)

# Then, we can attach this callback to the integrator
```
TODO: Discuss/link `Schedules` when we move them to `ClimaUtilities`.
"""
function report_walltime(wt, integrator)
    inst_wall_time_per_step = _update!(wt, integrator)
    t_start, t_end = float.(integrator.sol.prob.tspan)
    dt = float(integrator.dt)
    t = float(integrator.t)

    n_steps_total = ceil(Int, (t_end - t_start) / dt)
    n_steps = ceil(Int, (t - t_start) / dt)

    wall_time_ave_per_step = wt.∑Δt_wall[] / n_steps
    wall_time_ave_per_step_str = _time_and_units_str(wall_time_ave_per_step)
    percent_complete =
        round((t - t_start) / (t_end - t_start) * 100; digits = 1)
    n_steps_remaining = n_steps_total - n_steps
    wall_time_remaining = wall_time_ave_per_step * n_steps_remaining
    wall_time_remaining_str = _time_and_units_str(wall_time_remaining)
    wall_time_total =
        _time_and_units_str(wall_time_ave_per_step * n_steps_total)
    wall_time_spent = _time_and_units_str(wt.∑Δt_wall[])
    simulation_time = _time_and_units_str(float(t))

    overall_simulated_seconds_per_second = (t - t_start) / wt.∑Δt_wall[]
    inst_simulated_seconds_per_second = dt / inst_wall_time_per_step
    overall_sypd_estimate =
        sypd_str_from_ssps(overall_simulated_seconds_per_second)
    inst_sypd = sypd_str_from_ssps(inst_simulated_seconds_per_second)
    estimated_finish_date =
        Dates.now() + Dates.Second(ceil(wall_time_remaining))
    @info "Progress" simulation_time = simulation_time n_steps_completed =
        n_steps wall_time_per_step = wall_time_ave_per_step_str wall_time_total =
        wall_time_total wall_time_remaining = wall_time_remaining_str wall_time_spent =
        wall_time_spent percent_complete = "$percent_complete%" estimated_sypd =
        overall_sypd_estimate instantaneous_sypd = inst_sypd date_now =
        Dates.now() estimated_finish_date = estimated_finish_date

    return nothing
end

# TODO: Consider moving this to TimeManager
"""
    _time_and_units_str(seconds::Real)

Returns a truncated string of time and units, given a time `x` in Seconds.
"""
function _time_and_units_str(seconds)
    isapprox(seconds, 0) && return "0 seconds"
    nanoseconds = Dates.Nanosecond(ceil(1_000_000_000seconds))
    compound_period = Dates.canonicalize(Dates.CompoundPeriod(nanoseconds))
    return _trunc_time(string(compound_period))
end
_trunc_time(s::String) = count(',', s) > 1 ? join(split(s, ",")[1:2], ",") : s

"""
    sypd_str_from_ssps(simulated_seconds_per_second)
Given a simulated seconds per second, return a string of simulated years per day (sypd).
When sypd is very small, sdpd is appended to the string.
"""
function sypd_str_from_ssps(simulated_seconds_per_second)
    simulated_seconds_per_day = simulated_seconds_per_second * 86400
    simulated_days_per_day = simulated_seconds_per_day / 86400
    simulated_years_per_day = simulated_days_per_day / 365.25
    # When simulated_years_per_day is too small, also report the simulated_days_per_day
    sypd_estimate = string(round(simulated_years_per_day; digits = 3))
    if simulated_years_per_day < 0.01
        sdpd_estimate = round(simulated_days_per_day, digits = 3)
        sypd_estimate *= " (sdpd_estimate = $sdpd_estimate)"
    end
    return sypd_estimate
end
end
