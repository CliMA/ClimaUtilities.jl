module DataHandlingExt

import Dates
import Dates: Second

import ClimaCore
import ClimaCore: ClimaComms

import ClimaUtilities.Regridders
import ClimaUtilities.FileReaders: AbstractFileReader, NCFileReader, read
import ClimaUtilities.Regridders: AbstractRegridder, regrid

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
         CACHE,
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
    CACHE,
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
                regridder_type = nothing)

Create a `DataHandler` to read `varname` from `file_path` and remap it to `target_space`.

The DataHandler maintains a cache of Fields that were previously computed.

TODO: Add function to clear cache, and/or CACHE_MAX_SIZE (this will probably require
developing a LRU cache scheme)

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
"""
function DataHandling.DataHandler(
    file_path::AbstractString,
    varname::AbstractString,
    target_space::ClimaCore.Spaces.AbstractSpace;
    reference_date::Dates.DateTime = Dates.DateTime(1979, 1, 1),
    t_start::AbstractFloat = 0.0,
    regridder_type = nothing,
)

    # Determine which regridder to use if not already specified
    regridder_type =
        isnothing(regridder_type) ? Regridders.default_regridder_type() :
        regridder_type

    # File reader, deals with ingesting data, possibly buffered/cached
    file_reader = NCFileReader(file_path, varname)

    regridder_args = ()

    if regridder_type == :TempestRegridder
        # If we do not have a regrid_dir, create one and broadcast it to all the MPI
        # processes
        context = ClimaComms.context(target_space)
        regrid_dir = ClimaComms.iamroot(context) ? mktempdir() : ""
        regrid_dir = ClimaComms.bcast(context, regrid_dir)
        ClimaComms.barrier(context)

        regridder_args = (target_space, regrid_dir, varname, file_path)
    elseif regridder_type == :InterpolationsRegridder
        regridder_args = (target_space,)
    end

    RegridderConstructor = getfield(Regridders, regridder_type)
    regridder = RegridderConstructor(regridder_args...)

    # NOTE: this is not concretely typed
    _cached_regridded_fields = Dict{Dates.DateTime, ClimaCore.Fields.Field}()

    available_dates = file_reader.available_dates
    # Second() is required to convert from DateTime to float. Also, Second(1) transforms
    # from milliseconds to seconds.
    times_s = Second.(available_dates .- reference_date) ./ Second(1)
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
    time_to_date(data_handler::DataHandler, time::AbstractFloat)

Convert the given time to a calendar date.

```
date = reference_date + t_start + time
```
"""
function time_to_date(data_handler::DataHandler, time::AbstractFloat)
    return data_handler.reference_date +
           Second(data_handler.t_start) +
           Second(time)
end

"""
    previous_time(data_handler::DataHandler, time::AbstractFloat)
    previous_time(data_handler::DataHandler, date::Dates.DateTime)

Return the time in seconds of the snapshot before the given `time`.
If `time` is one of the snapshots, return itself.
"""
function DataHandling.previous_time(
    data_handler::DataHandler,
    time::AbstractFloat,
)
    date = time_to_date(data_handler, time)
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
    return data_handler.available_times[index]
end

"""
    next_time(data_handler::DataHandler, time::AbstractFloat)
    next_time(data_handler::DataHandler, date::Dates.DateTime)

Return the time in seconds of the snapshot after the given `time`.
If `time` is one of the snapshots, return the next time.
"""
function DataHandling.next_time(data_handler::DataHandler, time::AbstractFloat)
    date = time_to_date(data_handler, time)
    return DataHandling.next_time(data_handler, date)
end

function DataHandling.next_time(data_handler::DataHandler, date::Dates.DateTime)
    # We have to handle separately what happens when we are on the node
    if date in data_handler.available_dates
        index = searchsortedfirst(data_handler.available_dates, date) + 1
    else
        index = searchsortedfirst(data_handler.available_dates, date)
    end
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

TODO: Add `regridded_snapshot!`
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
    date = time_to_date(data_handler, time)
    return DataHandling.regridded_snapshot(data_handler, date)
end

function DataHandling.regridded_snapshot(data_handler::DataHandler)
    # This function can be called only when there are no dates (ie, the dataset is static)
    isempty(data_handler.available_dates) ||
        error("DataHandler is function of time")

    # In this case, we use as cache key Dates.DateTime(0)
    return DataHandling.regridded_snapshot(data_handler, Dates.DateTime(0))
end

end
