# TimeManager

This module contains functions that handle dates and times
in simulations. The functions in this module often call
functions from Julia's [Dates](https://docs.julialang.org/en/v1/stdlib/Dates/) module.

## TimeManager API

```@docs
ClimaUtilities.TimeManager.to_datetime
ClimaUtilities.TimeManager.strdate_to_datetime
ClimaUtilities.TimeManager.datetime_to_strdate
ClimaUtilities.TimeManager.trigger_callback
ClimaUtilities.TimeManager.Monthly
ClimaUtilities.TimeManager.EveryTimestep
```
