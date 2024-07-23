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
