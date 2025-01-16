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

plant = BOPTestPlant("http://api.boptest.net", testcase, dt=dt)

# Get available measurement points
mpts = plant.measurement_points
mdtable(mpts[1:3, :], latex=false) # hide
```
*(Output truncated)*

```@example 1
N = 100

# Get forecast data as well (for plotting later)
fc = getforecasts(plant, N * dt, dt)

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

The general idea is that the BOPTEST services are abstracted away as a `BOPTestPlant`, which only stores metadata about the plant such as the endpoints to use.

The package then defines common functions to operate on the plant, which are translated to REST API calls and the required data formattings.

### Initialization
Use the `BOPTestPlant` constructor:

```julia
dt = 900.0 # time step in seconds

testcase = "bestest_hydronic"
plant = BOPTestPlant("http://localhost", testcase, dt = dt)

# For old BOPTEST < v0.7, use the deprecated initboptest! function
old_plant = initboptest!("http://127.0.0.1:5000", dt = dt)
```

The initialization functions also query and store the available signals (as `DataFrame`),
since they are constant for a testcase. The signals are available as
* `plant.forecast_points`
* `plant.input_points`
* `plant.measurement_points`

### Interaction with the plant
The package then defines common functions to operate on the plant, namely
* `getforecasts`, `getmeasurements` to get the actual time series data for forecast or past measurements
* `getkpi` to get the KPI for the test case (calculated by BOPTEST)
* `advance!`, to step the plant one time step with user-specified control input
* `stop!`, to stop a test case (BOPTEST-Service only)

#### Querying data
The time series functions return a `DataFrame` with the time series. By default, a conversion to `Float64` is attempted (else the datatypes would be `Any`). You can use
the keyword argument `convert_f64=false` to disable conversion.

```julia
# Query forecast data for 24 hours, with 1/dt sampling frequency
# The column "Name" contains all available forecast signal names
fc = getforecasts(plant, 24*3600, dt, plant.forecast_points.Name)
```

#### Advancing
The `advance!` function requires the control inputs `u` as a `Dict`. Allowed control inputs are test case specific, but can be queried as property `input_points`.

```julia
ipts = plant.input_points

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
Stop a test case when no longer needed:

```julia
stop!(plant)
```

## API
```@docs
BOPTestPlant
initialize!
initboptest!
setscenario!
getforecasts
getmeasurements
getkpi
controlinputs
advance!
stop!
```
