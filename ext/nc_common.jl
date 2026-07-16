# Names a temporal dimension might have in a NetCDF file
const TIME_NAMES = ("time", "date", "t", "valid_time")

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
