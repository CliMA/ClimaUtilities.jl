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
contains one or more `FileReader`(s), a `Regridder`, and other metadata necessary to perform
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
This is a least-recently-used (LRU) cache implemented in `DataStructures`,
which removes the least-recently-used data when its maximum size is reached.
The default maximum size is 128.

While the reading backend could be generic, at the moment, this module uses only
the `NCFileReader`.

> This extension is loaded when loading `ClimaCore` and `NCDatasets` are loaded.
> In addition to this, a `Regridder` is needed (which might require importing
> additional packages) - see [`Regridders`](@ref) for more information.

It is possible to pass down keyword arguments to underlying constructors in
`DataHandler` with the `regridder_kwargs` and `file_reader_kwargs`. These have
to be a named tuple or a dictionary that maps `Symbol`s to values.

A `DataHandler` can contain information about a variable that we read directly from
an input file, or about a variable that is produced by composing data from multiple
input variables. In the latter case, the input variables may either all come from
the same input file, or may each come from a separate input file. The user must
provide the composing function, which operates pointwise on each of the inputs,
as well as an ordered list of the variable names to be passed to the function.
Additionally, input variables that are composed together must have the same
spatial and temporal dimensions.
Note that, if a non-identity pre-processing function is provided as part of
`file_reader_kwargs`, it will be applied to each input variable before they
are composed.
Composing multiple input variables is currently only supported with the
`InterpolationsRegridder`, not with `TempestRegridder`.

## Example: Linear interpolation of a single data variable

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

# Define pre-processing function to convert units of input
unit_conversion_func = (data) -> 1000 * data

data_handler = DataHandling.DataHandler("era5_example.nc",
                                        "u",
                                        target_space,
                                        reference_date = Dates.DateTime(2000, 1, 1),
                                        regridder_type = :InterpolationsRegridder,
                                        file_reader_kwargs = (; preprocess_func = unit_conversion_func))

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

### Example appendix: Using multiple input data variables

Suppose that the input NetCDF file `era5_example.nc` contains two variables `u`
and `v`, and we care about their sum `u + v` but not their individual values.
We can provide a pointwise composing function to perform the sum, along with
the `InterpolationsRegridder` to produce the data we want, `u + v`.
The `preprocess_func` passed in `file_reader_kwargs` will be applied to `u`
and to `v` individually, before the composing function is applied. The regridding
is applied after the composing function. `u` and `v` could also come from separate
NetCDF files, but they must still have the same spatial and temporal dimensions.

```julia
# Define the pointwise composing function we want, a simple sum in this case
compose_function = (x, y) -> x + y
data_handler = DataHandling.DataHandler("era5_example.nc",
                                        ["u", "v"],
                                        target_space,
                                        reference_date = Dates.DateTime(2000, 1, 1),
                                        regridder_type = :InterpolationsRegridder,
                                        file_reader_kwargs = (; preprocess_func = unit_conversion_func),
                                        compose_function)
```

## API

```@docs
ClimaUtilities.DataHandling.DataHandler
ClimaUtilities.DataHandling.available_times
ClimaUtilities.DataHandling.available_dates
ClimaUtilities.DataHandling.previous_time
ClimaUtilities.DataHandling.next_time
ClimaUtilities.DataHandling.regridded_snapshot
ClimaUtilities.DataHandling.regridded_snapshot!
ClimaUtilities.DataHandling.dt
ClimaUtilities.DataHandling.time_to_date
ClimaUtilities.DataHandling.date_to_time
```
