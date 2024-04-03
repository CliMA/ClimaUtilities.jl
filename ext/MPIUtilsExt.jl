module MPIUtilsExt

import ClimaUtilities.MPIUtils
import ClimaComms: SingletonCommsContext, MPICommsContext
import ClimaComms: iamroot, barrier

MPIUtils.root_or_singleton(::SingletonCommsContext) = true
MPIUtils.root_or_singleton(ctx::MPICommsContext) = iamroot(ctx)

MPIUtils.maybe_wait(::SingletonCommsContext) = nothing
MPIUtils.maybe_wait(ctx::MPICommsContext) = barrier(ctx)

end
