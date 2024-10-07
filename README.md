# BOPTestAPI

[![Build Status](https://github.com/terion-io/BOPTestAPI.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/terion-io/BOPTestAPI.jl/actions/workflows/CI.yml?query=branch%3Amain)

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://terion-io.github.io/BOPTestAPI.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://terion-io.github.io/BOPTestAPI.jl/dev)

Some convenience functions for developing building controllers against the [BOPTEST framework](https://github.com/ibpsa/project1-boptest) in Julia.

## Info
This package can be used to develop building controllers against the BOPTEST REST API.

BOPTEST itself comes in two flavours, the "single-plant" [BOPTEST](https://github.com/ibpsa/project1-boptest) and the larger scale [BOPTEST-Service](https://github.com/NREL/boptest-service), which allows running many plants in parallel.

## Usage
The general idea is that the BOPTEST services are abstracted away as a `plant`, which only stores metadata about the plant such as the endpoints to use.

The package then defines common functions to operate on the plant, which are translated to REST API calls and the required data formattings.

### Initialization
There are two types of plants, depending on whether they run in BOPTEST or BOPTEST-Service:
* For normal BOPTEST (type `BOPTestPlant`), the test case is specified when starting the service, and there is no test ID since only a single plant is running.
* For BOPTEST-Service (type `BOPTestServicePlant`), the test case needs to be specified explicitly, and a `testid` UUID is returned by the server that is stored as plant metadata.

> [!TIP]
> Both types are subtypes of `AbstractBOPTestPlant` (Note: not exported), this can be useful for defining additional functions.

It is recommended to create plants using the initialization functions:

```julia
# BOPTEST_DEF_URL points to "127.0.0.1:5000", which is the BOPTEST default
# BOPTEST_SERVICE_DEF_URL points to "http://api.boptest.net", which is where
# NREL hosts the BOPTEST API

dt = 900.0 # time step in seconds
local_plant = initboptest!(BOPTEST_DEF_URL, dt)

# and / or
testcase = "bestest_hydronic"
remote_plant = initboptestservice!(BOPTEST_SERVICE_DEF_URL, testcase, dt)
```

### Interaction with the plant
The package then defines common functions to operate on the plant, namely
* `inputpoints`, `measurementpoints`, `forecastpoints` to query input, measurement, and forecast signal metadata respectively
* `getforecasts`, `getmeasurements` to get the actual time series data for forecast or past measurements
* `getkpi` to get the KPI for the test case (calculated by BOPTEST)
* `advance!`, to step the plant one time step with user-specified control input
* `stop!`, to stop a test case (BOPTEST-Service only)

#### Querying data
The signal metadata functions (`inputpoints(plant)`, ...) return a `Vector{Dict}`, while the time series functions return a `Dict{String, Vector}`. However, both can be passed 
directly to the `DataFrame` constructor without additional arguments. This allows for piping if one wishes.

```julia
mpts = DataFrame(measurementpoints(plant))

# or by piping
fcpts = plant |> forecastpoints |> DataFrame

# Query forecast data for 24 hours, with 1/dt sampling frequency
# The column "Name" contains all available forecast signal names
fc = getforecasts(plant, fcpts.Name, 24*3600, dt) |> DataFrame

# The DataFrames are by default untyped, so for good performance we should convert
# if possible
mapcols!(c -> Float64.(c), fc)
```

#### Advancing
The `advance!` function requires the control inputs `u` as a `Dict`. Allowed control inputs are test case specific, but can be queried with `inputpoints`.

```julia
ipts = DataFrame(inputpoints(plant))

# Alternative: Create a simple Dict directly
# This will by default overwrite all baseline values with the lowest allowed value
u = controlinputs(plant)

# Simulate 100 steps open-loop
res_ol = [advance!(plant, u) for _ = 1:100]
df_ol = DataFrame(res_ol)

# KPI
kpi = getkpi(plant)
```

#### Stop
When using BOPTEST-Service, be nice to NREL (or whoever is hosting) and stop a test case when no longer needed:

```julia
stop!(remote_plant)
```

This function does nothing when called on a "normal" `BOPTestPlant`
