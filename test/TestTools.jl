import ClimaCore
import ClimaComms
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
