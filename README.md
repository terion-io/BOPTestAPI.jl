# BOPTestAPI

[![Build Status](https://github.com/terion-io/BOPTestAPI.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/terion-io/BOPTestAPI.jl/actions/workflows/CI.yml?query=branch%3Amain)

[![](https://img.shields.io/badge/docs-stable-blue.svg)](https://terion-io.github.io/BOPTestAPI.jl/stable)
[![](https://img.shields.io/badge/docs-dev-blue.svg)](https://terion-io.github.io/BOPTestAPI.jl/dev)

Some convenience functions for developing building controllers against the [BOPTEST framework](https://github.com/ibpsa/project1-boptest) in Julia.

## Info
This package can be used to develop building controllers against the BOPTEST REST API.

BOPTEST itself comes in two flavours, the "single-plant" [BOPTEST](https://github.com/ibpsa/project1-boptest) and the larger scale [BOPTEST-Service](https://github.com/NREL/boptest-service), which allows running many plants in parallel.

## Usage
The general idea is that the BOPTEST services are abstracted away as a `BOPTestPlant`, which only stores metadata about the plant such as the endpoints to use.

The package then defines common functions to operate on the plant, which are translated to REST API calls and the required data formattings.

### Initialization
There are two types of plants:
* `BOPTestPlant` to store metadata and provide access methods.
* `CachedBOPTestPlant`, which in addition also caches inputs, forecasts (up to a horizon), and measurements.

The types are parametrized, depending on whether they run in BOPTEST or BOPTEST-Service:
* For local BOPTEST `< v0.7`, the test case is specified when starting the service (i.e. outside of Julia). Use `initboptest!(url)` for connecting to the plant. It has type `BOPTestPlant{BOPTestEndpoint}`.
* For BOPTEST `>= v0.7` or remote plants, the test case needs to be specified explicitly, and a `testid` UUID is returned by the server that is stored as endpoint metadata.
  * Use `BOPTestPlant(url, testcase)` to create a plant without cache. It has type `BOPTestPlant{BOPTestServiceEndpoint}`.
  * Use `CachedBOPTestPlant(url, testcase, horizon)` to create a plant with cache. It has type `CachedBOPTestPlant{BOPTestServiceEndpoint}`.


> [!IMPORTANT]
> BOPTEST from version `v0.7.0` uses the BOPTEST-service API even on local deployment. Thus, since BOPTestAPI v0.3, the `BOPTestPlant` constructor is overloaded and can be used directly.

> [!TIP]
> For a plant instance, `plant.api_endpoint(service)` is callable and returns the endpoint of a specific service as `String`, this can be useful for defining additional functions.
> E.g. `plant.api_endpoint("advance")` for a plant on `localhost` with internal testid `"a-b-c-d"` returns `"http://localhost/advance/a-b-c-d"`.

```julia
testcase = "bestest_hydronic"
# NREL hosts the BOPTEST API "http://api.boptest.net"
remote_plant = BOPTestPlant("http://api.boptest.net", testcase)

local_plant = BOPTestPlant("http://localhost", testcase)

# !! Note: For BOPTEST < v0.7 use this for local deployed test cases
# The test case is then set when starting up BOPTEST
local_plant = initboptest!("http://127.0.0.1:5000")

```

The initialization functions also query and store the available signals (as `DataFrame`),
since they are constant for a testcase. The signals are available as
* `forecast_points(plant)`
* `input_points(plant)`
* `measurement_points(plant)`

### Interaction with the plant
The package then defines common functions to operate on the plant, namely
* `getforecasts`, `getmeasurements` to get the actual time series data for forecast or past measurements
* `getkpi` to get the KPI for the test case (calculated by BOPTEST)
* `advance!`, to step the plant one time step with user-specified control input
* `initialize!` to re-initialize the plant
* `setscenario!` to set the scenerio on an existing plant
* `stop!`, to stop a test case

#### Querying data
The time series functions return a `DataFrame` with the time series. By default, a conversion to `Float64` is attempted (else the datatypes would be `Any`). You can use
the keyword argument `convert_f64=false` to disable conversion.

```julia
# Query forecast data for 24 hours, with 1/dt sampling frequency
dt = 900.0
fc = getforecasts(plant, 24*3600, dt)
```

#### Advancing
The `advance!` function requires the control inputs `u` as a `Dict`.

```julia
# This will by default overwrite all baseline values with the lowest allowed value
u = controlinputs(plant)

# Simulate 100 steps open-loop
res_ol = [advance!(plant, u) for _ = 1:100]
df_ol = DataFrame(res_ol)

# KPI
kpi = getkpi(plant)
```

#### Stop
Stop a test case when no longer needed:

```julia
stop!(plant)
```