module ClimaArtifactsExt

import ClimaUtilities.ClimaArtifacts
import ClimaComms: SingletonCommsContext, MPICommsContext

ClimaArtifacts.root_or_singleton(::SingletonCommsContext) = true
ClimaArtifacts.root_or_singleton(ctx::MPICommsContext) = iamroot(ctx)

ClimaArtifacts.maybe_wait(::SingletonCommsContext) = nothing
ClimaArtifacts.maybe_wait(ctx::MPICommsContext) = barrier(ctx)

end
