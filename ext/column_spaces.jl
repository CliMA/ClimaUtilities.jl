# Spaces whose columns are independent sites, so that every column of
# ClimaCore.Fields.field2array is one time series
const MultiPointSpace =
    pkgversion(ClimaCore) >= v"0.16" ? ClimaCore.Spaces.MultiPointSpace :
    ClimaCore.Spaces.PointCloudSpace
const ColumnSpace = Union{
    ClimaCore.Spaces.PointSpace,
    ClimaCore.Spaces.FiniteDifferenceSpace,
    MultiPointSpace,
    ClimaCore.Spaces.MultiColumnFiniteDifferenceSpace,
}
