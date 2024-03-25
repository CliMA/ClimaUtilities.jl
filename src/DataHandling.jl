"""
    DataHandling

The `DataHandling` module is responsible for reading data from files and resampling it onto
the simulation grid.

This is no trivial task. Among the challenges:
- data can be large and cannot be read all in one go and/or held in memory
- regridding onto the simulation grid can be very expensive
- IO can be very expensive
- CPU/GPU communication can be a bottleneck

The `DataHandling` takes the divide and conquer approach: the various core tasks and
features and split into other independent modules (chiefly `FileReaders`, and `Regridders`).
Such modules can be developed, tested, and extended independently (as long as they maintain
a consistent interface). For instance, if need arises, the `DataHandler` can be used
(almost) directly to process files with a different format from NetCDF.

The key struct in `DataHandling` is the `DataHandler`. The `DataHandler` contains a
`FileReaders`, a `Regridders`, and other metadata necessary to perform its operations (e.g.,
target `ClimaCore.Space`). The `DataHandler` can be used for static or temporal data, and
exposes the following key functions:
- `regridded_snapshot(time)`: to obtain the regridded field at the given `time`. `time` has to be
                    available in the data.
- `available_times` (`available_dates`): to list all the `times` (`dates`) over which the
                    data is defined.
- `previous_time(time/date)` (`next_time(time/date)`): to obtain the time of the snapshot
                         before the given `time` or `date`. This can be used to compute the
                         interpolation weight for linear interpolation, or in combination
                         with `regridded_snapshot` to read a particular snapshot
Most `DataHandling` functions take either `time` or `date`, with the difference being that
`time` is intended as "simulation time" and is expected to be in seconds; `date` is a
calendar date (from `Dates.DateTime`). Conversion between time and date is performed using
the reference date and simulation starting time provided to the `DataHandler`.

The `DataHandler` has a caching mechanism in place: once a field is read and regridded, it
is stored in the local cache to be used again (if needed).

While the reading backend could be generic, at the moment, this module uses only the NCFileReader.
"""
module DataHandling

function DataHandler end

function available_times end

function available_dates end

function previous_time end

function next_time end

function regridded_snapshot end

end
