import ClimaUtilities.OutputPathGenerator:
    generate_output_path, RemovePreexistingStyle, ActiveLinkStyle
import ClimaComms
import Base: rm
using Test

const context = ClimaComms.context()
ClimaComms.init(context)

let_filesystem_catch_up() = context isa ClimaComms.MPICommsContext && sleep(0.1)

@testset "RemovePrexistingStyle" begin
    base_output_path = ClimaComms.iamroot(context) ? mktempdir() : ""
    base_output_path = ClimaComms.bcast(context, base_output_path)
    ClimaComms.barrier(context)
    let_filesystem_catch_up()

    # Folder does not yet exist
    output_path = joinpath(base_output_path, "dormouse")
    @test output_path == generate_output_path(
        output_path,
        context = context,
        style = RemovePreexistingStyle(),
    )
    let_filesystem_catch_up()
    # Check that it exists now
    @test isdir(output_path)

    if ClimaComms.iamroot(context)
        # Now the folder exists, let us add a file there
        open(joinpath(output_path, "something"), "w") do file
            write(file, "Something")
        end
    end
    ClimaComms.barrier(context)
    let_filesystem_catch_up()
    @test isfile(joinpath(output_path, "something"))

    # Check that the file got removed
    @test output_path == generate_output_path(
        output_path,
        context = context,
        style = RemovePreexistingStyle(),
    )
    let_filesystem_catch_up()
    @test !isfile(joinpath(output_path, "something"))

    Base.rm(base_output_path, force = true, recursive = true)
    let_filesystem_catch_up()
end

@testset "ActiveLinkStyle" begin
    base_output_path = ClimaComms.iamroot(context) ? mktempdir() : ""
    base_output_path = ClimaComms.bcast(context, base_output_path)
    ClimaComms.barrier(context)
    let_filesystem_catch_up()

    # Folder does not yet exist
    output_path = joinpath(base_output_path, "dormouse")

    expected_output = joinpath(output_path, "output_active")

    @test expected_output ==
          generate_output_path(output_path, context = context)
    let_filesystem_catch_up()
    # Check that it exists now
    @test isdir(output_path)

    # Check folder output_0000 was created
    @test isdir(joinpath(output_path, "output_0000"))

    # Check link points to folder
    @test readlink(expected_output) == "output_0000"

    # Now the folder exists, let us see if the rotation works
    @test expected_output ==
          generate_output_path(output_path, context = context)
    let_filesystem_catch_up()

    # Check folder output_0001 was created
    @test isdir(joinpath(output_path, "output_0001"))

    # Check link points to new folder
    @test readlink(expected_output) == "output_0001"
    let_filesystem_catch_up()

    # Now let us check something wrong

    # Missing link and existing output_ folders
    if ClimaComms.iamroot(context)
        rm(expected_output)
    end
    ClimaComms.barrier(context)
    let_filesystem_catch_up()
    @test_throws ErrorException generate_output_path(
        output_path,
        context = context,
    )
    let_filesystem_catch_up()
    # Wrong link
    if ClimaComms.iamroot(context)
        wrong_dir = joinpath(output_path, "wrong")
        mkdir(wrong_dir)
        symlink(wrong_dir, expected_output, dir_target = true)
    end
    ClimaComms.barrier(context)
    let_filesystem_catch_up()
    @test_throws ErrorException generate_output_path(
        output_path,
        context = context,
    )

    Base.rm(base_output_path, force = true, recursive = true)
end
