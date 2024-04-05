# `DataHandling`

The `DataHandling` module is responsible for reading data from files and
resampling it onto the simulation grid.

This is no trivial task. Among the challenges:
- data can be large and cannot be read all in one go and/or held in memory,
- regridding onto the simulation grid can be very expensive,
- IO can be very expensive,
- CPU/GPU communication can be a bottleneck.

The `DataHandling` takes the divide and conquer approach: the various core tasks
and features and split into other independent modules (chiefly
[`FileReaders`](@ref), and [`Regridders`](@ref)). Such modules can be developed,
tested, and extended independently (as long as they maintain a consistent
interface). For instance, if need arises, the `DataHandler` can be used (almost)
directly to process files with a different format from NetCDF.

The key struct in `DataHandling` is the `DataHandler`. The `DataHandler`
contains a `FileReader`, a `Regridder`, and other metadata necessary to perform
its operations (e.g., target `ClimaCore.Space`). The `DataHandler` can be used
for static or temporal data, and exposes the following key functions:
- `regridded_snapshot(time)`: to obtain the regridded field at the given `time`.
                    `time` has to be available in the data.
- `available_times` (`available_dates`): to list all the `times` (`dates`) over
                    which the data is defined.
- `previous_time(time/date)` (`next_time(time/date)`): to obtain the time of the
                         snapshot before the given `time` or `date`. This can be
                         used to compute the interpolation weight for linear
                         interpolation, or in combination with
                         `regridded_snapshot` to read a particular snapshot
Most `DataHandling` functions take either `time` or `date`, with the difference
being that `time` is intended as "simulation time" and is expected to be in
seconds; `date` is a calendar date (from `Dates.DateTime`). Conversion between
time and date is performed using the reference date and simulation starting time
provided to the `DataHandler`.

The `DataHandler` has a caching mechanism in place: once a field is read and
regridded, it is stored in the local cache to be used again (if needed).

While the reading backend could be generic, at the moment, this module uses only
the `NCFileReader`.

> This extension is loaded when loading `ClimaCore` and `NCDatasets` are loaded.
> In addition to this, a `Regridder` is needed (which might require importing
> additional packages).

## Example

As an example, let us implement a simple linear interpolation for a variable `u`
defined in the `era5_example.nc` NetCDF file. The file contains monthly averages
starting from the year 2000.

```julia
import ClimaUtilities.DataHandling
import ClimaCore
import NCDatasets
# Loading ClimaCore and Interpolations automatically loads DataHandling
import Interpolations
# This will load InterpolationsRegridder

import Dates

data_handler = DataHandling.DataHandler("era5_example.nc",
                                        "u",
                                        target_space,
                                        reference_date = Dates.DateTime(2000, 1, 1),
                                        regridder_type = :InterpolationsRegridder)

function linear_interpolation(data_handler, time)
    # Time is assumed to be "simulation time", ie seconds starting from reference_date

    time_of_prev_snapshot = DataHandling.previous_time(data_handler, time)
    time_of_next_snapshot = DataHandling.next_time(data_handler, time)

    prev_snapshot = DataHandling.regridded_snaphsot(data_handler, time_of_prev_snapshot)
    next_snapshot = DataHandling.regridded_snaphsot(data_handler, time_of_next_snapshot)

    # prev and next snapshots are ClimaCore.Fields defined on the target_space

    return @. prev_snapshot + (next_snapshot - prev_snapshot) *
        (time - time_of_prev_snapshot) / (time_of_next_snapshot - time_of_prev_snapshot)
end
```

## API

```@docs
ClimaUtilities.DataHandling.DataHandler
ClimaUtilities.DataHandling.available_times
ClimaUtilities.DataHandling.available_dates
ClimaUtilities.DataHandling.previous_time
ClimaUtilities.DataHandling.next_time
ClimaUtilities.DataHandling.regridded_snapshot
```
