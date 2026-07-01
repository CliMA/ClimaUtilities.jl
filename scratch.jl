import ClimaUtilities.FileReaders
import NCDatasets

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

# `close` -> releases each column's NetCDF dataset
close(multi_cols_reader)
