using Test

import ClimaUtilities
import ClimaUtilities: Regridders
import NCDatasets
import ClimaCore
import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends

const context = ClimaComms.context()
ClimaComms.init(context)

include("TestTools.jl")

@testset "default_regridder_type" begin
    # Case 1: no regridder available
    @test_throws ErrorException Regridders.default_regridder_type()

    # Case 2: only TempestRegridder available
    import ClimaCoreTempestRemap
    @test Regridders.default_regridder_type() == :TempestRegridder

    # Case 3: TempestRegridder and InterpolationsRegridder both available
    import Interpolations
    @test Regridders.default_regridder_type() == :InterpolationsRegridder

    # Case 4: only TempestRegridder available
    # This case is not currently tested because we don't have a way to remove
    #  previously-loaded extensions.
end

@testset "InterpolationsRegridder incorrect dimensions" begin
    lon, lat, z =
        collect(0.0:1:360), collect(-90.0:1:90), collect(0.0:1.0:100.0)
    dimensions3D = (lon, lat, z)
    dimensions3D_reversed = (lon, reverse(lat), reverse(z))
    dimensions2D = (lon, lat)
    dimensions2D_reversed = (lon, reverse(lat))
    size3D = (361, 181, 101)
    size2D = (361, 181)
    data_lat2D = zeros(size2D)
    data_lat2D_reversed = zeros(size2D)
    data_lon2D = zeros(size2D)
    data_lat3D = zeros(size3D)
    data_lat3D_reversed = zeros(size3D)
    data_lon3D = zeros(size3D)
    data_z3D = zeros(size3D)
    data_z3D_reversed = zeros(size3D)
    for i in 1:length(lon)
        data_lat2D[i, :] .= lat
        data_lat2D_reversed[i, :] .= reverse(lat)
    end
    for i in 1:length(lat)
        data_lon2D[:, i] .= lon
    end
    for i in 1:length(lon)
        for j in 1:length(z)
            data_lat3D_reversed[i, :, :] .= reverse(lat)
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
            data_z3D_reversed[i, j, :] .= reverse(z)
            data_z3D[i, j, :] .= z
        end
    end
    spaces = make_spherical_space(Float64; context)
    horzspace = spaces.horizontal
    hv_center_space = spaces.hybrid


    # 3D space
    extrapolation_bc = (
        Interpolations.Periodic(),
        Interpolations.Flat(),
        Interpolations.Flat(),
    )
    # create one regirdder with no transformations to dimensions needed
    # create another regridder that reverses the second dimension
    reg_horz = Regridders.InterpolationsRegridder(horzspace)
    reg_horz_reversed = Regridders.InterpolationsRegridder(
        horzspace;
        dim_increasing = (true, false),
    )
    # check that `reg_horz_reversed` reverses lon and not lat as expected
    regridded_lat = Regridders.regrid(reg_horz, data_lat2D, dimensions2D)
    regridded_lon = Regridders.regrid(reg_horz, data_lon2D, dimensions2D)
    regridded_lat_reversed = Regridders.regrid(
        reg_horz_reversed,
        data_lat2D_reversed,
        dimensions2D_reversed,
    )
    regridded_lon_reversed =
        Regridders.regrid(reg_horz_reversed, data_lon2D, dimensions2D_reversed)
    @test regridded_lat_reversed == regridded_lat
    @test regridded_lon_reversed == regridded_lon

    # Create one regridder with no transformations to dimensions needed
    # Create another regridder that reverses the second and third dimensions
    reg_hv =
        Regridders.InterpolationsRegridder(hv_center_space; extrapolation_bc)
    regridded_lat = Regridders.regrid(reg_hv, data_lat3D, dimensions3D)
    regridded_lon = Regridders.regrid(reg_hv, data_lon3D, dimensions3D)
    regridded_z = Regridders.regrid(reg_hv, data_z3D, dimensions3D)
    dim_increasing = (true, false, false)
    reg_hv_reversed = Regridders.InterpolationsRegridder(
        hv_center_space;
        extrapolation_bc,
        dim_increasing,
    )
    regridded_lat_reversed = Regridders.regrid(
        reg_hv_reversed,
        data_lat3D_reversed,
        dimensions3D_reversed,
    )
    regridded_lon_reversed =
        Regridders.regrid(reg_hv_reversed, data_lon3D, dimensions3D_reversed)
    regridded_z_reversed = Regridders.regrid(
        reg_hv_reversed,
        data_z3D_reversed,
        dimensions3D_reversed,
    )
    @test regridded_lat_reversed == regridded_lat
    @test regridded_lon_reversed == regridded_lon
    @test regridded_z_reversed == regridded_z
end

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
        spaces = make_spherical_space(FT; context)
        horzspace = spaces.horizontal
        hv_center_space = spaces.hybrid

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
        extrapolation_bc = (
            Interpolations.Periodic(),
            Interpolations.Flat(),
            Interpolations.Flat(),
        )

        reg_hv = Regridders.InterpolationsRegridder(
            hv_center_space;
            extrapolation_bc,
        )

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

@testset "TempestRegridder" begin
    for FT in (Float32, Float64)
        data_path = joinpath(@__DIR__, "test_data", "era5_1979_1.0x1.0_lai.nc")
        ds = NCDatasets.NCDataset(data_path, "r")
        original_max = maximum(ds["lai_lv"][:, :, 1])
        original_min = minimum(ds["lai_lv"][:, :, 1])
        test_time = ds["time"][1]
        close(ds)
        test_space = make_spherical_space(FT; context).horizontal
        regrid_dir = nothing
        if ClimaComms.iamroot(context)
            regrid_dir = mktempdir()
        end
        regrid_dir = ClimaComms.bcast(context, regrid_dir)
        ClimaComms.barrier(context)
        regridder = Regridders.TempestRegridder(
            test_space,
            "lai_lv",
            data_path;
            regrid_dir,
        )
        ClimaComms.barrier(context)
        regridded_field = Regridders.regrid(regridder, test_time)
        regridded_max = maximum(regridded_field)
        regridded_min = minimum(regridded_field)
        @test original_max >= regridded_max
        @test original_min <= regridded_min
    end
end
