ClimaUtilities.jl Release Notes
===============================

v0.1.12
-------

- Add support for interpolating while "period filling". PR
  [#85](https://github.com/CliMA/ClimaUtilities.jl/pull/85)
- Add support for boundary conditions in interpolation. PR
  [#84](https://github.com/CliMA/ClimaUtilities.jl/pull/84)
- Increased allocations in regridding. `read!` method removed. PR
  [#84](https://github.com/CliMA/ClimaUtilities.jl/pull/84)

v0.1.11
------

- Reduced allocations in regridding. New method `read!`. PR
  [#83](https://github.com/CliMA/ClimaUtilities.jl/pull/83)

v0.1.10
------

- Reduced allocations in regridding. New method `regridded_snapshot!`. PR
  [#72](https://github.com/CliMA/ClimaUtilities.jl/pull/72)

v0.1.9
------

- Extensions are internally reorganized, removing precompilation errors. PR
  [#69](https://github.com/CliMA/ClimaUtilities.jl/pull/69)

v0.1.8
------

- `generate_output_path(..., ::ActiveLinkStyle)` now returns the folder instead
  of the link. Links are still being created and managed. PR
  [#63](https://github.com/CliMA/ClimaUtilities.jl/pull/63)

v0.1.7
------

- Fix compatibility with ClimaComms 0.6. PR [#54](https://github.com/CliMA/ClimaUtilities.jl/pull/54)

v0.1.6
-------
- `OutputPathGenerator` now tries to create an active link when one is not available but some data is already there [#50](https://github.com/CliMA/ClimaUtilities.jl/pull/50)
- Fix compatibility with ClimaCore 0.14. PR [#50](https://github.com/CliMA/ClimaUtilities.jl/pull/50)

v0.1.5
-------
- Support passing down regridder and file reader arguments from higher level constructors. PR [#40](https://github.com/CliMA/ClimaUtilities.jl/pull/40)

v0.1.4
-------
- Fix and test MPI compatibility. PRs [#33](https://github.com/CliMA/ClimaUtilities.jl/pull/33), [#37](https://github.com/CliMA/ClimaUtilities.jl/pull/37)
- Select default regridder type if multiple are available. PR [#32](https://github.com/CliMA/ClimaUtilities.jl/pull/32)

v0.1.3
-------
- Add `DataStructures` module containing `LRUCache` object. PR [#35](https://github.com/CliMA/ClimaUtilities.jl/pull/35)
- Add `OutputPathGenerator`. PR [#28](https://github.com/CliMA/ClimaLand.jl/pull/28)

[badge-💥breaking]: https://img.shields.io/badge/💥BREAKING-red.svg
