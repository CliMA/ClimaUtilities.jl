using Test

import ClimaUtilities
import ClimaUtilities: Regridders

import ClimaCore
import ClimaComms

import Interpolations

@testset "InterpolationsRegridder" begin

    lon, lat, z =
        collect(0.0:1:360), collect(-90.0:1:90), collect(0.0:1.0:100.0)
    dimensions2D = (lon, lat)
    dimensions3D = (lon, lat, z)
    size2D = (361, 181)
    size3D = (361, 181, 101)
    data_lat2D = zeros(size2D)
    data_lon2D = zeros(size2D)
    for i in 1:length(lon)
        data_lat2D[i, :] .= lat
    end
    for i in 1:length(lat)
        data_lon2D[:, i] .= lon
    end

    data_lat3D = zeros(size3D)
    data_lon3D = zeros(size3D)
    data_z3D = zeros(size3D)
    for i in 1:length(lon)
        for j in 1:length(z)
            data_lat3D[i, :, :] .= lat
        end
    end
    for i in 1:length(lat)
        for j in 1:length(z)
            data_lon3D[:, i, :] .= lon
        end
    end
    for i in 1:length(lon)
        for j in 1:length(lat)
            data_z3D[i, j, :] .= z
        end
    end

    for FT in (Float32, Float64)
        context = ClimaComms.context()
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
        vert_center_space =
            ClimaCore.Spaces.CenterFiniteDifferenceSpace(vertmesh)

        horzdomain = ClimaCore.Domains.SphereDomain(radius)
        horzmesh = ClimaCore.Meshes.EquiangularCubedSphere(horzdomain, helem)
        horztopology = ClimaCore.Topologies.Topology2D(context, horzmesh)
        quad = ClimaCore.Spaces.Quadratures.GLL{Nq}()
        horzspace = ClimaCore.Spaces.SpectralElementSpace2D(horztopology, quad)

        hv_center_space = ClimaCore.Spaces.ExtrudedFiniteDifferenceSpace(
            horzspace,
            vert_center_space,
        )

        reg_horz = Regridders.InterpolationsRegridder(horzspace)

        regridded_lat = Regridders.regrid(reg_horz, data_lat2D, dimensions2D)
        regridded_lon = Regridders.regrid(reg_horz, data_lon2D, dimensions2D)

        coordinates = ClimaCore.Fields.coordinate_field(horzspace)

        # Compute max err
        err_lat = coordinates.lat .- regridded_lat
        err_lon = coordinates.long .- regridded_lon

        @test maximum(err_lat) < 1e-5
        @test maximum(err_lon) < 1e-5

        # 3D space

        reg_hv = Regridders.InterpolationsRegridder(hv_center_space)

        regridded_lat = Regridders.regrid(reg_hv, data_lat3D, dimensions3D)
        regridded_lon = Regridders.regrid(reg_hv, data_lon3D, dimensions3D)
        regridded_z = Regridders.regrid(reg_hv, data_z3D, dimensions3D)

        coordinates = ClimaCore.Fields.coordinate_field(hv_center_space)

        # Compute max err
        err_lat = coordinates.lat .- regridded_lat
        err_lon = coordinates.long .- regridded_lon
        err_z = coordinates.z .- regridded_z

        @test maximum(err_lat) < 1e-5
        @test maximum(err_lon) < 1e-4
        @test maximum(err_z) < 1e-5
    end
end
