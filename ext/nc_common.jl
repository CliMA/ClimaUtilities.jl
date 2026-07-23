# Names a temporal dimension might have in a NetCDF file
const TIME_NAMES = ("time", "date", "t", "valid_time")

# Names a coordinate variable might have in a NetCDF file
const COORD_NAMES = (;
    lon = ("longitude", "lon", "long"),
    lat = ("latitude", "lat"),
    z = ("z", "lev", "level", "height", "altitude"),
)

# For a single and multi-file dataset
const NetCDFDataset =
    Union{NCDatasets.NCDataset, NCDatasets.CommonDataModel.MFDataset}

"""
    read_available_dates(ds::NCDatasets.NCDataset)

Return all the dates in the given NCDataset. The dates are read from the "time",
"t", "valid_time", or "date" datasets (checked in that order). If none is
available, return an empty vector.
"""
function read_available_dates(ds::NetCDFDataset)
    # Check for time dimensions in order of preference
    for time_dim in TIME_NAMES
        # "date" holds integer yyyymmdd values and is parsed separately below
        time_dim == "date" && continue
        if time_dim in keys(ds.dim)
            # NCDatasets.jl uses CFTime.jl, which supports a time resolution of
            # an attosecond, whereas Dates.DateTime only supports a time
            # resolution of a millisecond.
            return reinterpret.(Ref(Dates.DateTime), ds[time_dim][:])
        end
    end
    if "date" in keys(ds.dim)
        return Dates.DateTime.(string.(ds["date"][:]), Ref("yyyymmdd"))
    else
        return Dates.DateTime[]
    end
end

"""
    detect_coord_names(ds::NetCDFDataset, file_paths)

Identify the coordinate variables in `ds` by matching its variable names
case-insensitively against the candidates in `COORD_NAMES` and return the result
as a `NamedTuple`.
"""
function detect_coord_names(ds::NetCDFDataset, file_paths)
    found = Pair{Symbol, String}[]
    varnames = collect(keys(ds))
    for (coord_type, candidates) in pairs(COORD_NAMES)
        matches = filter(name -> lowercase(name) in candidates, varnames)
        length(matches) > 1 && error(
            "Found multiple $coord_type variables ($(join(matches, ", "))) in $file_paths; pass `coord_names` to disambiguate",
        )
        isempty(matches) || push!(found, coord_type => only(matches))
    end
    return NamedTuple(found)
end
