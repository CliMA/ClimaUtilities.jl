ClimaUtilities.jl Release Notes
===============================

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
