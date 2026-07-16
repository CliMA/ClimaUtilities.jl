module DataHandlingExt

import Dates
import Dates: Second

import ClimaCore
import ClimaCore: ClimaComms

import NCDatasets

import ClimaUtilities.DataStructures
import ClimaUtilities.Regridders
import ClimaUtilities.FileReaders:
    AbstractFileReader, NCFileReader, MultiColumnNCFileReader, read, read!
import ClimaUtilities.Regridders: AbstractRegridder, regrid

import ClimaUtilities.Utils: isequispaced, period_to_seconds_float

import ClimaUtilities.DataHandling

"""
    AbstractDataHandler

Defines how to handle data from datasets and spatially interpolate them to
`ClimaCore.Fields.Field`. Structs of this type do not interpolate temporally.

The methods that only do time bookkeeping (`available_times`, `available_dates`,
`previous_time`, `next_time`, `previous_date`, `next_date`, `dt`, `time_to_date`,
`date_to_time`, and `close`) are implemented once on this abstract type and access the
fields of the handler directly. Hence, every struct of this type must implement
`regridded_snapshot(dh::YourDataHandler, date::Dates.DateTime)` and have the fields
`file_readers`, `available_times`, `available_dates`, and `start_date`.
"""
abstract type AbstractDataHandler end

"""
    DataHandler{
         FR <: AbstractDict{<:AbstractString, <:AbstractFileReader},
         REG <: AbstractRegridder,
         SPACE <: ClimaCore.Spaces.AbstractSpace,
         DATES <: AbstractArray{Dates.DateTime},
         DIMS,
         TIMES <: AbstractArray{<:AbstractFloat},
         CACHE <: DataStructures.LRUCache{Dates.DateTime, ClimaCore.Fields.Field},
         FUNC <: Function,
     }

Currently, the `DataHandler` remaps one variable at the time. This might not be the most
efficiently way to tackle the problem: we should be able to reuse the interpolation weights if
multiple variables are defined on the same grid and have to be remapped to the same grid.

Multiple input variables may be stored in the `DataHandler` by providing a dictionary
`file_readers` of variable names mapped to `FileReader` objects, along with a `compose_function`
that combines them into a single data variable. This is useful when we require variables
that are not directly available in the input data, but can be computed from the available variables.
The order of the variables in `varnames` must match the argument order of `compose_function`.

Assumptions:
- For each input variable, there is only one file with the entire time development of the given variable
- The file has well-defined physical dimensions (e.g., lat/lon)
- Currently, the time dimension has to be either "time" or "date", the spatial
  dimensions have to be lat and lon (restriction from TempestRegridder)
- If using multiple input variables, the input variables must have the same time development
  and spatial resolution

DataHandler is meant to live on the CPU, but the Fields can be on the GPU as well.
"""
struct DataHandler{
    FR <: AbstractDict{<:AbstractString, <:AbstractFileReader},
    REG <: AbstractRegridder,
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    DATES <: AbstractArray{Dates.DateTime},
    DIMS,
    TIMES <: AbstractArray{<:AbstractFloat},
    CACHE <: DataStructures.LRUCache{Dates.DateTime, ClimaCore.Fields.Field},
    FUNC <: Function,
    NAMES <: AbstractArray{<:AbstractString},
    PR <: AbstractDict{<:AbstractString, <:AbstractArray},
} <: AbstractDataHandler
    """Dictionary of variable names and objects responsible for getting the input data from disk to memory"""
    file_readers::FR

    """Object responsible for resampling a rectangular grid to the simulation grid"""
    regridder::REG

    """ClimaCore Space over which the data has to be resampled"""
    target_space::SPACE

    """Tuple of linear arrays where the data is defined (typically long/lat)"""
    dimensions::DIMS

    """Calendar dates over which the data is defined"""
    available_dates::DATES

    """Reference calendar date at the beginning of the simulation."""
    start_date::Dates.DateTime

    """Timesteps over which the data is defined (in seconds)"""
    available_times::TIMES

    """Private field where cached data is stored"""
    _cached_regridded_fields::CACHE

    """Function to combine multiple input variables into a single data variable"""
    compose_function::FUNC

    """Names of the datasets in the NetCDF that have to be read and processed"""
    varnames::NAMES

    """Preallocated memory for storing read dataset"""
    preallocated_read_data::PR
end


"""
    _check_file_paths_varnames(file_paths, varnames, regridder_type, compose_function)

Check consistency of `file_paths`, `varnames`, `regridder_type`, and `compose_function` for
our current `DataHandler`.
"""
function _check_file_paths_varnames(
    file_paths,
    varnames,
    regridder_type,
    compose_function,
)
    # Verify that the number of file paths and variable names are consistent
    if length(varnames) == 1
        # Multiple files are not supported by TempestRegridder
        (length(file_paths) > 1 && regridder_type == :TempestRegridder) &&
            error("TempestRegridder does not support multiple input files")
    else
        # We have multiple variables
        # This is not supported by TempestRegridder
        regridder_type == :TempestRegridder &&
            error("TempestRegridder does not support multiple input variables")

        # We need a compose_function when passed multiple variables
        compose_function == identity && error(
            "`compose_function` must be specified when using multiple input variables",
        )
    end
end

"""
    DataHandler(file_paths,
                varnames,
                target_space::ClimaCore.Spaces.AbstractSpace;
                start_date::Dates.DateTime = Dates.DateTime(1979, 1, 1),
                regridder_type = nothing,
                cache_max_size::Int = 2,
                regridder_kwargs = (),
                file_reader_kwargs = ())

Create a `DataHandler` to read `varnames` from `file_paths` and remap them to `target_space`.

This function supports reading across multiple files and composing variables that are in
different files.


`file_paths` may contain either one path for all variables or one path for each variable. In
the latter case, the entries of `file_paths` and `varnames` are expected to match based on
position.

The DataHandler maintains an LRU cache of Fields that were previously computed. The default
size for the cache is only two fields, so if you expect to re-use the same fields often,
increasing the cache size can lead to improved performances.

Creating this object results in the file being accessed (to preallocate some memory).

Positional arguments
=====================

- `file_paths`: Paths of the NetCDF file(s) that contain the input data. `file_paths` should
  be as "do-what-I-mean" as possible, meaning that it should behave as you expect.

  To be specific, there are three options for `file_paths`:
  - It is a string that points to a single NetCDF file.
  - It is a list that points to multiple NetCDF files. In this case, we support two modes:
    1. if `varnames` is a vector with the number of entries as `file_paths`, we assume that
       each file contains a different variable.
    2. otherwise, we assume that each file contains all the variables and is temporal chunk.
  - It is a list of lists of paths to NetCDF files, where the inner list identifies temporal
    chunks of a given variable, and the outer list identifies different variables
    (supporting the mode where different variables live in different files and their time
    development is split across multiple files). In other words, `file_paths[i]` is the list
    of files that define the temporal evolution of `varnames[i]`

- `varnames`: Names of the datasets in the NetCDF that have to be read and processed.
- `target_space`: Space where the simulation is run, where the data has to be regridded to.

Keyword arguments
===================

Time/date information will be ignored for static input files. (They are still set to make
everything more type stable.)

- `start_date`: Calendar date corresponding to the start of the simulation.
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
- `compose_function`: Function to combine multiple input variables into a single data
                      variable. The default, to be used in the case of one input variable,
                      is the identity. The compose function has to take N arguments, where
                      N is the number of variables in `varnames`, and return a scalar.
                      The order of the arguments in `compose_function` has to match the order
                      of `varnames`. This function will be broadcasted to data read from file.
"""
function DataHandling.DataHandler(
    file_paths,
    varnames,
    target_space::ClimaCore.Spaces.AbstractSpace;
    start_date::Union{Dates.DateTime, Dates.Date} = Dates.DateTime(1979, 1, 1),
    regridder_type = nothing,
    cache_max_size::Int = 2,
    regridder_kwargs = (),
    file_reader_kwargs = (),
    compose_function = identity,
    ########### DEPRECATED ###############
    reference_date = nothing,
    t_start = nothing,
    ########### DEPRECATED ###############
)
    ########### DEPRECATED ###############
    if !isnothing(reference_date)
        start_date = reference_date
        Base.depwarn(
            "The keyword argument `reference_date` is deprecated. Use `start_date` instead.",
            :DataHandler,
        )
    end
    if !isnothing(t_start)
        Base.depwarn(
            "`t_start` is deprecated and will be ignored",
            :DataHandler,
        )
    end
    ########### DEPRECATED ###############

    # Convert `file_paths` and `varnames` to arrays if they are not already
    # After this point, we assume that `file_paths` and `varnames` are arrays, possibly with only one element
    if file_paths isa AbstractString
        file_paths = [file_paths]
    end
    if varnames isa AbstractString
        varnames = [varnames]
    end

    # Determine which regridder to use if not already specified
    regridder_type =
        isnothing(regridder_type) ? Regridders.default_regridder_type() :
        regridder_type

    _check_file_paths_varnames(
        file_paths,
        varnames,
        regridder_type,
        compose_function,
    )

    # We have to deal with the case with have 1 FileReader (with possibly multiple files),
    # or with N FileReaders (for when variables are split across files, and with possibly
    # multiple files). To accommodate all these cases, we cast everything into the format
    # where we have a list of lists, where the outer list is along variable names, and the
    # inner list is along times. This is the most general input we expect from this
    # constructor.

    is_file_paths_list_of_lists = !(first(file_paths) isa AbstractString)

    if !is_file_paths_list_of_lists
        # If is_file_paths_list_of_lists not already a list of lists, we have two options:
        # 1. file_paths identifies the temporal development of the variables
        # 2. file_paths identifies different variables

        # We use as heuristic that when the number of files provided is the same as the
        # number of variables, that means that the files include different variables
        if length(file_paths) == length(varnames)
            # One file per variable
            file_paths = [[f] for f in file_paths]
        else
            # Every file per every variable
            file_paths = [copy(file_paths) for _ in varnames]
        end
    end
    # Now, we have a list of lists, where file_paths[i] is the list of files that define the
    # temporal evolution of varnames[i]

    # Construct the file readers, which deals with ingesting data and is possibly
    # buffered/cached, for each variable
    file_readers = Dict(
        varname => NCFileReader(paths, varname; file_reader_kwargs...) for
        (paths, varname) in zip(file_paths, varnames)
    )

    # Verify that the spatial dimensions are the same for each variable
    @assert length(
        Set(file_reader.dimensions for file_reader in values(file_readers)),
    ) == 1

    # Verify that the time information is the same for all variables
    @assert length(
        Set(
            file_reader.available_dates for file_reader in values(file_readers)
        ),
    ) == 1
    @assert length(
        Set(file_reader.time_index for file_reader in values(file_readers)),
    ) == 1

    # Note: using one arbitrary element of `file_readers` assumes
    #  that all input variables have the same time development
    available_dates = first(values(file_readers)).available_dates
    available_times = period_to_seconds_float.(available_dates .- start_date)
    dimensions = first(values(file_readers)).dimensions
    dim_names = first(values(file_readers)).dim_names
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

        # Note: using one arbitrary element of `varnames` and of `file_paths`
        # assumes that all input variables will use the same regridding (there
        # are two firsts in file_paths because we now have a list of lists)
        regridder_args =
            (target_space, first(varnames), first(first(file_paths)))
    elseif regridder_type == :InterpolationsRegridder
        # Check if the dimensions are monotonically increasing or decreasing
        # if monotonically decreasing, we need to reverse the data before regridding
        # Ideally, this should be done when the data is preprocessed
        dim_increasing = map(dimensions, dim_names) do dim, dim_name
            @assert issorted(dim) || issorted(dim, rev = true) "dimension $dim_name is neither monotonically increasing nor decreasing"
            issorted(dim) ? true : false
        end

        # Verify that dim_increasing and dim_names have matching orderings
        # This ensures that dim_increasing[i] corresponds to dim_names[i] and dimensions[i]
        @assert length(dim_increasing) == length(dim_names) "dim_increasing and dim_names must have the same length. Got dim_increasing with length $(length(dim_increasing)) and dim_names with length $(length(dim_names))"

        # Additional validation: verify that dim_increasing order matches the actual dimension sorting behavior
        for (i, (dim_name, increasing_flag, dim)) in
            enumerate(zip(dim_names, dim_increasing, dimensions))
            expected_increasing = issorted(dim)
            if increasing_flag != expected_increasing
                error(
                    "Detected mismatch in dimension ordering: dim_names[$i]=\"$dim_name\" but dim_increasing[$i]=$increasing_flag does not match actual sorting of dimensions[$i] (expected $expected_increasing). " *
                    "This indicates a potential bug in DataHandler construction where dim_names and dimensions are not in the same order.",
                )
            end
        end

        regridder_args = (target_space,)
        regridder_kwargs =
            merge((; dim_increasing, dim_names), regridder_kwargs)
    end

    RegridderConstructor = getfield(Regridders, regridder_type)
    regridder = RegridderConstructor(regridder_args...; regridder_kwargs...)

    # Use an LRU cache to store regridded fields
    _cached_regridded_fields =
        DataStructures.LRUCache{Dates.DateTime, ClimaCore.Fields.Field}(
            max_size = cache_max_size,
        )


    # Preallocate space for each variable to be read
    one_date = isempty(available_dates) ? () : (first(available_dates),)
    preallocated_read_data = Dict(
        varname => read(file_readers[varname], one_date...) for
        varname in varnames
    )

    return DataHandler(
        file_readers,
        regridder,
        target_space,
        dimensions,
        available_dates,
        Dates.DateTime(start_date),
        available_times,
        _cached_regridded_fields,
        compose_function,
        varnames,
        preallocated_read_data,
    )
end

"""
    close(data_handler::AbstractDataHandler)

Close all files associated to the given `data_handler`.
"""
function Base.close(data_handler::AbstractDataHandler)
    foreach(close, values(data_handler.file_readers))
    return nothing
end

"""
    available_times(data_handler::AbstractDataHandler)

Return the time in seconds of the snapshots in the data, measured considering
the starting time of the simulation and the reference date
"""
function DataHandling.available_times(data_handler::AbstractDataHandler)
    return data_handler.available_times
end

"""
    available_dates(data_handler::AbstractDataHandler)

Return the dates of the snapshots in the data.
"""
function DataHandling.available_dates(data_handler::AbstractDataHandler)
    return data_handler.available_dates
end

"""
    dt(data_handler::AbstractDataHandler)

Return the time interval between data points for the data in `data_handler`.

This requires the data to be defined on a equispaced temporal mesh.
"""
function DataHandling.dt(data_handler::AbstractDataHandler)
    isequispaced(DataHandling.available_times(data_handler)) ||
        error("dt not defined for non equispaced data")
    return DataHandling.available_times(data_handler)[begin + 1] -
           DataHandling.available_times(data_handler)[begin]
end


"""
    time_to_date(data_handler::AbstractDataHandler, time::AbstractFloat)

Convert the given time to a calendar date.

```
date = start_date + time
```
"""
function DataHandling.time_to_date(
    data_handler::AbstractDataHandler,
    time::AbstractFloat,
)
    # We go through milliseconds to allow fractions of a second (otherwise, Second(0.8)
    # would fail). Milliseconds is the level of resolution that one gets when taking the
    # difference between two DateTimes. In addition to this, we add a round to account for
    # floating point errors. If the floating point error is small enough, round will correct
    # it.
    time_ms = Dates.Millisecond(round(1_000 * time))
    return data_handler.start_date + time_ms
end

"""
    date_to_time(data_handler::AbstractDataHandler, time::AbstractFloat)

Convert the given calendar date to a time (in seconds).

```
date = start_date + time
```
"""
function DataHandling.date_to_time(
    data_handler::AbstractDataHandler,
    date::Dates.DateTime,
)
    return period_to_seconds_float(date - data_handler.start_date)
end

"""
    previous_time(data_handler::AbstractDataHandler, time::AbstractFloat)
    previous_time(data_handler::AbstractDataHandler, date::Dates.DateTime)

Return the time in seconds of the snapshot before the given `time`.
If `time` is one of the snapshots, return itself.

If `time` is not in the `data_handler`, return an error.
"""
function DataHandling.previous_time(
    data_handler::AbstractDataHandler,
    time::AbstractFloat,
)
    date = DataHandling.time_to_date(data_handler, time)
    return DataHandling.previous_time(data_handler, date)
end

function DataHandling.previous_time(
    data_handler::AbstractDataHandler,
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
    next_time(data_handler::AbstractDataHandler, time::AbstractFloat)
    next_time(data_handler::AbstractDataHandler, date::Dates.DateTime)

Return the time in seconds of the snapshot after the given `time`.
If `time` is one of the snapshots, return the next time.

If `time` is not in the `data_handler`, return an error.
"""
function DataHandling.next_time(
    data_handler::AbstractDataHandler,
    time::AbstractFloat,
)
    date = DataHandling.time_to_date(data_handler, time)
    return DataHandling.next_time(data_handler, date)
end

function DataHandling.next_time(
    data_handler::AbstractDataHandler,
    date::Dates.DateTime,
)
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
    DataHandling.previous_date(data_handler::AbstractDataHandler, time::Dates.TimeType)

Return the date of the snapshot before the given `date`.
If `date` is one of the snapshots, return itself.

If `date` is not in the `data_handler`, return an error.
"""
function DataHandling.previous_date(
    data_handler::AbstractDataHandler,
    date::Dates.TimeType,
)
    if date in data_handler.available_dates
        index = searchsortedfirst(data_handler.available_dates, date)
    else
        index = searchsortedfirst(data_handler.available_dates, date) - 1
    end
    index < 1 && error("Date $date is before available dates")
    return data_handler.available_dates[index]
end

"""
    DataHandling.next_date(data_handler::AbstractDataHandler, time::Dates.TimeType)

Return the date of the snapshot after the given `time`.
If `date` is one of the snapshots, return itself.

If `date` is not in the `data_handler`, return an error.
"""
function DataHandling.next_date(
    data_handler::AbstractDataHandler,
    date::Dates.TimeType,
)
    if date in data_handler.available_dates
        index = searchsortedfirst(data_handler.available_dates, date) + 1
    else
        index = searchsortedfirst(data_handler.available_dates, date)
    end
    index > length(data_handler.available_dates) &&
        error("Date $date is after available dates")
    return data_handler.available_dates[index]
end

"""
    regridded_snapshot(data_handler::AbstractDataHandler, date::Dates.DateTime)
    regridded_snapshot(data_handler::AbstractDataHandler, time::AbstractFloat)
    regridded_snapshot(data_handler::AbstractDataHandler)

Return the regridded snapshot from `data_handler` associated to the given `time` (if relevant).

The `time` has to be available in the `data_handler`.

When using multiple input variables, the `varnames` argument determines the order of arguments
to the `compose_function` function used to produce the data variable.

`regridded_snapshot` potentially modifies the internal state of `data_handler` and it might be a very
expensive operation.
"""
function DataHandling.regridded_snapshot(
    data_handler::DataHandler,
    date::Dates.DateTime,
)
    varnames = data_handler.varnames
    compose_function = data_handler.compose_function

    # Dates.DateTime(0) is the cache key for static maps
    if date != Dates.DateTime(0)
        file_paths = data_handler.file_readers[first(varnames)].file_paths
        date in data_handler.available_dates ||
            error("Date $date not available in files $(file_paths)")
    end

    regridder_type = nameof(typeof(data_handler.regridder))

    # Check if the regridded field at this date is already in the cache
    return get!(data_handler._cached_regridded_fields, date) do
        if regridder_type == :TempestRegridder
            if length(data_handler.file_readers) > 1
                error(
                    "TempestRegridder does not support multiple input variables. Please use InterpolationsRegridder.",
                )
            else
                regrid_args = (date,)
            end
        elseif regridder_type == :InterpolationsRegridder

            # Read input data from each file, maintaining order, and apply composing function
            # In the case of a single input variable, it will remain unchanged
            for varname in varnames
                read!(
                    data_handler.preallocated_read_data[varname],
                    data_handler.file_readers[varname],
                    date,
                )
            end
            data_composed = compose_function(
                (
                    data_handler.preallocated_read_data[varname] for
                    varname in varnames
                )...,
            )
            regrid_args = (data_composed, data_handler.dimensions)
        else
            error("Invalid regridder type")
        end
        regrid(data_handler.regridder, regrid_args...)
    end
end

function DataHandling.regridded_snapshot(
    data_handler::AbstractDataHandler,
    time::AbstractFloat,
)
    date = DataHandling.time_to_date(data_handler, time)
    return DataHandling.regridded_snapshot(data_handler, date)
end

function DataHandling.regridded_snapshot(data_handler::AbstractDataHandler)
    # This function can be called only when there are no dates (ie, the dataset is static)
    isempty(data_handler.available_dates) ||
        error("DataHandler is function of time")

    # In this case, we use as cache key `Dates.DateTime(0)`
    return DataHandling.regridded_snapshot(data_handler, Dates.DateTime(0))
end

"""
    regridded_snapshot!(dest::ClimaCore.Fields.Field, data_handler::DataHandler, date::Dates.DateTime)

Write to `dest` the regridded snapshot from `data_handler` associated to the given `time`.

The `time` has to be available in the `data_handler`.

`regridded_snapshot!` potentially modifies the internal state of `data_handler` and it might be a very
expensive operation.
"""
function DataHandling.regridded_snapshot!(dest, data_handler, time)
    dest .= DataHandling.regridded_snapshot(data_handler, time)
    return nothing
end


"""
    MultiColumnDataHandler

A data handler that reads and remaps data column-by-column onto a multi-column
space. Mirrors `DataHandler`, but keeps the horizontal and vertical dimensions
separate (there is no horizontal interpolation; only the vertical is regridded).
"""
struct MultiColumnDataHandler{
    FR <: AbstractDict{<:AbstractString, <:AbstractFileReader},
    REG <: AbstractRegridder,
    SPACE <: ClimaCore.Spaces.AbstractSpace,
    HDIMS,
    VDIM,
    DATES <: AbstractArray{Dates.DateTime},
    TIMES <: AbstractArray{<:AbstractFloat},
    CACHE <: DataStructures.LRUCache{Dates.DateTime, ClimaCore.Fields.Field},
    FUNC <: Function,
    NAMES <: AbstractArray{<:AbstractString},
    PR <: AbstractDict{<:AbstractString, <:AbstractArray},
} <: AbstractDataHandler
    """Dictionary of variable names and objects responsible for getting the input data from disk to memory"""
    file_readers::FR

    """Object responsible for resampling the column data to the simulation grid"""
    regridder::REG

    """ClimaCore Space over which the data has to be resampled"""
    target_space::SPACE

    """Tuple of per-column horizontal coordinates (e.g., (lons, lats))"""
    horizontal_dimensions::HDIMS

    """Per-column vertical levels (e.g., zs), empty when there is no z dimension"""
    vertical_dimension::VDIM

    """Calendar dates over which the data is defined"""
    available_dates::DATES

    """Reference calendar date at the beginning of the simulation."""
    start_date::Dates.DateTime

    """Timesteps over which the data is defined (in seconds)"""
    available_times::TIMES

    """Private field where cached regridded fields are stored"""
    _cached_regridded_fields::CACHE

    """Function to combine multiple input variables into a single data variable"""
    compose_function::FUNC

    """Names of the datasets in the NetCDF that have to be read and processed"""
    varnames::NAMES

    """Preallocated memory for storing read dataset"""
    preallocated_read_data::PR
end

"""
    MultiColumnDataHandler(dataset_sources,
                           target_space::ClimaCore.Spaces.AbstractSpace;
                           start_date::Union{Dates.DateTime, Dates.Date} = Dates.DateTime(1979, 1, 1),
                           cache_max_size::Int = 2,
                           compose_function = identity,
                           file_reader_kwargs = (),
                           regridder_kwargs = (),
                           atol = 1e-3)

Create a `MultiColumnDataHandler` from `dataset_sources` and remap them onto
`target_space` column-by-column.

Creating this object results in the files being accessed (to preallocate some memory).

Within each variable, only the dates common to all of that variable's columns
are considered (their intersection). Across variables, the available dates must
be identical.

Positional arguments
=====================

- `dataset_sources`: a vector of vectors of `DataSource`, where the outer vector
  represents the variable and each inner vector represent that variable's
  columns. A single `DataSource` or a vector of `DataSource` is also accepted
  and treated as one variable. Each variable's columns are matched to
  `target_space` by location. Columns not needed by the target space are
  ignored.
- `target_space`: the `ClimaCore` space to remap onto. Its horizontal space must be a
  `PointCloudSpace`.

Keyword arguments
=================

- `start_date`: reference date for the numeric time axis.
- `cache_max_size`: size of the LRU cache of regridded `Field`s.
- `compose_function`: combine multiple input variables into one (required when
  there is more than one variable). The ordering of `dataset_sources` determines
  the ordering of the arguments to the `compose_function`.
- `file_reader_kwargs`: forwarded to each `MultiColumnNCFileReader`.
- `regridder_kwargs`: forwarded to the `ColumnRegridder` constructor (e.g.
  `order` or `extrapolate`).
- `atol`: absolute tolerance (in degrees) used to match each column's
  (lon, lat) location to the columns of `target_space`.
"""
function DataHandling.MultiColumnDataHandler(
    dataset_sources,
    target_space::ClimaCore.Spaces.AbstractSpace;
    start_date::Union{Dates.DateTime, Dates.Date} = Dates.DateTime(1979, 1, 1),
    cache_max_size::Int = 2,
    compose_function = identity,
    file_reader_kwargs = (),
    regridder_kwargs = (),
    atol = 1e-3,
)
    is_point_cloud(target_space) || error(
        "There is only support for spaces whose horizontal space is a PointCloudSpace",
    )

    # Standardize to a vector of vectors, where the outer vector represents the
    # variables and the inner vectors represent each variable's columns. There
    # are three cases:
    # 1. A single DataSource: one variable with a single column
    # 2. A vector of DataSource: one variable with one or more columns
    # 3. A vector of vector of DataSource: multiple variables, each with one
    #    or more columns
    is_vector = x -> x isa AbstractVector
    is_vector(dataset_sources) || (dataset_sources = [dataset_sources])
    isempty(dataset_sources) &&
        error("At least one DataSource must be provided")
    if !any(is_vector, dataset_sources)
        # A vector of DataSource: a single variable
        dataset_sources = [dataset_sources]
    elseif !all(is_vector, dataset_sources)
        error(
            "For dataset_sources, pass a DataSource, a vector of DataSources, or a vector of vectors of DataSources",
        )
    end
    any(isempty, dataset_sources) &&
        error("Each variable must have at least one column")
    any(col -> any(is_vector, col), dataset_sources) && error(
        "Each inner vector of dataset_sources must contain only DataSources",
    )

    if length(dataset_sources) > 1 && compose_function == identity
        error(
            "`compose_function` must be specified when using multiple input variables",
        )
    end

    # We can rely on MultiColumnNCFileReader to check that the variable name is
    # consistent between the datasets
    readers = map(dataset_sources) do column_sources
        MultiColumnNCFileReader(
            _find_columns_for_space(column_sources, target_space; atol);
            file_reader_kwargs...,
        )
    end
    varnames = [reader.varname for reader in readers]
    allunique(varnames) || error(
        "Duplicate variable names across dataset_sources ($varnames); each variable must have a unique name",
    )
    file_readers = Dict(zip(varnames, readers))

    # The horizontal dimensions are already verified by constructing the file
    # readers, so we check that the vertical levels agree between the different
    # variables
    ref_vertical = first(values(file_readers)).vertical_dimension
    all(
        file_reader ->
            size(file_reader.vertical_dimension) == size(ref_vertical) &&
            isapprox(file_reader.vertical_dimension, ref_vertical),
        values(file_readers),
    ) || error("Variables have inconsistent vertical dimensions")

    # Dates carry no roundoff, so require them to match exactly across variables
    allequal(
        file_reader.available_dates for file_reader in values(file_readers)
    ) || error("Variables have inconsistent available dates")

    # Get all the relevant fields for the struct
    file_reader = first(values(file_readers))
    available_dates = file_reader.available_dates
    available_times =
        period_to_seconds_float.(available_dates .- Dates.DateTime(start_date))
    horizontal_dimensions = file_reader.horizontal_dimensions
    vertical_dimension = file_reader.vertical_dimension

    # The regridder stores the source vertical levels and validates them
    # (strictly increasing or decreasing, consistent direction across columns)
    regridder = Regridders.ColumnRegridder(
        target_space,
        vertical_dimension;
        regridder_kwargs...,
    )

    # Use LRU cache to store regridded fields
    _cached_regridded_fields =
        DataStructures.LRUCache{Dates.DateTime, ClimaCore.Fields.Field}(
            max_size = cache_max_size,
        )

    # Preallocate space for each variable to be read
    maybe_first_date = isempty(available_dates) ? () : (first(available_dates),)
    preallocated_read_data = Dict(
        varname => read(file_readers[varname], maybe_first_date...) for
        varname in varnames
    )

    return MultiColumnDataHandler(
        file_readers,
        regridder,
        target_space,
        horizontal_dimensions,
        vertical_dimension,
        available_dates,
        Dates.DateTime(start_date),
        available_times,
        _cached_regridded_fields,
        compose_function,
        varnames,
        preallocated_read_data,
    )
end

"""
    is_point_cloud(space::ClimaCore.Spaces.AbstractSpace)

Return true if the horizontal part of the `space` is a `PointCloudSpace`.

This is used in the constructor for a `MultiColumnDataHandler` since that struct
currently only supports spaces whose horizontal spaces are
`PointCloudSpace`.
"""
is_point_cloud(space::ClimaCore.Spaces.AbstractSpace) =
    ClimaCore.Spaces.horizontal_space(space) isa
    ClimaCore.Spaces.PointCloudSpace
is_point_cloud(::ClimaCore.Spaces.PointCloudSpace) = true
is_point_cloud(::ClimaCore.Spaces.AbstractPointSpace) = false

"""
    _find_columns_for_space(file_sources, target_space; atol = 1e-3)

Return the columns corresponding to the datasets in `file_sources` where each
column of `target_space` correspond to a dataset in `file_sources`.
"""
function _find_columns_for_space(file_sources, target_space; atol = 1e-3)
    # For CLiMA, longitudes range from -180 to 180. For some external datasets,
    # longitudes range from 0 to 360. Applying this function to longitudes
    # ranging from -180 to 180 is a no-op, but to longitudes ranging from
    # 0 to 360 shifts them to -180 to 180. Both the space and the file
    # longitudes are wrapped so the two are compared in the same convention.
    # This function is copied from ClimaAnalysis.shift_longitude
    wrap_longitude(lon, lower_lon, upper_lon) =
        (lon >= upper_lon) || (lon < lower_lon) ?
        mod1(lon - lower_lon, upper_lon - lower_lon) + lower_lon : lon
    wrap_longitude(lon) = wrap_longitude(lon, -180, 180)

    # `field2array` either return an array of size Nz x Ncolumn or a vector of
    # size Ncolumn
    coords = ClimaCore.Fields.coordinate_field(target_space)
    first_level(a) = ndims(a) == 1 ? a : a[1, :]
    space_lons = wrap_longitude.(
        first_level(Array(ClimaCore.Fields.field2array(coords.long))),
    )
    space_lats = first_level(Array(ClimaCore.Fields.field2array(coords.lat)))
    n_space_cols = length(space_lats)

    # Find the longitude and latitude of each column of the datasets
    col_lons = zeros(length(file_sources))
    col_lats = zeros(length(file_sources))
    for (j, source) in enumerate(file_sources)
        first_file = first(source.file_paths)
        (
            haskey(source.coord_names, :lon) &&
            haskey(source.coord_names, :lat)
        ) || error(
            "No longitude/latitude variables identified in $first_file. Pass `coord_names` to DataSource or check that the dataset have a longitude and latitude coordinate",
        )
        col_lons[j], col_lats[j] = NCDatasets.NCDataset(first_file) do ds
            lon_values = ds[source.coord_names.lon][:]
            lat_values = ds[source.coord_names.lat][:]
            (length(lon_values) == 1 && length(lat_values) == 1) || error(
                "Expected a single (lon, lat) location in $first_file, found $(length(lon_values)) longitudes and $(length(lat_values)) latitudes; only single-column files are supported",
            )
            (wrap_longitude(only(lon_values)), only(lat_values))
        end
    end

    targets = map(1:n_space_cols) do i
        matches = findall(
            j ->
                isapprox(col_lons[j], space_lons[i]; atol) &&
                isapprox(col_lats[j], space_lats[i]; atol),
            eachindex(file_sources),
        )
        isempty(matches) && error(
            "No column matches target space column $i at (lon, lat) = ($(space_lons[i]), $(space_lats[i]))",
        )
        length(matches) == 1 || error(
            "Multiple columns ($matches) match target space column $i at (lon, lat) = ($(space_lons[i]), $(space_lats[i])); locations may be closer than `atol` = $atol",
        )
        only(matches)
    end

    return file_sources[targets]
end

"""
    regridded_snapshot(data_handler::MultiColumnDataHandler, date::Dates.DateTime)
    regridded_snapshot(data_handler::MultiColumnDataHandler, time::AbstractFloat)
    regridded_snapshot(data_handler::MultiColumnDataHandler)

Return the regridded snapshot associated to the given `time`/`date` (if relevant).
"""
function DataHandling.regridded_snapshot(
    data_handler::MultiColumnDataHandler,
    date::Dates.DateTime,
)
    varnames = data_handler.varnames
    compose_function = data_handler.compose_function

    # Dates.DateTime(0) is the cache key for static maps
    if date != Dates.DateTime(0)
        file_paths = data_handler.file_readers[first(varnames)].file_paths
        date in data_handler.available_dates ||
            error("Date $date not available in files $(file_paths)")
    end

    return get!(data_handler._cached_regridded_fields, date) do
        for varname in varnames
            read!(
                data_handler.preallocated_read_data[varname],
                data_handler.file_readers[varname],
                date,
            )
        end
        data_composed = compose_function(
            (
                data_handler.preallocated_read_data[varname] for
                varname in varnames
            )...,
        )
        regrid(data_handler.regridder, data_composed)
    end
end

end
