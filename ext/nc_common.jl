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
    for time_dim in ("time", "t", "valid_time", "date")
        time_dim in keys(ds.dim) && return read_available_dates(ds, time_dim)
    end
    return Dates.DateTime[]
end

"""
    read_available_dates(ds::NetCDFDataset, time_dim)

Return the dates of the time dimension `time_dim` in `ds`, read as yyyymmdd
integers for "date".
"""
function read_available_dates(ds::NetCDFDataset, time_dim)
    time_dim == "date" &&
        return Dates.DateTime.(string.(ds["date"][:]), Ref("yyyymmdd"))
    # NCDatasets.jl uses CFTime.jl, which supports a time resolution of
    # an attosecond, whereas Dates.DateTime only supports a time
    # resolution of a millisecond.
    return reinterpret.(Ref(Dates.DateTime), ds[time_dim][:])
end
