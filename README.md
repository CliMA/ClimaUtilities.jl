# ClimaUtilities.jl
Shared utilities for packages within the CliMA project.

These will include modules for regridding spatial data, temporal interpolation,
and reading in data from input files. This functionality will be used by multiple
packages including ClimaAtmos, ClimaLSM, and ClimaCoupler.

[WIP] Each of these modules is currently duplicated in multiple of the packages
listed above. The goal of this repo is to consolidate this code in one place,
and extend it to meet the needs of each of these users.
