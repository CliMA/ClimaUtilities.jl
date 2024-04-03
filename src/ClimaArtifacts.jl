module ClimaArtifacts

import Base.BinaryPlatforms: HostPlatform
import Artifacts as JuliaArtifacts

import ..MPIUtils: root_or_singleton, maybe_wait

export @clima_artifact

const ACCESSED_ARTIFACTS::Set{String} = Set(String[])

"""
    accessed_artifacts()

Return a set with the names of the artifacts accessed using the @clima_artifact macro.
"""
function accessed_artifacts()
    return ACCESSED_ARTIFACTS
end

# This code is largely a re-implementation of Artifacts.artifact_str extended to
# add instrumentation and control MPI. Loading ClimaComms to load
# ClimaArtifactsExt.jl is required whenever MPI is possibly involved.
"""
    @clima_artifact(artifact_name, context = nothing)

Return the path of the given artifact name. The path is always a folder (Julia
artifacts can contain multiple files).

This macro plays nicely with MPI contexts and lazily downloaded artifacts. This
is achieved by ensuring that only one process downloads the file, while the
other wait until the file is fully downloaded.

Passing the context is required only for lazy artifacts.
"""
macro clima_artifact(name, context = nothing)
    # Find Artifacts.toml file we're going to load from
    srcfile = string(__source__.file)
    if (
        (isinteractive() && startswith(srcfile, "REPL[")) ||
        (!isinteractive() && srcfile == "none")
    ) && !isfile(srcfile)
        srcfile = pwd()
    end
    local artifacts_toml = JuliaArtifacts.find_artifacts_toml(srcfile)
    if artifacts_toml === nothing
        error(
            string(
                "Cannot locate '(Julia)Artifacts.toml' file when attempting to use artifact '",
                name,
                "' in '",
                __module__,
                "'",
            ),
        )
    end

    # Load Artifacts.toml at compile time, so that we don't have to use `__source__.file`
    # at runtime, which gets stale if the `.ji` file is relocated.
    local artifact_dict = JuliaArtifacts.load_artifacts_toml(artifacts_toml)

    # Invalidate calling .ji file if Artifacts.toml file changes
    Base.include_dependency(artifacts_toml)

    # Check if the user has provided `LazyArtifacts`, and thus supports lazy artifacts
    # If not, check to see if `Pkg` or `Pkg.Artifacts` has been imported.
    lazyartifacts = nothing
    for module_name in (:LazyArtifacts, :Pkg, :Artifacts)
        if isdefined(__module__, module_name)
            lazyartifacts = GlobalRef(__module__, module_name)
            break
        end
    end

    # Artifacts.artifact_str deals with platforms, but we do not need to support that
    # feature
    platform = HostPlatform()

    # If `name` is a constant, we can actually load and parse the `Artifacts.toml` file now,
    # saving the work from runtime.
    if isa(name, AbstractString)
        # To support slash-indexing, we need to split the artifact name from the path tail:
        artifact_name, artifact_path_tail, hash =
            JuliaArtifacts.artifact_slash_lookup(
                name,
                artifact_dict,
                artifacts_toml,
                platform,
            )
        meta = JuliaArtifacts.artifact_meta(
            artifact_name,
            artifact_dict,
            artifacts_toml;
            platform,
        )
        if !isnothing(meta) && get(meta, "lazy", false)
            # This is a lazy artifact, we can only process it with a context
            isnothing(context) &&
                error("Lazy artifacts require @clima_artifact(name, context)")
        end
        # If artifact_name is not a string (e.g., it is a variable), we have to do all the
        # work at runtime
        return quote
            local platform = $(esc(platform))
            local artifact_name, artifact_path_tail, hash =
                JuliaArtifacts.artifact_slash_lookup(
                    $(esc(name)),
                    $(artifact_dict),
                    $(artifacts_toml),
                    platform,
                )
            # We call JuliaArtifacts._artifact_str twice, the first time only with the root
            # process (to avoid race conditions), the second time to ensure that all the
            # processes have the artifact string
            if Base.invokelatest(root_or_singleton, $(esc(context)))
                artifact_path = Base.invokelatest(
                    JuliaArtifacts._artifact_str,
                    $(__module__),
                    $(artifacts_toml),
                    $(artifact_name),
                    $(artifact_path_tail),
                    $(artifact_dict),
                    $(hash),
                    $(platform),
                    $(lazyartifacts),
                )::String
                push!(ACCESSED_ARTIFACTS, artifact_name)
            end
            Base.invokelatest(
                JuliaArtifacts._artifact_str,
                $(__module__),
                $(artifacts_toml),
                $(artifact_name),
                $(artifact_path_tail),
                $(artifact_dict),
                $(hash),
                $(platform),
                $(lazyartifacts),
            )::String
        end
    else
        # If artifact_name is not a string (e.g., it is a variable), we have to do all the
        # work at runtime
        return quote
            local platform = $(esc(platform))
            local artifact_name, artifact_path_tail, hash =
                JuliaArtifacts.artifact_slash_lookup(
                    $(esc(name)),
                    $(artifact_dict),
                    $(artifacts_toml),
                    platform,
                )
            meta = JuliaArtifacts.artifact_meta(
                artifact_name,
                $artifact_dict,
                $artifacts_toml;
                platform,
            )
            if !isnothing(meta) && get(meta, "lazy", false)
                # This is a lazy artifact, we can only process it with a context
                isnothing($(esc(context))) && error(
                    "Lazy artifacts require @clima_artifact(name, context)",
                )
            end
            # We call JuliaArtifacts._artifact_str twice, the first time only with the root
            # process (to avoid race conditions), the second time to ensure that all the
            # processes have the artifact string
            if Base.invokelatest(root_or_singleton, $(esc(context)))
                artifact_path = Base.invokelatest(
                    JuliaArtifacts._artifact_str,
                    $(__module__),
                    $(artifacts_toml),
                    artifact_name,
                    artifact_path_tail,
                    $(artifact_dict),
                    hash,
                    platform,
                    $(lazyartifacts),
                )::String
                push!(ACCESSED_ARTIFACTS, artifact_name)
            end
            Base.invokelatest(maybe_wait, $(esc(context)))
            Base.invokelatest(
                JuliaArtifacts._artifact_str,
                $(__module__),
                $(artifacts_toml),
                artifact_name,
                artifact_path_tail,
                $(artifact_dict),
                hash,
                platform,
                $(lazyartifacts),
            )::String
        end
    end
end
end
