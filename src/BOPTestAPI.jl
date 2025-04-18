module BOPTestAPI

export BOPTestPlant, CachedBOPTestPlant
export forecast_points, input_points, measurement_points
export forecasts, inputs_sent, measurements
export controlinputs
export initboptest!, initialize!, advance!, setscenario!, stop!
export getforecasts, getmeasurements, getkpi, getstep

using HTTP
using JSON
using DataFrames
using Logging

const _DEF_TIMEOUT = 30

# const BOPTEST_DEF_URL = "http://127.0.0.1:5000"
Base.@deprecate_binding BOPTEST_DEF_URL "http://127.0.0.1:5000"

# const BOPTEST_SERVICE_DEF_URL = "http://api.boptest.net"
Base.@deprecate_binding BOPTEST_SERVICE_DEF_URL "http://api.boptest.net"

abstract type AbstractBOPTestEndpoint end

# BOPTEST-Service (https://github.com/NREL/boptest-service)
# runs several test cases in parallel
struct BOPTestEndpoint <: AbstractBOPTestEndpoint
    base_url::AbstractString
end

function (base::BOPTestEndpoint)(service::AbstractString)
    return "$(base.base_url)/$service"
end

# BOPTEST (https://github.com/ibpsa/project1-boptest/) 
# runs a single test case and thus doesn't have a testid
struct BOPTestServiceEndpoint <: AbstractBOPTestEndpoint
    base_url::AbstractString
    testid::AbstractString
end

function (base::BOPTestServiceEndpoint)(service::AbstractString)
    return "$(base.base_url)/$service/$(base.testid)"
end

abstract type AbstractBOPTestPlant end

"""
    BOPTestPlant(boptest_url, testcase[; dt, init_vals, scenario])

Initialize a testcase in BOPTEST service.

# Arguments
- `boptest_url::AbstractString`: URL of the BOPTEST-Service API to initialize.
- `testcase::AbstractString` : Name of the test case, \
[list here](https://ibpsa.github.io/project1-boptest/testcases/index.html).
## Keyword arguments
- `dt::Real`: Time step in seconds.
- `init_vals::AbstractDict`: Parameters for the initialization.
- `scenario::AbstractDict` : Parameters for scenario selection.

"""
Base.@kwdef struct BOPTestPlant{EP <: AbstractBOPTestEndpoint} <: AbstractBOPTestPlant
    api_endpoint::EP
    testcase::AbstractString
    scenario::AbstractDict

    forecast_points::AbstractDataFrame
    input_points::AbstractDataFrame
    measurement_points::AbstractDataFrame
end

function BOPTestPlant(
    boptest_url::AbstractString,
    testcase::AbstractString;
    kwargs...
)
    return _initboptestservice!(boptest_url, testcase; kwargs...)
end


"""
    CachedBOPTestPlant(boptest_url, testcase, N[; dt, init_vals, scenario])

[**Warning: Experimental**] Initialize a testcase in BOPTEST service, with a local cache.

In addition to the properties and methods of the normal `BOPTestPlant`, this type also
stores submitted inputs, received measurements, and the current forecast. These values
are updated when calling `advance!`.

# Arguments
- `boptest_url::AbstractString`: URL of the BOPTEST-Service API to initialize.
- `testcase::AbstractString`: Name of the test case, \
[list here](https://ibpsa.github.io/project1-boptest/testcases/index.html).
- `N::Int`: Forecast cache size
## Keyword arguments
See the documentation for `BOPTestPlant`.
"""
Base.@kwdef mutable struct CachedBOPTestPlant{EP <: AbstractBOPTestEndpoint} <: AbstractBOPTestPlant
    meta::BOPTestPlant{EP}

    dt::Float64 # Step size
    N::Int      # Forecast horizon

    forecasts::AbstractDataFrame
    inputs::AbstractDataFrame
    measurements::AbstractDataFrame
end

function CachedBOPTestPlant(
    boptest_url::AbstractString,
    testcase::AbstractString,
    N::Int;
    kwargs...
)
    meta = _initboptestservice!(boptest_url, testcase; kwargs...)

    dt = Float64(get(kwargs, :dt, getstep(meta)))

    forecasts = getforecasts(meta, N * dt, dt)
    measurements = getmeasurements(meta, 0, 0)
    inputs = _create_input_df(meta)

    return CachedBOPTestPlant(;
        meta,
        dt,
        N,
        forecasts,
        inputs,
        measurements,
    )
end

function Base.getproperty(p::CachedBOPTestPlant, s::Symbol)
    if s in fieldnames(BOPTestPlant)
        return getfield(p.meta, s)
    end
    return getfield(p, s)
end

function Base.propertynames(::CachedBOPTestPlant)
    return (fieldnames(BOPTestPlant)..., :dt, :N, :forecasts, :inputs, :measurements)
end

function Base.show(io::IO, plant::T) where {T <: AbstractBOPTestPlant}
    print(io, "$T(", plant.api_endpoint.base_url, ")")
end

function Base.show(io::IO, ::MIME"text/plain", plant::AbstractBOPTestPlant)
    show(io, plant)
    println(io)
    if plant.api_endpoint isa BOPTestServiceEndpoint
        println(io, "Test-ID: ", plant.api_endpoint.testid)
    end
    println(io, "Testcase: ", plant.testcase)
    println(io, "Scenario: ", plant.scenario)
    if plant isa CachedBOPTestPlant
        println(io, "Cached forecast horizon: ", plant.N)
    end
end

## Private functions
function _batch_timestamps(
    starttime::Real, finaltime::Real, dt::Real, n_points::Int; batch_target::Int = 10_000
)
    plant_timesteps = starttime:dt:finaltime

    di = batch_target ÷ n_points
    query_timesteps = plant_timesteps[1:di:end]
    if !(finaltime in query_timesteps)
        query_timesteps = [query_timesteps; finaltime]
    end
    if length(query_timesteps) == 1
        query_timesteps = [query_timesteps; query_timesteps]
    end

    return query_timesteps
end

function _complete_inputs(u::AbstractDict, cols)
    u = Dict{String, Union{Int, Float64, Missing}}(u...)
    for c in cols
        if !haskey(u, c)
            u[c] = missing
        end
    end
    return u
end

function _create_measurement_df(plant::AbstractBOPTestPlant)
    mcols = [plant.measurement_points.Name; plant.input_points.Name; "time"]
    return DataFrame([name => Float64[] for name in mcols])
end

function _create_input_df(plant::AbstractBOPTestPlant)
    override_sigs = subset(
        plant.input_points,
        :Name => s -> endswith.(s, "_activate")
    )
    u_sigs = subset(plant.input_points, :Name => s -> endswith.(s, "_u"))
    int_input_cols = [name => Union{Int, Missing}[] for name in sort(override_sigs.Name)]
    float_input_cols = [name => Union{Float64, Missing}[] for name in sort(u_sigs.Name)]

    length(int_input_cols) == length(float_input_cols) || error(
        "Number of '_activate' and '_u' inputs does not match"
    )
    
    inputs = DataFrame(:time => Float64[])
    for (act_col, val_col) in zip(int_input_cols, float_input_cols)
        insertcols!(inputs, act_col, val_col)
    end

    return inputs
end

function _getdata(endpoint::AbstractString, body; timeout = _DEF_TIMEOUT)
    put_hdr = ["Content-Type" => "application/json"]
    res = HTTP.put(endpoint, put_hdr, JSON.json(body), readtimeout = timeout)
    payload = JSON.parse(String(res.body))["payload"]

    d = Dict("time" => payload["time"])
    for col in body["point_names"]
        d[col] = payload[col]
    end

    return d
end

function _getpoints(endpoint::AbstractString; timeout = _DEF_TIMEOUT)
    yvars_res = HTTP.get(endpoint, readtimeout = timeout)
    yvars_dict = JSON.parse(String(yvars_res.body))["payload"]
    yvars = []
    for (k, v_dict) in yvars_dict
        # Replace nothing with missing; not beautiful but explicit
        for (vk, vv) in v_dict
            if isnothing(vv)
                v_dict[vk] = missing
            end
        end
        _d = Dict("Name" => k, v_dict...)
        push!(yvars, _d)
    end

    return yvars
end

function _initboptestservice!(
    boptest_url::AbstractString,
    testcase::AbstractString;
    timeout = _DEF_TIMEOUT,
    kwargs...
)
    # Select testcase
    res = try
        HTTP.post(
            "$boptest_url/testcases/$testcase/select",
            ["Content-Type" => "application/json"],
            JSON.json(Dict()), # This is needed as empty body
            readtimeout = timeout,
        )
    catch e
        if e isa HTTP.Exceptions.TimeoutError
            @error "TimeoutError. Hint: Check available number of workers"
        end
        rethrow(e)
    end

    res.status != 200 && error("Could not select BOPTest testcase")

    payload = JSON.parse(String(res.body))
    testid = payload["testid"]

    api_endpoint = BOPTestServiceEndpoint(boptest_url, testid)

    plant = try
        _initboptest!(api_endpoint; timeout, kwargs...)
    catch e
        HTTP.put(api_endpoint("stop"), readtimeout = timeout)
        rethrow(e)
    end

    return plant
end

function _initboptest!(
    api_endpoint::AbstractBOPTestEndpoint;
    dt::Union{Nothing, Real} = nothing,
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    scenario::Union{Nothing, AbstractDict} = nothing,
    timeout::Real = _DEF_TIMEOUT,
)
    initialize!(api_endpoint; init_vals, timeout)

    # Set simulation step
    if !isnothing(dt)
        res = HTTP.put(
            api_endpoint("step"),
            ["Content-Type" => "application/json"],
            JSON.json(Dict("step" => dt)),
            readtimeout = timeout,
        )
        res.status != 200 && error("Error setting time step")
    end

    res = HTTP.get(api_endpoint("name"), readtimeout = timeout)
    testcase = JSON.parse(String(res.body))["payload"]["name"]
    @info "Initialized testcase = '$testcase'"
    
    # Set scenario (electricity prices, ...)
    scenario = if !isnothing(scenario)
        sc = setscenario!(api_endpoint, scenario; timeout)
        @info "Initialized scenario with " scenario
        sc
    else
        res = HTTP.get(api_endpoint("scenario"), readtimeout = timeout)
        JSON.parse(String(res.body))["payload"]
    end

    forecast_points = DataFrame(_getpoints(api_endpoint("forecast_points")))
    input_points = DataFrame(_getpoints(api_endpoint("inputs")))
    measurement_points = DataFrame(_getpoints(api_endpoint("measurements")))

    return BOPTestPlant(
        api_endpoint,
        testcase,
        scenario,
        forecast_points,
        input_points,
        measurement_points,
    )
end

## Public API
@deprecate initboptestservice!(boptest_url, testcase, dt; kwargs...) BOPTestPlant(boptest_url, testcase; dt, kwargs...)


## Accessor methods
"""
    forecast_points(p::AbstractBOPTestPlant)

Return forecast points as `DataFrame`.
"""
forecast_points(p::AbstractBOPTestPlant) = copy(p.forecast_points)

"""
    input_points(p::AbstractBOPTestPlant)

Return forecast points as `DataFrame`.
"""
input_points(p::AbstractBOPTestPlant) = copy(p.input_points)

"""
    measurement_points(p::AbstractBOPTestPlant)

Return measurement points as `DataFrame`.
"""
measurement_points(p::AbstractBOPTestPlant) = copy(p.measurement_points)


"""
    forecasts(p::CachedBOPTestPlant)
    forecasts(p::CachedBOPTestPlant; rows, columns)

Return forecasts from current time step as `DataFrame`.

Use valid row and column selectors from `DataFrames.jl` for the keyword arguments.
"""
forecasts(
    p::CachedBOPTestPlant;
    rows = axes(p.forecasts, 1),
    columns = All(),
) = p.forecasts[rows, columns]

"""
    inputs_sent(p::CachedBOPTestPlant)
    inputs_sent(p::CachedBOPTestPlant; rows, columns)

Return past inputs sent to the plant as `DataFrame`.

Note that this contains values as sent; if out of bounds, the plant might use other values.
Use `measurements` to get a `DataFrame` with the actually used inputs. In case the default
was used for a signal, the entry here will be `missing`.
Use valid row and column selectors from `DataFrames.jl` for the keyword arguments.
"""
inputs_sent(
    p::CachedBOPTestPlant;
    rows = axes(p.inputs, 1),
    columns = All(),
) = p.inputs[rows, columns]

"""
    measurements(p::CachedBOPTestPlant)
    measurements(p::CachedBOPTestPlant; rows, columns)

Return measurements as `DataFrame`.

Unlike `getmeasurements(p, ...)`, this method uses the local cache. This also means
that the time step corresponds to the controller time step.
Use valid row and column selectors from `DataFrames.jl` for the keyword arguments.
"""
measurements(
    p::CachedBOPTestPlant;
    rows = axes(p.measurements, 1),
    columns = All(),
) = p.measurements[rows, columns]


"""
    initialize!(api_endpoint::AbstractBOPTestEndpoint; init_vals, timeout)
    initialize!(plant::AbstractBOPTestPlant; init_vals, timeout)

# Arguments
## Keyword arguments
- `init_vals::AbstractDict`: Parameters for the initialization. Default is \
`Dict("start_time" => 0, "warmup_period" => 0)`.
- `timeout::Real`: Timeout for the BOPTEST-Service API, in seconds. Default is 30.

(Re-)Initialize the plant and return the payload from the BOPTEST-Service API.
Also re-initializes the caches for a `CachedBOPTestPlant`.
"""
function initialize!(
    api_endpoint::AbstractBOPTestEndpoint;
    init_vals::AbstractDict = Dict("start_time" => 0, "warmup_period" => 0),
    timeout::Real = _DEF_TIMEOUT,
)
    res = HTTP.put(
        api_endpoint("initialize"),
        ["Content-Type" => "application/json"],
        JSON.json(init_vals),
        readtimeout = timeout,
    )

    payload_dict = JSON.parse(String(res.body))["payload"]
    return payload_dict
end

initialize!(p::BOPTestPlant; kwargs...) = initialize!(p.api_endpoint; kwargs...)

function initialize!(plant::CachedBOPTestPlant; kwargs...)
    res = initialize!(plant.meta)

    plant.forecasts = getforecasts(plant.meta, plant.N * plant.dt, plant.dt)
    plant.measurements = getmeasurements(plant.meta, 0, 0)
    plant.inputs = _create_input_df(plant.meta)
    return res
end

"""
    setscenario!(api_endpoint::AbstractBOPTestEndpoint, d; timeout)
    setscenario!(plant::AbstractBOPTestPlant, d; timeout)

# Arguments
- `d::AbstractDict`: Parameters for scenario selection.
## Keyword arguments
- `timeout::Real`: Timeout for the BOPTEST-Service API, in seconds. Default is 30.

Set the scenario for a BOPTEST plant and return the selected scenario.
"""
function setscenario!(
    api_endpoint::AbstractBOPTestEndpoint,
    d::AbstractDict;
    timeout::Real = _DEF_TIMEOUT,
)
    res = HTTP.put(
        api_endpoint("scenario"),
        ["Content-Type" => "application/json"],
        JSON.json(d),
        readtimeout = timeout,
    )

    res = HTTP.get(api_endpoint("scenario"), readtimeout = timeout)
    payload_dict = JSON.parse(String(res.body))["payload"]
    return payload_dict
end

setscenario!(p::AbstractBOPTestPlant, d; kwargs...) = setscenario!(p.api_endpoint, d; kwargs...)


"""
    initboptest!(boptest_url[; dt, init_vals, scenario])

[**Warning:** Deprecated.] Initialize the local BOPTEST server.

# Arguments
- `boptest_url::AbstractString`: URL of the BOPTEST server to initialize.
## Keyword arguments
- `dt::Real`: Time step in seconds.
- `init_vals::AbstractDict`: Parameters for the initialization.
- `scenario::AbstractDict` : Parameters for scenario selection.

Return a `BOPTestPlant` instance, or throw an `ErrorException` on error.

**Warning:** This function is deprecated, since BOPTEST v0.7 switched to the
BOPTEST-Service API. Use it for a locally deployed `BOPTEST < v0.7`.

"""
function initboptest!(
    api_endpoint::AbstractBOPTestEndpoint;
    dt::Union{Nothing, Real} = nothing,
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    scenario::Union{Nothing, AbstractDict} = nothing,
    timeout::Real = _DEF_TIMEOUT,
)
    Base.depwarn(
        "`initboptest!` is deprecated since v0.3.0 and will be removed" *
        " from the public API in a future release.",
        initboptest!,
    )

    return _initboptest!(api_endpoint; dt, init_vals, scenario, timeout)
end

function initboptest!(boptest_url::AbstractString, args...; kwargs...)
    api_endpoint = BOPTestEndpoint(boptest_url)
    return initboptest!(api_endpoint, args...; kwargs...)
end

"""
    getkpi(plant::AbstractBOPTestPlant)

Get KPI from BOPTEST server as `Dict`.
"""
function getkpi(plant::AbstractBOPTestPlant; timeout::Real = _DEF_TIMEOUT)
    res = HTTP.get(plant.api_endpoint("kpi"), readtimeout = timeout)
    return JSON.parse(String(res.body))["payload"]
end


"""
    getstep(plant::AbstractBOPTestPlant; timeout = _DEF_TIMEOUT)

Get plant time step as `Float64`.
"""
function getstep(plant::AbstractBOPTestPlant; timeout::Real = _DEF_TIMEOUT)
    res = HTTP.get(plant.api_endpoint("step"), readtimeout = timeout)
    payload = JSON.parse(String(res.body))["payload"]
    return Float64(payload)
end


"""
    getmeasurements(plant, starttime, finaltime[, points])

Query measurements from BOPTEST server and return as `DataFrame`.

# Arguments
- `plant::AbstractBOPTestPlant` : The plant to query measurements from.
- `starttime::Real` : Start time for measurements time series, in seconds.
- `finaltime::Real` : Final time for measurements time series, in seconds.
- `points::AbstractVector{AbstractString}` : The measurement point names to query. Optional.
## Keyword Arguments
- `convert_f64::Bool` : whether to convert column types to `Float64`, default `true`. \
If set to `false`, the columns will have type `Any`.

To obtain available points, use `measurement_points(plant)` and `input_points(plant),
which each return a `DataFrame` with a column `:Name` that contains all available signals.
"""
function getmeasurements(
    plant::AbstractBOPTestPlant,
    starttime::Real,
    finaltime::Real,
    points = [plant.input_points.Name; plant.measurement_points.Name];
    convert_f64::Bool = true,
    kwargs...
)
    # Plant will run at max 30 sec timestep
    dt = min(getstep(plant), 30.0)
    query_timesteps = _batch_timestamps(starttime, finaltime, dt, length(points))

    n_batches = length(query_timesteps)
    if n_batches > 100
        @info "Fetching $n_batches batches of measurement data"
    end
    
    # Type needed for dispatching on correct reduce(vcat, dfs) later
    dfs::Vector{DataFrame} = []
    for (ts, te) in zip(query_timesteps[1:end-1], query_timesteps[2:end])
        body = Dict(
            "point_names" => points,
            "start_time" => ts,
            "final_time" => te,
        )
        data = _getdata(plant.api_endpoint("results"), body; kwargs...)
        push!(dfs, DataFrame(data))
    end

    all_data = reduce(vcat, dfs, cols = :intersect)
    unique!(all_data, :time)

    if convert_f64
        try
            mapcols!(c -> Float64.(c), all_data)
        catch e
            @warn "Error converting to Float64: $(e)"
        end
    end
    return all_data
end


"""
    getforecasts(plant, horizon, interval[, points])

Query forecast from BOPTEST server and return as `DataFrame`.

# Arguments
- `plant::AbstractBOPTestPlant` : The plant to query forecast from.
- `horizon::Real` : Forecast time horizon from current time step, in seconds.
- `interval::Real` : Time step size for the forecast data, in seconds.
- `points::AbstractVector{AbstractString}` : The forecast point names to query. Optional.
## Keyword Arguments
- `convert_f64::Bool` : whether to convert column types to `Float64`, default `true`. \
If set to `false`, the columns will have type `Any`.

Available forecast points are available using `forecast_points(plant)`. 
"""
function getforecasts(
    plant::AbstractBOPTestPlant,
    horizon::Real,
    interval::Real,
    points = plant.forecast_points.Name;
    convert_f64::Bool = true,
    kwargs...
)
    body = Dict(
        "point_names" => points,
        "horizon" => horizon,
        "interval" => interval
    )
    data = _getdata(plant.api_endpoint("forecast"), body; kwargs...)
    df = DataFrame(data)
    if convert_f64
        try
            mapcols!(c -> Float64.(c), df)
        catch e
            @warn "Error converting to Float64: $(e)"
        end
    end
    return df
end


"""
    advance!(plant::AbstractBOPTestPlant, u::AbstractDict)

Step the plant using control input u.

Returns the payload as `Dict{String, Vector}`.
"""
function advance!(
    plant::BOPTestPlant,
    u::AbstractDict;
    timeout::Real = _DEF_TIMEOUT,
)
    res = HTTP.post(
        plant.api_endpoint("advance"),
        ["Content-Type" => "application/json"],
        JSON.json(u);
        readtimeout = timeout,
        retry_non_idempotent = true
    )

    payload_dict = JSON.parse(String(res.body))["payload"]
    return payload_dict
end

function advance!(
    plant::CachedBOPTestPlant,
    u::AbstractDict;
    timeout::Real = _DEF_TIMEOUT,
)
    payload = advance!(plant.meta, u; timeout)

    fc = getforecasts(plant, plant.N * plant.dt, plant.dt)
    deleteat!(plant.forecasts, 1)
    push!(plant.forecasts, fc[end, :])

    push!(plant.measurements, payload)
    all_inputs = _complete_inputs(u, plant.input_points.Name)
    all_inputs["time"] = fc[1, :time] - plant.dt
    push!(plant.inputs, all_inputs)
    
    return payload
end


function _stop!(url::AbstractString, log_testid::AbstractString; timeout::Real = _DEF_TIMEOUT)
    try
        r = HTTP.put(url, readtimeout = timeout)
        if r.status == 200
            @info "Successfully stopped testid $log_testid"
        end
    catch e
        if e isa HTTP.Exceptions.StatusError
            payload = JSON.parse(String(e.response.body))
            msg = payload["errors"][1]["msg"]
            @warn "StatusError when stopping plant" msg
        else
            rethrow(e)
        end
    end
end

"""
    stop!(plant::AbstractBOPTestPlant)
    stop!([base_url = "http://localhost",] testid::AbstractString)

Stop a `BOPTestPlant` from running.

This method does nothing for plants run in normal BOPTEST 
(i.e. not BOPTEST-Service).
"""
function stop!(plant::BOPTestPlant{BOPTestServiceEndpoint}; kwargs...)
    _stop!(plant.api_endpoint("stop"), plant.api_endpoint.testid; kwargs...)
    return nothing
end

stop!(p::CachedBOPTestPlant; kwargs...) = stop!(p.meta; kwargs...)

function stop!(base_url::AbstractString, testid::AbstractString; kwargs...)
    _stop!("$(base_url)/stop/$(testid)", testid; kwargs...)
    return nothing
end

stop!(testid::AbstractString; kwargs...) = stop!("http://localhost", testid; kwargs...)

# Hopefully avoids user confusion
function stop!(::BOPTestPlant{BOPTestEndpoint}; kwargs...)
    @warn "Only plants in BOPTEST-Service can be stopped"
    return nothing
end


"""
    controlinputs([f::Function, ]plant::AbstractBOPTestPlant)

Return `Dict` with control signals for BOPTEST.

This method calls `input_points(plant)` to gather available inputs,
and then creates a `Dict` with the available inputs as keys and
default values defined by function `f`.

`f` is a function that is applied to a `DataFrame` constructed from
the input points that have a suffix "_u", i.e. control inputs. The `DataFrame`
normally has columns `:Name`, `:Minimum`, `:Maximum`, `:Unit`, `:Description`.

The default for `f` is `df -> df[!, :Minimum]`, i.e. use the minimum allowed 
input.
"""
function controlinputs(f::Function, plant::AbstractBOPTestPlant)
    # Default for u: override all controls -> "*_activate" = 1
    # and send u = dfmap(Name)
    override_sigs = subset(
        plant.input_points,
        :Name => s -> endswith.(s, "_activate")
    )
    u_sigs = subset(plant.input_points, :Name => s -> endswith.(s, "_u"))

    u = Dict(
        Pair.(override_sigs.Name, 1)...,
        Pair.(u_sigs.Name, f(u_sigs))...,
    )
    return u
end

controlinputs(p::AbstractBOPTestPlant) = controlinputs(df -> df[!, :Minimum], p)

end