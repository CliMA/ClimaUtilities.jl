# CallbackManager

This module contains functions that handle dates and times
in simulations. The functions in this module often call
functions from Julia's [Dates](https://docs.julialang.org/en/v1/stdlib/Dates/) module.

## CallbackManager API

```@docs
ClimaUtilities.CallbackManager.HourlyCallback
ClimaUtilities.CallbackManager.MonthlyCallback
ClimaUtilities.CallbackManager.Monthly
ClimaUtilities.CallbackManager.EveryTimestep
ClimaUtilities.CallbackManager.to_datetime
ClimaUtilities.CallbackManager.strdate_to_datetime
ClimaUtilities.CallbackManager.datetime_to_strdate
ClimaUtilities.CallbackManager.trigger_callback
```
