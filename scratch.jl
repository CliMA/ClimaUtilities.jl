import ClimaUtilities.FileReaders
import ClimaUtilities.DataHandling
import NCDatasets
import ClimaCore
import ClimaCore.CommonSpaces: PointColumnEnsembleSpace, CellCenter
import ClimaCore.Geometry: LatLongPoint

filepaths = readdir("callmip_phase1_forcing", join = true)

multi_cols_reader = FileReaders.MultiColumnNCFileReader(
    filepaths,
    "LAI",
    preprocess_func = identity,
    cache_size = 128,
)

dates = FileReaders.available_dates(multi_cols_reader)
@show length(dates)
@show first(dates), last(dates)

date = first(dates)
data = FileReaders.read(multi_cols_reader, date)
@show data
@show size(data)

data_again = FileReaders.read(multi_cols_reader, date)
@show data_again == data

# `read!(dest, reader, date)` -> in-place read into a preallocated buffer
dest = similar(data)
FileReaders.read!(dest, multi_cols_reader, date)
@show dest == data

lons, lats = multi_cols_reader.horizontal_dimensions
points =
    [LatLongPoint(Float64(lat), Float64(lon)) for (lon, lat) in zip(lons, lats)]

space = PointColumnEnsembleSpace(;
    points = points,
    z_elem = 10,
    z_min = 0.0,
    z_max = 10.0,
    staggering = CellCenter(),
)

level_space = ClimaCore.level(space, 1)

# `close` -> releases each column's NetCDF dataset. We close the standalone
# reader before building the DataHandler below, since both open the same files
# and share entries in `OPEN_NCFILES`.
close(multi_cols_reader)

# Build a MultiColumnDataHandler for LAI, remapped onto the column-ensemble
# space. Each column file is matched to the space's columns by (lon, lat).
data_handler = DataHandling.MultiColumnDataHandler(filepaths, "LAI", level_space)
@show data_handler.varnames
@show length(data_handler.available_dates)
@show keys(data_handler.file_readers)

@show DataHandling.available_times(data_handler)
@show DataHandling.available_dates(data_handler)
@show DataHandling.dt(data_handler)

time = first(DataHandling.available_times(data_handler))
@show DataHandling.time_to_date(data_handler, time)
@show DataHandling.date_to_time(data_handler, date)

@show DataHandling.previous_time(data_handler, date)
@show DataHandling.next_time(data_handler, date)
@show DataHandling.previous_date(data_handler, date)
@show DataHandling.next_date(data_handler, date)

@show DataHandling.regridded_snapshot(data_handler, date)
@show DataHandling.regridded_snapshot(data_handler, time)

field = zeros(level_space)
DataHandling.regridded_snapshot!(field, data_handler, date)
@show field

close(data_handler)
