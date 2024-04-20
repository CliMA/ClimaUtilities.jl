<h1 align="center">
  <img src="logo.svg" width="180px"> <br>
ClimaUtilities.jl
</h1>

Shared utilities for packages within the CliMA project. Please, check out the
[documentation](https://clima.github.io/ClimaUtilities.jl/dev/).

`ClimaUtilities.jl` contains:
- [`ClimaArtifacts`](https://clima.github.io/ClimaUtilities.jl/dev/climaartifacts/),
  a module that provides an MPI-safe way to lazily download artifacts and to tag
  artifacts that are being accessed in a given simulation.
- [`SpaceVaryingInputs` and
  `TimeVaryingInputs`](https://clima.github.io/ClimaUtilities.jl/dev/inputs/) to
  work with external input data.
- [`FileReaders`](https://clima.github.io/ClimaUtilities.jl/dev/filereaders/),
  [`DataHandling`](https://clima.github.io/ClimaUtilities.jl/dev/datahandling/),
  and [`Regridders`](https://clima.github.io/ClimaUtilities.jl/dev/regridders/)
  to process input data and remap it onto the simulation grid.
- [`OutputPathGenerator`](https://clima.github.io/ClimaUtilities.jl/dev/outputpathgenerator/)
  to prepare the output directory structure of a simulation.
- [`TimeManager`](https://clima.github.io/ClimaUtilities.jl/dev/timemanager/) to
  handle dates.
