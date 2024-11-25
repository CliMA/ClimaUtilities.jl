# For a single and multi-file dataset
const NetCDFDataset =
    Union{NCDatasets.NCDataset, NCDatasets.CommonDataModel.MFDataset}

"""
    read_available_dates(ds::NCDatasets.NCDataset)

Return all the dates in the given NCDataset. The dates are read from the "time"
or "date" datasets. If none is available, return an empty vector.
"""
function read_available_dates(ds::NetCDFDataset)
    if "time" in keys(ds.dim)
        return Dates.DateTime.(
            reinterpret.(Ref(NCDatasets.DateTimeStandard), ds["time"][:])
        )
    elseif "date" in keys(ds.dim)
        return yyyymmdd_to_datetime.(string.(ds["date"][:]))
    else
        return Dates.DateTime[]
    end
end

"""
    strdate_to_datetime(strdate::String)

Convert from String ("YYYYMMDD") to Date format.

# Arguments
- `yyyymmdd`: [String] to be converted to Date type
"""
function yyyymmdd_to_datetime(strdate::String)
    length(strdate) == 8 || error("$strdate does not have the YYYYMMDD format")
    return Dates.DateTime(
        parse(Int, strdate[1:4]),
        parse(Int, strdate[5:6]),
        parse(Int, strdate[7:8]),
    )
end
