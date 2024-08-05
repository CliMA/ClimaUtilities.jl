# TimeVaryingInputs.jl
#
# This module contains structs and methods to process external data and evaluate it on the
# model. This module only concerns with evaluations in time, not in space.

# There are three possible sources of data:
# 1. Analytic functions that prescribe how a variable has to be set at a given time
# 2. 0D, single-site data, which is assumed small enough to be saved to memory
# 3. 2/3D, global data, which cannot be saved to memory in its entirety.
#
# The TimeVaryingInputs module introduces a shared interface for the three cases so that
# uses and developers do not have to worry about the details of what type of data will be
# provided. Behind the scenes, we introduce a new type AbstractTimeVaryingInput, that has
# three concrete implementation, corresponding to the three use cases described above.
# Constructors will automatically identify which of the three implementations to use based
# on the input data, and the existence of three concrete structs should be considered an
# implementation detail.
#
# The three TimeVaryingInputs are:
# - AnalyticTimeVaryingInput,
# - InterpolatingTimeVaryingInput0D,
# - InterpolatingTimeVaryingInput23D.
#
# Along side these TimeVaryingInputs, we also define InterpolationMethods that implement
# specific interpolation strategies (e.g., linear interpolation).
#
# In all cases, the TimeVaryingInputs work with simulation time (ie, seconds from the
# beginning of the reference date). It is up to the various TimeVaryingInputs to convert this
# information to an actual date (if needed).

module TimeVaryingInputs

"""
    AbstractTimeVaryingInput

Note
=====

`TimeVaryingInput`s should be considered implementation details. The exposed public interface
should only be considered
- `TimeVaryingInput(input; method, context)` for construction,
- `evaluate!(dest, input, time)` for evaluation
"""
abstract type AbstractTimeVaryingInput end

"""
    AbstractInterpolationMethod

Defines how to perform interpolation.

Not all the TimeVaryingInputs support all the interpolation methods (e.g., no interpolation
methods are supported when the given function is analytic).

`AbstractInterpolationMethod`s have to implement a `extrapolation_bc` field.
"""
abstract type AbstractInterpolationMethod end

"""
    AbstractInterpolationBoundaryMethod

Defines how to handle values outside of the data boundary.

Not all the `AbstractInterpolationMethod` support all the `AbstractInterpolationBoundaryMethod`s.
"""
abstract type AbstractInterpolationBoundaryMethod end

"""
    Throw

Throw an error when interpolating outside of range.
"""
struct Throw <: AbstractInterpolationBoundaryMethod end

"""
    PeriodicCalendar

When interpolating outside of range, restart from the beginning.

For example, if the data is defined from t0 = 0 to t1 = 10, extrapolating at t=13 is
equivalent to interpolating at t=2. In practice, we identify `t1 + dt` to be `t0` again.

This can be used to repeat one year of data over and over.

`PeriodicCalendar` requires data to be uniformly sampled in time.

Note: this `PeriodicCalendar` is different from what you might be used to for `Periodic`,
where the identification is `t1 = t0`.
"""
struct PeriodicCalendar <: AbstractInterpolationBoundaryMethod end

"""
    Flat

When interpolating outside of range, use the boundary value.

For example, if the data is defined from t0 = 0 to t1 = 10, extrapolating at t=13 returns
the value at t1 = 10. When interpolating at t=-3, use t0 = 0.
"""
struct Flat <: AbstractInterpolationBoundaryMethod end

"""
    TimeVaryingInput(func)
    TimeVaryingInput(times, vals; method, context)

Construct on object that knows how to evaluate the given function/data on the model times.

When passing a function
=======================

When a function `func` is passed, the function has to be GPU-compatible (e.g., no splines).

When passing single-site data
=============================

When a `times` and `vals` are passed, `times` have to be sorted and the two arrays have to
have the same length.

=======
When the input is a function, the signature of the function can be `func(time, args...;
kwargs...)`. The function will be called with the additional arguments and keyword arguments
passed to `evaluate!`. This can be used to access the state and the cache and use those to
set the output field.

For example:
```julia
CO2fromp(time, Y, p) = p.atmos.co2
input = TimeVaryingInput(CO2fromY)
evaluate!(dest, input, t, Y, p)
```
"""
function TimeVaryingInput end

"""
    evaluate!(dest, input, time, args...; kwargs...)

Evaluate the `input` at the given `time`, writing the output in-place to `dest`.

Depending on the details of `input`, this function might do I/O and communication.

Extra arguments
================

`args` and `kwargs` are used only when the `input` is a non-interpolating function, e.g.,
an analytic one. In that case, `args` and `kwargs` are passed down to the function itself.
"""
function evaluate! end

"""
    extrapolation_bc(aim::AbstractInterpolationMethod)

Return the interpolation boundary conditions associated to `aim`.
"""
function extrapolation_bc(aim::AbstractInterpolationMethod)
    return aim.extrapolation_bc
end

"""
    NearestNeighbor(extrapolation_bc::AbstractInterpolationBoundaryMethod)

Return the value corresponding to the point closest to the input time.

`extrapolation_bc` specifies how to deal with out of boundary values.
The default value is `Throw`.
"""
struct NearestNeighbor{BC <: AbstractInterpolationBoundaryMethod} <:
       AbstractInterpolationMethod
    extrapolation_bc::BC
end

function NearestNeighbor()
    return NearestNeighbor(Throw())
end

"""
    LinearInterpolation(extrapolation_bc::AbstractInterpolationBoundaryMethod)

Perform linear interpolation between the two neighboring points.

`extrapolation_bc` specifies how to deal with out of boundary values.
The default value is `Throw`.
"""
struct LinearInterpolation{BC <: AbstractInterpolationBoundaryMethod} <:
       AbstractInterpolationMethod
    extrapolation_bc::BC
end

function LinearInterpolation()
    return LinearInterpolation(Throw())
end

end
