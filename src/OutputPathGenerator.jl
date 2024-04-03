"""
The `OutputPathGenerator` module provides tools to prepare the directory structure to be
used as output for a simulation. This might entail creating folders, moving existing data,
et cetera.
"""
module OutputPathGenerator

import ..MPIUtils: root_or_singleton, maybe_wait

import Base: rm

# Note, Styles have nothing to do with traits
abstract type OutputPathGeneratorStyle end

"""
    RemovePreexistingStyle

With this option, the output directory is directly specified. If the directory already
exists, remove it. No confirmation is asked, so use at your own risk.
"""
struct RemovePreexistingStyle <: OutputPathGeneratorStyle end

"""
    ActiveLinkStyle

This style generates a unique output path within a base directory specified by
`output_path`. It ensures the base directory exists and creates it if necessary.
Additionally, it manages a sequence of subfolders and a symbolic link named "output_active"
for convenient access to the active output location.

# Examples:

Let us assume that `output_path = dormouse`.

- `dormouse` does not exist in the current working directory: `ActiveLinkStyle` will create
  it and return `dormouse/output_active`. `dormouse/output_active` is a symlink that points
  to the newly created `dormouse/output_0000` directory.
- `dormouse` exists and contains a `output_active` link that points to
  `dormouse/output_0005`, `ActiveLinkStyle` will a new directory `dormouse/output_0006` and
  change the `output_active` to point to this directory.
- `dormouse` exists and does not contain a `output_active`, `ActiveLinkStyle` will check if
  any `dormouse/output_XXXX` exists. If not, it creates `dormouse/output_0000` and a link
  `dormouse/output_active` that points to this directory.
"""
struct ActiveLinkStyle end

"""
    generate_output_path(output_path,
                         context = nothing,
                         style::OutputPathGeneratorStyle = ActiveLinkStyle())

Process the `output_path` and return a string with the path where to write the output.

The `context` is a `ClimaComms` context and is required for MPI runs.

How the output should be structured (in terms of directory tree) is determined by the
`style`.

# Styles

- `RemovePreexistingStyle`: the `output_path` provided is the actual output path. If a directory
  already exists there, remove it without asking for confirmation.

- `ActiveLinkStyle`: the `output_path` provided is `output_path/output_active`, a link to a
  subdirectory within `output_path`. This style looks at the content of `output_path` and
  adds new subdirectories. The added directories are named with a counter, with the latest
  always accessible via the `output_path/output_active` symlink. This is style is
  non-destructive.

(Note, "styles" have nothing to do with traits.)
"""
function generate_output_path(
    output_path;
    context = nothing,
    style = ActiveLinkStyle(),
)
    return generate_output_path(style, output_path; context)
end

"""
    generate_output_path(::RemovePreexistingStyle, output_path, context = nothing)

Documentation for this function is in the `RemovePreexistingStyle` struct.
"""
function generate_output_path(
    ::RemovePreexistingStyle,
    output_path;
    context = nothing,
)
    if root_or_singleton(context)
        if isdir(output_path)
            @warn "Removing $output_path"
            rm(output_path, recursive = true)
        end
        mkpath(output_path)
    end
    return output_path
end


"""
    generate_output_path(::ActiveLinkStyle, output_path, context = nothing)

Documentation for this function is in the `ActiveLinkStyle` struct.
"""
function generate_output_path(::ActiveLinkStyle, output_path; context = nothing)
    # TODO: At the moment we hard code the name to be something like output_0000. We could make
    # this customizable as an attribute in ActiveLinkStyle.

    # Ensure path ends with a trailing slash for consistency
    path_separator_str = Base.Filesystem.path_separator
    # We need the path_separator as a char to use it in rstrip
    path_separator_char = path_separator_str[1]
    output_path = rstrip(output_path, path_separator_char) * path_separator_char

    # Create folder if it does not exist
    if root_or_singleton(context)
        isdir(output_path) || mkpath(output_path)
    end
    # For MPI runs, we have to make sure we are synced
    maybe_wait(context)

    # Look for a output_active link
    active_link = joinpath(output_path, "output_active")

    link_exists = islink(active_link)

    name_rx = r"output_(\d\d\d\d)"

    if link_exists
        target = readlink(active_link)
        counter_str = match(name_rx, target)
        if !isnothing(counter_str)
            # counter_str is the only capturing group
            counter = parse(Int, counter_str[1])
            next_counter = counter + 1

            # Remove old link
            root_or_singleton(context) && rm(active_link)
        else
            error(
                "Link $target points to a folder with a name we do not handle",
            )
        end
    else
        # The link does not exist, but maybe there are already output folders
        if any(map(x -> !isnothing(match(name_rx, x)), readdir(output_path)))
            error(
                "$output_path already contains some output data, but no active link",
            )
        end
        # This is our fist counter
        next_counter = 0
    end
    # For MPI runs, we have to make sure we are synced
    maybe_wait(context)

    # Ensure that there are four digits
    next_counter_str = lpad(next_counter, 4, "0")

    # Create the next folder
    new_output_folder = joinpath(output_path, "output_$next_counter_str")

    # Make new folder
    if root_or_singleton(context)
        mkpath(new_output_folder)
        # In Windows, symlinks must be explicitly declared as referring to a directory or not
        symlink("output_$next_counter_str", active_link, dir_target = true)
    end
    maybe_wait(context)
    return active_link
end

end
