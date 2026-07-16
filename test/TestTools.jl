import ClimaCore
import ClimaComms
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
    if pkgversion(ClimaCore) >= v"0.14.10"
        vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
            ClimaComms.device(context),
            vertmesh,
        )
    else
        vert_center_space =
            ClimaCore.Spaces.CenterFiniteDifferenceSpace(vertmesh)
    end

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
    if pkgversion(ClimaCore) >= v"0.14.10"
        vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
            ClimaComms.device(context),
            vertmesh,
        )
    else
        vert_center_space =
            ClimaCore.Spaces.CenterFiniteDifferenceSpace(vertmesh)
    end

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
    if pkgversion(ClimaCore) >= v"0.14.10"
        vert_center_space = ClimaCore.Spaces.CenterFiniteDifferenceSpace(
            ClimaComms.device(context),
            vertmesh,
        )
    else
        vert_center_space =
            ClimaCore.Spaces.CenterFiniteDifferenceSpace(vertmesh)
    end

    return vert_center_space
end

function make_column_space(
    FT;
    context = ClimaComms.context(),
    points = [ClimaCore.Geometry.LatLongPoint(FT(0), FT(0))],
    z_elem = 10,
    z_min = FT(0),
    z_max = FT(1),
    reverse_mode = false,
)
    # `reverse_mode` builds a mesh with descending faces so that the coordinate
    # field's z-levels are stored in decreasing order (useful for exercising a
    # target space with decreasing vertical levels). The default path is left
    # untouched (it uses the space's `DefaultZMesh`).
    extra = if reverse_mode
        z_domain = ClimaCore.Domains.IntervalDomain(
            ClimaCore.Geometry.ZPoint(FT(z_min)),
            ClimaCore.Geometry.ZPoint(FT(z_max));
            boundary_names = (:bottom, :top),
        )
        faces = [
            ClimaCore.Geometry.ZPoint(FT(z)) for
            z in range(FT(z_max), FT(z_min); length = z_elem + 1)
        ]
        (; z_mesh = ClimaCore.Meshes.IntervalMesh(z_domain, faces))
    else
        (;)
    end
    return CommonSpaces.PointColumnEnsembleSpace(
        FT;
        device = ClimaComms.device(context),
        points,
        z_elem,
        z_min,
        z_max,
        extra...,
        staggering = CommonSpaces.CellCenter(),
    )
end
