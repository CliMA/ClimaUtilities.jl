import ClimaCore
import ClimaComms
import NCDatasets
import ClimaCore: CommonSpaces, Grids

@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends

function make_spherical_space(FT; context = ClimaComms.context())
    radius = FT(128)
    zlim = (FT(0), FT(1))
    helem = 4
    zelem = 10
    Nq = 4

    vertdomain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.ZPoint{FT}(zlim[1]),
        ClimaCore.Geometry.ZPoint{FT}(zlim[2]);
        boundary_names = (:bottom, :top),
    )
    vertmesh = ClimaCore.Meshes.IntervalMesh(vertdomain, nelems = zelem)
    vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
        ClimaComms.device(context),
        vertmesh,
    )

    horzdomain = ClimaCore.Domains.SphereDomain(radius)
    horzmesh = ClimaCore.Meshes.EquiangularCubedSphere(horzdomain, helem)
    horztopology = ClimaCore.Topologies.Topology2D(context, horzmesh)
    quad = ClimaCore.Spaces.Quadratures.GLL{Nq}()
    horzspace = ClimaCore.Spaces.SpectralElementSpace2D(horztopology, quad)

    hv_center_space = ClimaCore.Spaces.ExtrudedFiniteDifferenceSpace(
        horzspace,
        vert_center_space,
    )
    (;
        horizontal = horzspace,
        hybrid = hv_center_space,
        vertical = vert_center_space,
    )
end

function make_regional_space(FT; context = ClimaComms.context())
    lat0, long0 = FT(34), FT(-118)
    delta_lat, delta_long = FT(5), FT(5)
    zlim = (FT(0), FT(1))
    helem = (4, 4)
    zelem = 10
    Nq = 4

    domain_long = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.LongPoint{FT}(long0 - delta_long),
        ClimaCore.Geometry.LongPoint{FT}(long0 + delta_long),
        boundary_names = (:west, :east),
    )
    domain_lat = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.LatPoint{FT}(lat0 - delta_lat),
        ClimaCore.Geometry.LatPoint{FT}(lat0 + delta_lat),
        boundary_names = (:north, :south),
    )
    horzdomain = ClimaCore.Domains.RectangleDomain(domain_lat, domain_long)
    horzmesh = ClimaCore.Meshes.RectilinearMesh(horzdomain, helem...)
    horztopology = ClimaCore.Topologies.Topology2D(context, horzmesh)
    quad = ClimaCore.Spaces.Quadratures.GLL{Nq}()
    horzspace = ClimaCore.Spaces.SpectralElementSpace2D(horztopology, quad)

    vertdomain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.ZPoint{FT}(zlim[1]),
        ClimaCore.Geometry.ZPoint{FT}(zlim[2]);
        boundary_names = (:bottom, :top),
    )
    vertmesh = ClimaCore.Meshes.IntervalMesh(vertdomain, nelems = zelem)
    vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
        ClimaComms.device(context),
        vertmesh,
    )

    hv_center_space = ClimaCore.Spaces.ExtrudedFiniteDifferenceSpace(
        horzspace,
        vert_center_space,
    )
    (;
        horizontal = horzspace,
        hybrid = hv_center_space,
        vertical = vert_center_space,
    )
end

function make_box_space(FT; context = ClimaComms.context())
    helem = (10, 10)
    xrange = (0.0, 1.0)
    yrange = (0.0, 1.0)
    zrange = (0.0, 1.0)
    Nq = 4
    zelem = 10

    vertical_domain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.ZPoint{FT}(zrange[1]),
        ClimaCore.Geometry.ZPoint{FT}(zrange[2]),
        boundary_names = (:bottom, :top),
    )

    x_domain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.XPoint{FT}(xrange[1]),
        ClimaCore.Geometry.XPoint{FT}(xrange[2]),
        boundary_names = (:west, :east),
    )

    y_domain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.YPoint{FT}(yrange[1]),
        ClimaCore.Geometry.YPoint{FT}(yrange[2]),
        boundary_names = (:south, :north),
    )

    horzdomain = ClimaCore.Domains.RectangleDomain(x_domain, y_domain)
    horzmesh = ClimaCore.Meshes.RectilinearMesh(horzdomain, helem...)
    horztopology = ClimaCore.Topologies.Topology2D(context, horzmesh)
    quad = ClimaCore.Spaces.Quadratures.GLL{Nq}()
    horzspace = ClimaCore.Spaces.SpectralElementSpace2D(horztopology, quad)

    vertmesh = ClimaCore.Meshes.IntervalMesh(vertical_domain, nelems = zelem)

    vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
        ClimaComms.device(context),
        vertmesh,
    )

    hybrid = ClimaCore.Spaces.ExtrudedFiniteDifferenceSpace(
        horzspace,
        vert_center_space,
    )

    return hybrid

end

function make_z_only_space(FT; context = ClimaComms.context())
    zlim = (FT(0), FT(1))
    zelem = 10

    vertdomain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.ZPoint{FT}(zlim[1]),
        ClimaCore.Geometry.ZPoint{FT}(zlim[2]);
        boundary_names = (:bottom, :top),
    )
    vertmesh = ClimaCore.Meshes.IntervalMesh(vertdomain, nelems = zelem)
    vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
        ClimaComms.device(context),
        vertmesh,
    )

    return vert_center_space
end

# ClimaCore < 0.16 only has the old name. Remove this when ClimaCore v0.15 is
# not supported.
const MultiColumnSpace =
    pkgversion(ClimaCore) >= v"0.16" ? CommonSpaces.MultiColumnSpace :
    CommonSpaces.PointColumnEnsembleSpace

"""
    write_column_file(path; z, dates, variables, z_name = "z", z_units = "m",
                      time_first = false, scalars = ())

Write a single-site NetCDF file at `path` and return the path: the coordinate
`z_name` holding `z` with units `z_units`, a `time` axis holding `dates` unless
`dates` is `nothing`, the scalar variables `scalars` and the variables
`variables`, both `name => data` pairs. A matrix is written over `(z, time)`, or
`(time, z)` when `time_first`; a vector over `time`, or over `z` when there are
no dates.
"""
function write_column_file(
    path;
    z,
    dates,
    variables,
    z_name = "z",
    z_units = "m",
    time_first = false,
    scalars = (),
)
    NCDatasets.NCDataset(path, "c") do nc
        nc.attrib["site_latitude"] = 17.0
        nc.attrib["site_longitude"] = -149.0
        NCDatasets.defDim(nc, z_name, length(z))
        NCDatasets.defVar(
            nc,
            z_name,
            z,
            (z_name,);
            attrib = ["units" => z_units],
        )
        if !isnothing(dates)
            NCDatasets.defDim(nc, "time", length(dates))
            NCDatasets.defVar(nc, "time", dates, ("time",))
        end
        for (name, value) in scalars
            NCDatasets.defVar(nc, name, value, ())
        end
        for (name, data) in variables
            if data isa AbstractMatrix
                dims = time_first ? ("time", z_name) : (z_name, "time")
                data = time_first ? permutedims(data) : data
            else
                dims = isnothing(dates) ? (z_name,) : ("time",)
            end
            NCDatasets.defVar(nc, name, data, dims)
        end
    end
    return path
end

"""
    make_spaces(FT; nlevels, z_max)

Spaces with four columns and with one column, `nlevels` levels up to `z_max`,
and their single-level counterparts.
"""
function make_spaces(FT; nlevels, z_max)
    points = [
        ClimaCore.Geometry.LatLongPoint(FT(lat), FT(long)) for
        (lat, long) in zip((-30.0, 0.0, 30.0, 60.0), (0.0, 45.0, 90.0, 180.0))
    ]
    center_space = MultiColumnSpace(
        FT;
        points,
        z_elem = nlevels,
        z_min = FT(0),
        z_max,
        radius = FT(6.371229e6),
        staggering = Grids.CellCenter(),
    )
    domain = ClimaCore.Domains.IntervalDomain(
        ClimaCore.Geometry.ZPoint{FT}(0),
        ClimaCore.Geometry.ZPoint{FT}(z_max),
        boundary_names = (:bottom, :top),
    )
    mesh = ClimaCore.Meshes.IntervalMesh(domain; nelems = nlevels)
    topology = ClimaCore.Topologies.IntervalTopology(
        ClimaComms.SingletonCommsContext(ClimaComms.device()),
        mesh,
    )
    column_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(topology)
    return (;
        center_space,
        level_space = ClimaCore.Spaces.level(center_space, 1),
        horizontal_space = ClimaCore.Spaces.horizontal_space(center_space),
        column_space,
        point_space = ClimaCore.Spaces.level(column_space, 1),
    )
end
