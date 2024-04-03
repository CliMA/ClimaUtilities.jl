import ClimaUtilities.OutputPathGenerator:
    generate_output_path, RemovePreexistingStyle, ActiveLinkStyle
import ClimaComms
import Base: rm
using Test

@testset "RemovePrexistingStyle" begin
    mktempdir() do base_output_path

        # Folder does not yet exist
        output_path = joinpath(base_output_path, "dormouse")
        @test output_path == generate_output_path(
            output_path,
            context = ClimaComms.context(),
            style = RemovePreexistingStyle(),
        )
        # Check that it exists now
        @test isdir(output_path)

        # Now the folder exists, let us add a file there
        open(joinpath(output_path, "something"), "w") do file
            write(file, "Something")
        end
        @test isfile(joinpath(output_path, "something"))

        # Check that the file got removed
        @test output_path == generate_output_path(
            output_path,
            context = ClimaComms.context(),
            style = RemovePreexistingStyle(),
        )
        @test !isfile(joinpath(output_path, "something"))
    end
end

@testset "ActiveLinkStyle" begin
    mktempdir() do base_output_path

        # Folder does not yet exist
        output_path = joinpath(base_output_path, "dormouse")

        expected_output = joinpath(output_path, "output_active")

        @test expected_output ==
              generate_output_path(output_path, context = ClimaComms.context())
        # Check that it exists now
        @test isdir(output_path)

        # Check folder output_0000 was created
        @test isdir(joinpath(output_path, "output_0000"))

        # Check link points to folder
        @test readlink(expected_output) == "output_0000"

        # Now the folder exists, let us see if the rotation works
        @test expected_output ==
              generate_output_path(output_path, context = ClimaComms.context())

        # Check folder output_0001 was created
        @test isdir(joinpath(output_path, "output_0001"))

        # Check link points to new folder
        @test readlink(expected_output) == "output_0001"

        # Now let us check something wrong

        # Missing link and existing output_ folders
        rm(expected_output)
        @test_throws ErrorException generate_output_path(
            output_path,
            context = ClimaComms.context(),
        )
        # Wrong link
        wrong_dir = joinpath(output_path, "wrong")
        mkdir(wrong_dir)
        symlink(wrong_dir, expected_output, dir_target = true)
        @test_throws ErrorException generate_output_path(
            output_path,
            context = ClimaComms.context(),
        )
    end
end
