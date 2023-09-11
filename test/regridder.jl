import ClimaCore: Fields
import ClimaComms
using ClimaUtilities: Regridder, TestHelper
import Dates
using Test

REGRID_DIR = @isdefined(REGRID_DIR) ? REGRID_DIR : joinpath("", "regrid_tmp/")

const comms_ctx = ClimaComms.SingletonCommsContext()
const pid, nprocs = ClimaComms.init(comms_ctx)

for FT in (Float32, Float64)
    @testset "test missings_to_zero!" begin
        vec = [FT(1.0), FT(-2.0), missing, FT(4.0), missing]
        @test Regridder.missings_to_zero!(vec) ==
              FT.([1.0, -2.0, 0.0, 4.0, 0.0])
    end

    @testset "test nans_to_zero!" begin
        vec = FT.([1.0, -2.0, NaN, 4.0, NaN])
        @test Regridder.missings_to_zero!(vec) ==
              FT.([1.0, -2.0, 0.0, 4.0, 0.0])
    end

    @testset "test clean_data!" begin
        vec = [missing, FT(1.0), FT(-2.0), missing, FT(4.0), NaN, NaN]
        @test Regridder.clean_data!(vec) ==
              FT.([0.0, 1.0, -2.0, 0.0, 4.0, 0.0, 0.0])
    end

    # TODO add test for sparse_array_to_field!

    # Add tests which use TempestRemap here -
    # TempestRemap is not built on Windows because of NetCDF support limitations
    if !Sys.iswindows()
        @testset "test write_to_hdf5 and read_from_hdf5" begin
            # Set up testing directory
            ispath(REGRID_DIR) ?
            rm(REGRID_DIR; recursive = true, force = true) : nothing
            mkpath(REGRID_DIR)

            hd_outfile_root = "hdf5_out_test"
            tx = Dates.DateTime(1979, 01, 01, 01, 00, 00)
            test_space = TestHelper.create_space(FT)
            input_field = Fields.ones(test_space)
            varname = "testdata"

            Regridder.write_to_hdf5(
                REGRID_DIR,
                hd_outfile_root,
                tx,
                input_field,
                varname,
                comms_ctx,
            )

            output_field = Regridder.read_from_hdf5(
                REGRID_DIR,
                hd_outfile_root,
                tx,
                varname,
                comms_ctx,
            )
            @test parent(input_field) == parent(output_field)

            # Delete testing directory and files
            rm(REGRID_DIR; recursive = true, force = true)
        end
    end


end
