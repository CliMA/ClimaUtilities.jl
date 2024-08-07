module DataHandlingExt

import Dates
import Dates: Second

import ClimaCore
import ClimaCore: ClimaComms

import ClimaUtilities.DataStructures
import ClimaUtilities.Regridders
import ClimaUtilities.FileReaders: AbstractFileReader, NCFileReader, read
import ClimaUtilities.Regridders: AbstractRegridder, regrid

import ClimaUtilities.Utils: isequispaced, period_to_seconds_float

import ClimaUtilities.DataHandling

"""
    DataHandler{
         FR <: AbstractFileReader,
         REG <: AbstractRegridder,
         SPACE <: ClimaCore.Spaces.AbstractSpace,
         REF_DATE <: Dates.DateTime,
         TSTART <: AbstractFloat,
         DATES <: AbstractArray{<:Dates.DateTime},
         DIMS,
         TIMES <: AbstractArray{<:AbstractFloat},
         CACHE <: DataStructures.LRUCache{<:Dates.DateTime, ClimaCore.Fields.Field},
     }

Currently, the `DataHandler` works with one variable at the time. This might not be the most
efficiently way to tackle the problem: we should be able to reuse the interpolation weights if
multiple variables are defined on the same grid and have to be remapped to the same grid.

Assumptions:
- There is only one file with the entire time development of the given variable
- The file has well-defined physical dimensions (e.g., lat/lon)
- Currently, the time dimension has to be either "time" or "date", the spatial
  dimensions have to be lat and lon (restriction from TempestRegridder)

DataHandler is meant to live on the CPU, but the Fields can be on the GPU as well.
"""
struct DataHandler{
    FR <: AbstractFileReader,
    REG <: AbstractRegridder,
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    REF_DATE <: Dates.DateTime,
    TSTART <: AbstractFloat,
    DATES <: AbstractArray{<:Dates.DateTime},
    DIMS,
    TIMES <: AbstractArray{<:AbstractFloat},
    CACHE <: DataStructures.LRUCache{<:Dates.DateTime, ClimaCore.Fields.Field},
}
    """Object responsible for getting the data from disk to memory"""
    file_reader::FR

    """Object responsible for resampling a rectangular grid to the simulation grid"""
    regridder::REG

    """ClimaCore Space over which the data has to be resampled"""
    target_space::SPACE

    """Tuple of linear arrays where the data is defined (typically long/lat)"""
    dimensions::DIMS

    """Calendar dates over which the data is defined"""
    available_dates::DATES

    """Simulation time at the beginning of the simulation in seconds (typically 0, but
    could be different, e.g., for restarted simulations)"""
    t_start::TSTART

    """Reference calendar date at the beginning of the simulation."""
    reference_date::REF_DATE

    """Timesteps over which the data is defined (in seconds)"""
    available_times::TIMES

    """Private field where cached data is stored"""
    _cached_regridded_fields::CACHE
end

"""
    DataHandler(file_path::AbstractString,
                varname::AbstractString,
                target_space::ClimaCore.Spaces.AbstractSpace;
                reference_date::Dates.DateTime = Dates.DateTime(1979, 1, 1),
                t_start::AbstractFloat = 0.0,
                regridder_type = nothing,
                cache_max_size::Int = 128,
                regridder_kwargs = (),
                file_reader_kwargs = ())

Create a `DataHandler` to read `varname` from `file_path` and remap it to `target_space`.

The DataHandler maintains an LRU cache of Fields that were previously computed.

Positional arguments
=====================

- `file_path`: Path of the NetCDF file that contains the data.
- `varname`: Name of the dataset in the NetCDF that has to be read and processed.
- `target_space`: Space where the simulation is run, where the data has to be regridded to.

Keyword arguments
===================

Time/date information will be ignored for static input files. (They are still set to make
everything more type stable.)

- `reference_date`: Calendar date corresponding to the start of the simulation.
- `t_start`: Simulation time at the beginning of the simulation. Typically this is 0
             (seconds), but if might be different if the simulation was restarted.
- `regridder_type`: What type of regridding to perform. Currently, the ones implemented are
                    `:TempestRegridder` (using `TempestRemap`) and
                    `:InterpolationsRegridder` (using `Interpolations.jl`). `TempestRemap`
                    regrids everything ahead of time and saves the result to HDF5 files.
                    `Interpolations.jl` is online and GPU compatible but not conservative.
                    If the regridder type is not specified by the user, and multiple are
                    available, the default `:InterpolationsRegridder` regridder is used.
- `cache_max_size`: Maximum number of regridded fields to store in the cache. If the cache
                    is full, the least recently used field is removed.
- `regridder_kwargs`: Additional keywords to be passed to the constructor of the regridder.
                      It can be a NamedTuple, or a Dictionary that maps Symbols to values.
- `file_reader_kwargs`: Additional keywords to be passed to the constructor of the file reader.
                        It can be a NamedTuple, or a Dictionary that maps Symbols to values.
"""
function DataHandling.DataHandler(
    file_path::AbstractString,
    varname::AbstractString,
    target_space::ClimaCore.Spaces.AbstractSpace;
    reference_date::Dates.DateTime = Dates.DateTime(1979, 1, 1),
    t_start::AbstractFloat = 0.0,
    regridder_type = nothing,
    cache_max_size::Int = 128,
    regridder_kwargs = (),
    file_reader_kwargs = (),
)

    # Determine which regridder to use if not already specified
    regridder_type =
        isnothing(regridder_type) ? Regridders.default_regridder_type() :
        regridder_type

    # File reader, deals with ingesting data, possibly buffered/cached
    file_reader = NCFileReader(file_path, varname; file_reader_kwargs...)

    regridder_args = ()

    if regridder_type == :TempestRegridder
        # TempestRegridder does not currently have the capability to regrid 3D
        # fields, so we check that the input space is not 3D
        @assert !(
            target_space isa ClimaCore.Spaces.ExtrudedFiniteDifferenceSpace
        )
        if !(:regrid_dir in regridder_kwargs)
            # If we do not have a regrid_dir, create one and broadcast it to all the MPI
            # processes
            context = ClimaComms.context(target_space)
            regrid_dir = ClimaComms.iamroot(context) ? mktempdir() : ""
            regrid_dir = ClimaComms.bcast(context, regrid_dir)
            ClimaComms.barrier(context)
            regridder_kwargs = merge((; regrid_dir), regridder_kwargs)
        end

        regridder_args = (target_space, varname, file_path)
    elseif regridder_type == :InterpolationsRegridder
        regridder_args = (target_space,)
    end

    RegridderConstructor = getfield(Regridders, regridder_type)
    regridder = RegridderConstructor(regridder_args...; regridder_kwargs...)

    # Use an LRU cache to store regridded fields
    _cached_regridded_fields =
        DataStructures.LRUCache{Dates.DateTime, ClimaCore.Fields.Field}(
            max_size = cache_max_size,
        )

    available_dates = file_reader.available_dates
    times_s = period_to_seconds_float.(available_dates .- reference_date)
    available_times = times_s .- t_start

    return DataHandler(
        file_reader,
        regridder,
        target_space,
        file_reader.dimensions,
        available_dates,
        t_start,
        reference_date,
        available_times,
        _cached_regridded_fields,
    )
end

"""
    close(data_handler::DataHandler)

Close any file associated to the given `data_handler`.
"""
function Base.close(data_handler::DataHandler)
    close(data_handler.file_reader)
    return nothing
end

"""
    available_times(data_handler::DataHandler)

Return the time in seconds of the snapshots in the data, measured considering
the starting time of the simulation and the reference date
"""
function DataHandling.available_times(data_handler::DataHandler)
    return data_handler.available_times
end

"""
    available_dates(data_handler::DataHandler)

Return the dates of the snapshots in the data.
"""
function DataHandling.available_dates(data_handler::DataHandler)
    return data_handler.available_dates
end

"""
    dt(data_handler::DataHandler)

Return the time interval between data points for the data in `data_handler`.

This requires the data to be defined on a equispaced temporal mesh.
"""
function DataHandling.dt(data_handler::DataHandler)
    isequispaced(DataHandling.available_times(data_handler)) ||
        error("dt not defined for non equispaced data")
    return DataHandling.available_times(data_handler)[begin + 1] -
           DataHandling.available_times(data_handler)[begin]
end


"""
    time_to_date(data_handler::DataHandler, time::AbstractFloat)

Convert the given time to a calendar date.

```
date = reference_date + t_start + time
```
"""
function DataHandling.time_to_date(
    data_handler::DataHandler,
    time::AbstractFloat,
)
    # We go through nanoseconds to allow fractions of a second (otherwise, Second(0.8) would fail)
    time_ms = Dates.Nanosecond(1_000_000_000 * (data_handler.t_start + time))
    return data_handler.reference_date + time_ms
end

"""
    date_to_time(data_handler::DataHandler, time::AbstractFloat)

Convert the given calendar date to a time (in seconds).

```
date = reference_date + t_start + time
```
"""
function DataHandling.date_to_time(
    data_handler::DataHandler,
    date::Dates.DateTime,
)
    return period_to_seconds_float(date - data_handler.reference_date) -
           data_handler.t_start
end

"""
    previous_time(data_handler::DataHandler, time::AbstractFloat)
    previous_time(data_handler::DataHandler, date::Dates.DateTime)

Return the time in seconds of the snapshot before the given `time`.
If `time` is one of the snapshots, return itself.

If `time` is not in the `data_handler`, return an error.
"""
function DataHandling.previous_time(
    data_handler::DataHandler,
    time::AbstractFloat,
)
    date = DataHandling.time_to_date(data_handler, time)
    return DataHandling.previous_time(data_handler, date)
end

function DataHandling.previous_time(
    data_handler::DataHandler,
    date::Dates.DateTime,
)
    # We have to handle separately what happens when we are on the node
    if date in data_handler.available_dates
        index = searchsortedfirst(data_handler.available_dates, date)
    else
        index = searchsortedfirst(data_handler.available_dates, date) - 1
    end
    index < 1 && error("Date $date is before available dates")
    return data_handler.available_times[index]
end

"""
    next_time(data_handler::DataHandler, time::AbstractFloat)
    next_time(data_handler::DataHandler, date::Dates.DateTime)

Return the time in seconds of the snapshot after the given `time`.
If `time` is one of the snapshots, return the next time.

If `time` is not in the `data_handler`, return an error.
"""
function DataHandling.next_time(data_handler::DataHandler, time::AbstractFloat)
    date = DataHandling.time_to_date(data_handler, time)
    return DataHandling.next_time(data_handler, date)
end

function DataHandling.next_time(data_handler::DataHandler, date::Dates.DateTime)
    # We have to handle separately what happens when we are on the node
    if date in data_handler.available_dates
        index = searchsortedfirst(data_handler.available_dates, date) + 1
    else
        index = searchsortedfirst(data_handler.available_dates, date)
    end
    index > length(data_handler.available_dates) &&
        error("Date $date is after available dates")
    return data_handler.available_times[index]
end

"""
    regridded_snapshot(data_handler::DataHandler, date::Dates.DateTime)
    regridded_snapshot(data_handler::DataHandler, time::AbstractFloat)
    regridded_snapshot(data_handler::DataHandler)

Return the regridded snapshot from `data_handler` associated to the given `time` (if relevant).

The `time` has to be available in the `data_handler`.

`regridded_snapshot` potentially modifies the internal state of `data_handler` and it might be a very
expensive operation.
"""
function DataHandling.regridded_snapshot(
    data_handler::DataHandler,
    date::Dates.DateTime,
)
    # Dates.DateTime(0) is the cache key for static maps
    if date != Dates.DateTime(0)
        date in data_handler.available_dates || error(
            "Date $date not available in file $(data_handler.file_reader.file_path)",
        )
    end

    regridder_type = nameof(typeof(data_handler.regridder))
    regrid_args = ()

    return get!(data_handler._cached_regridded_fields, date) do
        if regridder_type == :TempestRegridder
            regrid_args = (date,)
        elseif regridder_type == :InterpolationsRegridder
            regrid_args =
                (read(data_handler.file_reader, date), data_handler.dimensions)
        else
            error("Uncaught case")
        end
        regrid(data_handler.regridder, regrid_args...)
    end
end

function DataHandling.regridded_snapshot(
    data_handler::DataHandler,
    time::AbstractFloat,
)
    date = DataHandling.time_to_date(data_handler, time)
    return DataHandling.regridded_snapshot(data_handler, date)
end

function DataHandling.regridded_snapshot(data_handler::DataHandler)
    # This function can be called only when there are no dates (ie, the dataset is static)
    isempty(data_handler.available_dates) ||
        error("DataHandler is function of time")

    # In this case, we use as cache key `Dates.DateTime(0)`
    return DataHandling.regridded_snapshot(data_handler, Dates.DateTime(0))
end

function DataHandling.regridded_snapshot!(out, data_handler, time)
    out .= DataHandling.regridded_snapshot(data_handler, time)
    return nothing
end

end
