module ClimaUtilitiesCUDAExt

import ClimaComms
import ClimaUtilities
import ClimaUtilities.TimeVaryingInputs
import CUDA

function TimeVaryingInputs.evaluate!(
    device::ClimaComms.CUDADevice,
    destination,
    itp,
    time,
    args...;
    kwargs...,
)
    # Cannot do type dispatch across extensions, we check here
    @assert itp isa
            Base.get_extension(
        ClimaUtilities,
        :ClimaUtilitiesClimaCoreExt,
    ).TimeVaryingInputs0DExt.InterpolatingTimeVaryingInput0D
    CUDA.@cuda TimeVaryingInputs.evaluate!(
        parent(destination),
        itp,
        time,
        itp.method,
    )
    return nothing
end

end
