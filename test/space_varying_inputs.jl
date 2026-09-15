using Test

import ClimaUtilities
using Dates

using ClimaUtilities.SpaceVaryingInputs: SpaceVaryingInput
import ClimaUtilities.FileReaders: DataSource
import ClimaUtilities.Utils: interpolate_columns!

import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends
using ClimaCore
using Interpolations

const context = ClimaComms.context()
ClimaComms.init(context)

include("TestTools.jl")

AT = ClimaComms.array_type(ClimaComms.device())

# This tests the analytic and 1d cases of the SpaceVaryingInput function
@testset "SpaceVaryingInput" begin
    FT = Float32

    spaces = make_spherical_space(FT; context)
    column = spaces.vertical

    analytic_func = (coords) -> 2.0
    for space in (spaces.horizontal, spaces.vertical)
        coords = ClimaCore.Fields.coordinate_field(space)
        @test SpaceVaryingInput(analytic_func, space) ==
              FT.(analytic_func.(coords))
    end

    # 1D cases
    data_z = collect(range(FT(0.0), FT(1.0), 11))
    data_value = data_z .* 2
    field = SpaceVaryingInput(data_z, data_value, column)
    @test parent(field)[:] ≈ AT(collect(range(FT(0.1), FT(1.9), 10)))

    struct Tmp{FT}
        a::FT
        b::FT
        c::FT
        function Tmp{FT}(; a::FT, c::FT) where {FT}
            b = a * 2
            new{FT}(a, b, c)
        end
    end
    data_values = (; a = data_z .* 2, c = data_z .* 3)
    field_of_structs = SpaceVaryingInput(data_z, data_values, column, Tmp{FT})
    @test eltype(field_of_structs) == Tmp{FT}
    @test field_of_structs.a == field
    @test field_of_structs.b == 2 .* field_of_structs.a
    @test parent(field_of_structs.c)[:] ≈
          AT(collect(range(FT(0.15), FT(2.85), 10)))

end

@testset "SpaceVaryingInput from DataSources" begin
    data_dir = mktempdir()
    z_a = Float64[0, 1000, 2000, 3000, 4000, 5000]
    z_b = Float64[500, 1500, 2500, 3500, 4500, 5500]
    ta_a = 300 .- 0.006 .* z_a
    ta_b = 290 .- 0.005 .* z_b
    file_a = write_column_file(
        joinpath(data_dir, "static_a.nc");
        z = z_a,
        dates = nothing,
        variables = ["ta" => ta_a],
        scalars = ["ts" => 280.0],
    )
    file_b = write_column_file(
        joinpath(data_dir, "static_b.nc");
        z = z_b,
        dates = nothing,
        variables = ["ta" => ta_b],
        scalars = ["ts" => 285.0],
        z_name = "height",
    )
    tv_file = write_column_file(
        joinpath(data_dir, "time_varying.nc");
        z = z_a,
        dates = [DateTime(2000, 1, 1), DateTime(2000, 1, 2)],
        variables = ["ta" => hcat(ta_a, ta_a)],
    )
    sources(name) =
        [DataSource(f, name) for f in (file_a, file_b, file_a, file_b)]

    for FT in (Float32, Float64)
        (; center_space, level_space, column_space, point_space) =
            make_spaces(FT; nlevels = 10, z_max = FT(6000))
        model_z = model_levels(center_space)
        regrid(z, vals) = vec(
            interpolate_columns!(
                zeros(FT, length(model_z), 1),
                model_z,
                z,
                reshape(vals, :, 1),
            ),
        )

        field = SpaceVaryingInput(sources("ta"), center_space)
        arr = Array(ClimaCore.Fields.field2array(field))
        @test arr[:, 1] == arr[:, 3] == regrid(z_a, ta_a)
        @test arr[:, 2] == arr[:, 4] == regrid(z_b, ta_b)

        # The same profile in every column, with preprocess_func applied
        field = SpaceVaryingInput(
            DataSource(file_a, "ta"),
            center_space;
            preprocess_func = x -> 2x,
        )
        arr = Array(ClimaCore.Fields.field2array(field))
        @test all(c -> arr[:, c] == 2 .* regrid(z_a, ta_a), 1:4)

        # A single column matches the array method
        field = SpaceVaryingInput([DataSource(file_a, "ta")], column_space)
        @test Array(parent(field)) ≈ Array(
            parent(SpaceVaryingInput(FT.(z_a), FT.(ta_a), column_space)),
        )

        # Static points into spaces with a single level
        field = SpaceVaryingInput(sources("ts"), level_space)
        @test vec(Array(ClimaCore.Fields.field2array(field))) ==
              FT[280, 285, 280, 285]
        field = SpaceVaryingInput([DataSource(file_a, "ts")], point_space)
        @test vec(Array(ClimaCore.Fields.field2array(field))) == FT[280]

        @test_throws "sources for a space" SpaceVaryingInput(
            sources("ta")[1:2],
            center_space,
        )
        @test_throws "has a time dimension" SpaceVaryingInput(
            [DataSource(tv_file, "ta")],
            column_space,
        )
        @test_throws "but the space has no levels" SpaceVaryingInput(
            [DataSource(file_a, "ta")],
            point_space,
        )
        @test_throws "levels, but the space has" SpaceVaryingInput(
            [DataSource(file_a, "ts")],
            column_space,
        )
        @test_throws MethodError SpaceVaryingInput(
            [DataSource(file_a, "ta")],
            make_box_space(FT),
        )
    end
end
