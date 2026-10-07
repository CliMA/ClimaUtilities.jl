# Names a temporal dimension might have in a NetCDF file
const TIME_NAMES = ("time", "date", "t", "valid_time")

# Names a dimension might have in a NetCDF file, by type of coordinate
const COORD_NAMES = (;
    lon = ("longitude", "lon", "long"),
    lat = ("latitude", "lat"),
    z = ("z", "lev", "level", "plev", "height", "altitude"),
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
    for time_dim in ("time", "t", "valid_time")
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
    detect_coord_names(ds::NetCDFDataset, varname, file_paths)

Identify the coordinates of `varname` in `ds` by matching its dimension names
case-insensitively against `COORD_NAMES` and return them as a `NamedTuple` by
type of coordinate, omitting the types without a match.
"""
function detect_coord_names(ds::NetCDFDataset, varname, file_paths)
    found = Pair{Symbol, String}[]
    dims = NCDatasets.dimnames(ds[varname])
    for (coord_type, candidates) in pairs(COORD_NAMES)
        matches = filter(name -> lowercase(name) in candidates, dims)
        length(matches) > 1 && error(
            "Found multiple $coord_type dimensions ($(join(matches, ", "))) of $varname in $file_paths. Pass `coord_names` to disambiguate",
        )
        isempty(matches) || push!(found, coord_type => only(matches))
    end
    return NamedTuple(found)
end
