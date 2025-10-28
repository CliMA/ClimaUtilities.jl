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
            return Dates.DateTime.(
                reinterpret.(Ref(NCDatasets.DateTimeStandard), ds[time_dim][:]),
            )
        end
    end
    if "date" in keys(ds.dim)
        return Dates.DateTime.(string.(ds["date"][:]), Ref("yyyymmdd"))
    else
        return Dates.DateTime[]
    end
end
