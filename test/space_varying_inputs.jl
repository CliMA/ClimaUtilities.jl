using Test

import ClimaUtilities
import ClimaUtilities.DataHandling
import ClimaUtilities.FileReaders
using ClimaUtilities.SpaceVaryingInputs: SpaceVaryingInput

import ClimaComms
@static pkgversion(ClimaComms) >= v"0.6" && ClimaComms.@import_required_backends
using ClimaCore
using Interpolations
using NCDatasets

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

@testset "SpaceVaryingInput with MultiColumnDataHandler" begin
    FT = Float32
    long, lat = FT(20), FT(10)
    profile = FT[10, 20, 30, 40]
    nz = length(profile)
    target_space = make_column_space(
        FT;
        context,
        points = [ClimaCore.Geometry.LatLongPoint(lat, long)],
        z_elem = nz,
        z_min = FT(0.5),
        z_max = FT(nz + 0.5),
    )

    PATH = joinpath(mktempdir(), "svi_col.nc")
    NCDataset(PATH, "c") do nc
        defDim(nc, "z", nz)
        defVar(nc, "longitude", long, ())
        defVar(nc, "latitude", lat, ())
        defVar(nc, "z", FT[1, 2, 3, 4], ("z",))
        defVar(nc, "sp", profile, ("z",))
    end

    data_handler = DataHandling.MultiColumnDataHandler(
        [FileReaders.DataSource(PATH, "sp")],
        target_space,
    )
    field = SpaceVaryingInput(data_handler)
    @test field isa ClimaCore.Fields.Field
    @test axes(field) == target_space
    # Source and target z are the same, so no interpolation should be done
    @test vec(Array(ClimaCore.Fields.field2array(field))) ≈ profile

    close(data_handler)
end
