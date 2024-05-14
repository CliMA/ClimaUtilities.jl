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
    maybe_wait_filesystem(context,
                          path,
                          check_func = ispath,
                          sleep_time = 0.1,
                          max_attempts = 10)


Distributed filesystems might need some time to catch up a file/folder is created/removed.

This function watches the given `path` with `check_func` and returns when `check_func(path)`
returns true. This is done by trying up to `max_attempt` times and sleeping `sleep_time`
seconds in between.

Example: when creating a file, we want to check that all the MPI processes see that new
file. In this case, `check_func` could be `ispath`. Another example is with removing files
and `check_func` would be `(f) -> !ispath(f)`.
"""
function maybe_wait_filesystem(
    context,
    path;
    check_func = ispath,
    sleep_time = 0.1,
    max_attempts = 10,
)
    maybe_wait(context)
    attempt = 1
    while attempt < max_attempts
        check_func(path) && return nothing
        sleep(sleep_time)
        attempt = attempt + 1
    end
    error("Path $path not properly synced")
    return nothing
end

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

This style is designed to:
- be non-destructive,
- provide a deterministic and fixed path for the latest available data,
- and have nearly zero runtime overhead.

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

## A note for Windows users

Windows does not always allow the creation of symbolic links by unprivileged users. This
depends on the version of Windows, but also some of its settings. When the creation of
symbolic links is not possible, `OutputPathGenerator` will create NTFS junction points
instead. Junction points are similar to symbolic links, with the main difference that they
have to refer to directories and they have to be absolute paths. As a result, on systems
that do not allow unprivileged users to create symbolic links, moving the base output folder
results in breaking the `output_active` link.
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
    output_path == "" && error("output_path cannot be empty")
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
    maybe_wait_filesystem(context, output_path)
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
    maybe_wait_filesystem(context, output_path)

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
        # The link does not exist, but maybe there are already output folders. We can try to
        # guess what was the last one by first filtering the folders that match the name,
        # and then taking the first one when sorted in reverse alphabetical order.
        existing_outputs =
            filter(x -> !isnothing(match(name_rx, x)), readdir(output_path))
        if length(existing_outputs) > 0
            @warn "$output_path already contains some output data, but no active link"
            latest_output = first(sort(existing_outputs, rev = true))
            counter_str = match(name_rx, latest_output)
            counter = parse(Int, counter_str[1])
            next_counter = counter + 1
            @warn "Restarting counter from $next_counter"
        else
            # This is our first counter
            next_counter = 0
        end
    end
    # For MPI runs, we have to make sure we are synced
    maybe_wait_filesystem(context, active_link, check_func = (f) -> !ispath(f))

    # Ensure that there are four digits
    next_counter_str = lpad(next_counter, 4, "0")

    # Create the next folder
    new_output_folder = joinpath(output_path, "output_$next_counter_str")

    # Make new folder
    if root_or_singleton(context)
        mkpath(new_output_folder)
        # On Windows, creating symlinks might require admin privileges. This depends on the
        # version of Windows and some of its settings (e.g., if "Developer Mode" is enabled).
        # So, we first try creating a symlink. If this fails, we resort to creating a NTFS
        # junction. This is almost the same as a symlink, except it requires absolute paths.
        # In general, relative paths would be preferable because they make the output
        # completely relocatable (whereas absolute paths are not).
        try
            symlink("output_$next_counter_str", active_link, dir_target = true)
        catch e
            if e isa Base.IOError && Base.uverrorname(e.code) == "EPERM"
                active_link = abspath(active_link)
                dest_active_link = abspath("output_$next_counter_str")
                symlink(dest_active_link, active_link, dir_target = true)
            else
                rethrow(e)
            end
        end
    end
    maybe_wait_filesystem(context, new_output_folder)
    return active_link
end

end
