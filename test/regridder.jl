import ClimaCore: Fields, Spaces
import ClimaComms
import ClimaUtilities: Regridder, TestHelper
import Dates
import NCDatasets as NCD
using Test

TEST_DIR = @isdefined(TEST_DIR) ? TEST_DIR : joinpath("", "regrid_test_tmp/")

const comms_ctx = ClimaComms.SingletonCommsContext()
const pid, nprocs = ClimaComms.init(comms_ctx)

for FT in (Float32, Float64)
    @testset "test missings_to_zero for FT=$FT" begin
        vec = [FT(1.0), FT(-2.0), missing, FT(4.0), missing]
        vec = Regridder.missings_to_zero(vec)
        @test vec == FT.([1.0, -2.0, 0.0, 4.0, 0.0])
        @test typeof(vec) == Vector{FT}
    end

    @testset "test nans_to_zero for FT=$FT" begin
        vec = FT.([1.0, -2.0, NaN, 4.0, NaN])
        vec = Regridder.nans_to_zero(vec)
        @test vec == FT.([1.0, -2.0, 0.0, 4.0, 0.0])
        @test typeof(vec) == Vector{FT}
    end

    @testset "test clean_data for FT=$FT" begin
        # Vector of all FT type
        vec_ft = FT.([1.0, -2.0, NaN, 4.0, NaN])
        vec_ft = Regridder.clean_data(vec_ft)
        @test vec_ft == FT.([1.0, -2.0, 0.0, 4.0, 0.0])
        @test typeof(vec_ft) == Vector{FT}

        # Vector of combined Missing/FT types
        vec_mft =
            [missing, FT(1.0), FT(-2.0), missing, FT(4.0), FT(NaN), FT(NaN)]
        vec_mft = Regridder.clean_data(vec_mft)
        @test vec_mft == FT.([0.0, 1.0, -2.0, 0.0, 4.0, 0.0, 0.0])
        @test typeof(vec_mft) == Vector{FT}
    end

    # TODO finish test for sparse_array_to_field!
    # @testset "test sparse_array_to_field! for FT=$FT" begin
    #     # create spectral element space
    #     space = TestHelper.create_space(FT)
    #     field = Fields.ones(space)

    #     TR_in_arr = vec(0.5 .* copy(parent(field)))
    #     TR_inds = (; target_idxs, row_indices)
    #     # TODO what shapes should target_idxs, row_indices have?

    #     sparse_array_to_field!(field, TR_in_arr, TR_inds)

    #     # apply dss! to input array to compare with converted field
    #     # TODO does it make sense to dss 1d array?
    #     # TODO field will have redundant node indexing
    #     space = axes(field)
    #     topology = Spaces.topology(space)
    #     hspace = Spaces.horizontal_space(space)
    #     Spaces.dss!(TR_in_arr, topology, hspace.quadrature_style)

    #     # TODO do I need to loop over rows for comparison?
    #     # TODO can I do comparison with dss?
    #     @test vec(parent(field)) == TR_in_arr
    # end

    @testset "test binary_mask for FT=$FT" begin
        arr = FT.([0.6, -1, 0.4, 0.5, 0, 100000])
        @test Regridder.binary_mask.(arr) == FT.([1, 0, 0, 1, 0, 1])
    end

    @testset "test dummy_remap! for FT=$FT" begin
        test_space = TestHelper.create_space(FT)
        test_field_ones = Fields.ones(test_space)
        target_field = Fields.zeros(test_space)

        Regridder.dummy_remap!(target_field, test_field_ones)
        @test parent(target_field) == parent(test_field_ones)
    end

    @testset "test write_field_to_ncdataset for FT=$FT" begin
        # Set up testing directory
        ispath(TEST_DIR) ? rm(TEST_DIR; recursive = true, force = true) :
        nothing
        mkpath(TEST_DIR)

        # Create field of all ones
        test_space = TestHelper.create_space(FT)
        field = Fields.ones(test_space)
        var = :test_var
        ncd_filename = TEST_DIR * "regrid_test_ncd.nc"

        # Write field to NCDataset
        Regridder.write_field_to_ncdataset(ncd_filename, field, var)

        # Test that NCDataset was created and contains the correct data
        data = NCD.NCDataset(ncd_filename) do ds
            ds[var][:]
        end

        # Note: we can't directly compare the vectors for equality because
        #  redundant vs unique nodes changes their lengths
        @test typeof(data[1]) == eltype(field)
        @test extrema(data) == extrema(parent(field))
        # Compare lengths, accounting for redundant vs unique node counts
        @test size(data)[1] == size(vec(parent(field)))[1] * (9 / 16) + 2
        @test any(isnan.(data)) == any(isnan.(parent(field))) == false
        @test any(ismissing.(data)) == any(ismissing.(parent(field))) == false

        # Delete testing directory and files
        rm(TEST_DIR; recursive = true, force = true)
    end

    @testset "test fill_field!" begin
        space1 = TestHelper.create_space(FT)
        space2 = TestHelper.create_space(FT)

        field1 = ones(space1)
        field2 = zeros(space2)

        Regridder.fill_field!(field2, field1)

        @test parent(field1) == parent(field2)
        @test axes(field2) === space2
    end

    @testset "test swap_space" begin
        space1 = TestHelper.create_space(FT)
        space2 = TestHelper.create_space(FT)

        field1 = ones(space1)

        @test axes(field1) === space1
        field2 = Regridder.swap_space(field1, space2)

        @test parent(field1) == parent(field2)
        @test axes(field2) !== space1
        @test axes(field2) === space2
    end

    # Add tests which use TempestRemap here -
    # TempestRemap is not built on Windows because of NetCDF support limitations
    if !Sys.iswindows()
        @testset "test write_to_hdf5 and read_from_hdf5 for FT=$FT" begin
            # Set up testing directory
            ispath(TEST_DIR) ? rm(TEST_DIR; recursive = true, force = true) :
            nothing
            mkpath(TEST_DIR)

            hd_outfile_root = "hdf5_out_test"
            tx = Dates.DateTime(1979, 01, 01, 01, 00, 00)
            test_space = TestHelper.create_space(FT)
            input_field = Fields.ones(test_space)
            varname = "testdata"

            Regridder.write_to_hdf5(
                TEST_DIR,
                hd_outfile_root,
                tx,
                input_field,
                varname,
                comms_ctx,
            )

            output_field = Regridder.read_from_hdf5(
                TEST_DIR,
                hd_outfile_root,
                tx,
                varname,
                comms_ctx,
            )
            @test parent(input_field) == parent(output_field)

            # Delete testing directory and files
            rm(TEST_DIR; recursive = true, force = true)
        end

        @testset "test remap_field_cgll_to_rll for FT=$FT" begin
            # Set up testing directory
            remap_tmpdir = joinpath(TEST_DIR, "cgll_to_rll")
            ispath(remap_tmpdir) ?
            rm(remap_tmpdir; recursive = true, force = true) : nothing
            mkpath(remap_tmpdir)
            name = :testdata
            datafile_rll = remap_tmpdir * "/" * string(name) * "_rll.nc"

            test_space = TestHelper.create_space(FT)
            field = Fields.ones(test_space)

            Regridder.remap_field_cgll_to_rll(
                name,
                field,
                remap_tmpdir,
                datafile_rll,
            )

            # Test no new extrema are introduced in monotone remapping
            nt = NCD.NCDataset(datafile_rll) do ds
                max_remapped = maximum(ds[name])
                min_remapped = minimum(ds[name])
                (; max_remapped, min_remapped)
            end
            (; max_remapped, min_remapped) = nt

            @test max_remapped <= maximum(field)
            @test min_remapped >= minimum(field)

            # Delete testing directory and files
            rm(TEST_DIR; recursive = true, force = true)
        end
    end

end
