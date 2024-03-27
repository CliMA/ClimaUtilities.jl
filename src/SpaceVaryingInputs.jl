# SpaceVaryingInputs.jl
#
# This module contains methods to process external data, regrid it onto the
# model grid, and return the corresponding fields for use in the simulation.
# This module only concerns with external data which varies in space,
# and not time. For temporally varying input, we refer you to `TimeVaryingInputs.jl`.

# All spatially varying parameter fields are assumed to fit into memory,
# and on GPU runs, they have underlying CuArrays on the GPU.

# The planned parameter underlying arrays are:
# - one-dimensional (values prescribed as a function of depth at a site),
# - two-dimensional (values prescribed globally at each lat/lon),
# - three-dimensional (values prescribed as a function of depth globally)
# - analytic (functions of the coordinates of the space)

module SpaceVaryingInputs

function SpaceVaryingInput end

end
