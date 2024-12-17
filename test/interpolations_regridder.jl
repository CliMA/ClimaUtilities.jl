using Test
import ClimaUtilities
import Interpolations
import ClimaUtilities: Regridders
import ClimaComms
import ClimaCore

linear_interp_z =
    Base.get_extension(
        ClimaUtilities,
        :ClimaUtilitiesClimaCoreInterpolationsExt,
    ).InterpolationsRegridderExt.linear_interp_z
bilinear_interp =
    Base.get_extension(
        ClimaUtilities,
        :ClimaUtilitiesClimaCoreInterpolationsExt,
    ).InterpolationsRegridderExt.bilinear_interp
interpolation_3d_z =
    Base.get_extension(
        ClimaUtilities,
        :ClimaUtilitiesClimaCoreInterpolationsExt,
    ).InterpolationsRegridderExt.interpolation_3d_z

const context = ClimaComms.context()
ClimaComms.init(context)

include("TestTools.jl")

@testset "Interpolation Tests" begin
    @testset "linear_interp_z" begin
        f = [1.0, 3.0, 5.0]
        z = [10.0, 20.0, 30.0]
        @test linear_interp_z(f, z, 15.0) ≈ 2.0
        @test linear_interp_z(f, z, 25.0) ≈ 4.0
        @test linear_interp_z(f, z, 10.0) ≈ 1.0
        @test linear_interp_z(f, z, 30.0) ≈ 5.0

        # Out of bounds
        f = [1.0, 3.0]
        z = [10.0, 20.0]
        @test_throws ErrorException linear_interp_z(f, z, 5.0)
        @test_throws ErrorException linear_interp_z(f, z, 25.0)


        # One point
        f = [2.5]
        z = [15.0]
        @test_throws ErrorException linear_interp_z(f, z, 10.0)
        @test_throws ErrorException linear_interp_z(f, z, 20.0)

        # Non uniform spacing
        f = [2.0, 4.0, 8.0]
        z = [1.0, 3.0, 7.0]
        @test linear_interp_z(f, z, 1.0) ≈ 2.0
        @test linear_interp_z(f, z, 3.0) ≈ 4.0
        @test linear_interp_z(f, z, 7.0) ≈ 8.0
        @test linear_interp_z(f, z, 2.0) ≈ 3.0
        @test linear_interp_z(f, z, 5.0) ≈ 6.0
    end

    @testset "interpolation_3d_z" begin
        # Test cases for the main 3D interpolation function

        # Create some sample data
        xs = [1.0, 2.0, 3.0]
        ys = [4.0, 5.0, 6.0]
        zs = zeros(3, 3, 8)
        for k in 1:8
            for j in 1:3
                for i in 1:3
                    zs[i, j, k] = i + j + k
                end
            end
        end
        data = reshape(1:(3 * 3 * 8), 3, 3, 8)

        # Exact point
        @test interpolation_3d_z(data, xs, ys, zs, xs[1], ys[1], zs[1, 1, 4]) ≈
              data[1, 1, 4]

        # Interpolated point
        @test interpolation_3d_z(data, xs, ys, zs, 2.5, 5.5, 7.5) ≈ 20.5

        # Out of bounds
        @test_throws ErrorException interpolation_3d_z(
            data,
            xs,
            ys,
            zs,
            0.5,
            4.5,
            3.5,
        )
        @test_throws ErrorException interpolation_3d_z(
            data,
            xs,
            ys,
            zs,
            2.5,
            4.5,
            4.5,
        )
    end

    @testset "Regrid" begin

        lon, lat, z =
            collect(-180.0:1:180), collect(-90.0:1:90), collect(0.0:1.0:100.0)
        size3D = (361, 181, 101)
        data_z3D = zeros(size3D)

        for i in 1:length(lon)
            for j in 1:length(lat)
                data_z3D[i, j, :] .= z
            end
        end
        dimensions3D = (lon, lat, data_z3D)

        FT = Float64
        spaces = make_spherical_space(FT; context)
        hv_center_space = spaces.hybrid
        extrapolation_bc = (
            Interpolations.Throw(),
            Interpolations.Throw(),
            Interpolations.Throw(),
        )
        reg_hv = Regridders.InterpolationsRegridder(
            hv_center_space;
            extrapolation_bc,
        )
        regridded_z = Regridders.regrid(reg_hv, data_z3D, dimensions3D)
        @test maximum(ClimaCore.Fields.level(regridded_z, 2)) ≈ 0.15
        @test minimum(ClimaCore.Fields.level(regridded_z, 2)) ≈ 0.15

    end
end
