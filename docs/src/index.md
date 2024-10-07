# BOPTestAPI.jl

## Quickstart
### Installation
`BOPTestAPI` is available from the Julia general registry. Thus, you can add it like
```julia
import Pkg; Pkg.add("BOPTestAPI")
```

### Self-contained example
See further below for some explanations.

```@example 1
using BOPTestAPI
using DataFrames
using Plots
using Latexify # hide

dt = 900.0 # time step in seconds
testcase = "bestest_hydronic"

plant = initboptestservice!(BOPTEST_SERVICE_DEF_URL, testcase, dt)

# Get available measurement points
mpts = plant |> measurementpoints |> DataFrame
mdtable(mpts[1:3, :], latex=false) # hide
```
*(Output truncated)*

```@example 1
N = 100

# Get forecast data as well (for plotting later)
fcpts = plant |> forecastpoints |> DataFrame
fc = getforecasts(plant, fcpts.Name, N * dt, dt) |> DataFrame

# Run N time steps of baseline control
res = []
for t = 1:N
    u = Dict() # here you would put your own controller
    y = advance!(plant, u)
    push!(res, y)
end
stop!(plant)

dfres = DataFrame(res)
mdtable(mapcols(c -> round.(c, digits=2), dfres[1:5, 3:6]), latex=false) # hide
```
*(Output truncated in both columns and rows)*

**And that's it!** You successfully simulated a building HVAC system in the cloud using 
BOPTEST-Service. The following code will just make some plots of the results.
```@example 1
# typecast forecast to Float64
mapcols!(c -> Float64.(c), fc)
# Create single df with all data
df = leftjoin(dfres, fc, on = :time => :time)

pl1 = plot(
    df.time ./ 3600,
    Matrix(df[!, ["reaTRoo_y", "LowerSetp[1]"]]);
    xlabel="t [h]",
    ylabel="T [K]",
    labels=["actual" "target"],
)
pl2 = plot(
    df.time ./ 3600, df.reaQHea_y ./ 1000;
    xlabel="t [h]",
    ylabel="Qdot [kW]",
    labels="Heating"
)
plot(pl1, pl2; layout=(2, 1))
```

## Usage
(See also the [README on Github](https://github.com/terion-io/BOPTestAPI.jl))

The general idea is that the BOPTEST services are abstracted away as a `plant`, which only stores metadata about the plant such as the endpoints to use.

The package then defines common functions to operate on the plant, which are translated to REST API calls and the required data formattings.

### Initialization
There are two types of plants, depending on whether they run in BOPTEST or BOPTEST-Service:
* For normal BOPTEST (type `BOPTestPlant`), the test case is specified when starting the service, and there is no test ID since only a single plant is running.
* For BOPTEST-Service (type `BOPTestServicePlant`), the test case needs to be specified explicitly, and a `testid` UUID is returned by the server that is stored as plant metadata.

It is recommended to create plants using the initialization functions:

```julia
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


## API
```@docs
BOPTEST_DEF_URL
BOPTEST_SERVICE_DEF_URL
BOPTestPlant
BOPTestServicePlant
initboptest!
initboptestservice!
forecastpoints
inputpoints
measurementpoints
getforecasts
getmeasurements
getkpi
controlinputs
advance!
stop!
```
