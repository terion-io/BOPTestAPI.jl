module BOPTestAPI

export BOPTestPlant
export controlinputs
export initboptest!, initboptestservice!, advance!, stop!
export getforecasts, getmeasurements, getkpi
export BOPTEST_DEF_URL, BOPTEST_SERVICE_DEF_URL

using HTTP
using JSON
using DataFrames

"""
    const BOPTEST_DEF_URL = "http://127.0.0.1:5000"

Default URL when starting BOPTEST locally,
"""
const BOPTEST_DEF_URL = "http://127.0.0.1:5000"

"""
    const BOPTEST_SERVICE_DEF_URL = "http://api.boptest.net"

URL of the NREL BOPTEST-Service API.
"""
const BOPTEST_SERVICE_DEF_URL = "http://api.boptest.net"

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
    struct BOPTestPlant <: AbstractBOPTestPlant

Metadata for a BOPTEST plant.

"""
Base.@kwdef struct BOPTestPlant{EP <: AbstractBOPTestEndpoint} <: AbstractBOPTestPlant
    api_endpoint::EP
    testcase::AbstractString
    scenario::AbstractDict

    forecast_points::AbstractDataFrame
    input_points::AbstractDataFrame
    measurement_points::AbstractDataFrame
end

function Base.show(io::IO, plant::T) where {T <: AbstractBOPTestPlant}
    print(io, "$T(", plant.api_endpoint.base_url, ")")
end

function Base.show(io::IO, ::MIME"text/plain", plant::AbstractBOPTestPlant)
    show(io, plant)
    println()
    if plant.api_endpoint isa BOPTestServiceEndpoint
        println(io, "Test-ID: ", plant.api_endpoint.testid)
    end
    println(io, "Testcase: ", plant.testcase)
    println(io, "Scenario: ", plant.scenario)
end

## Private functions

function _getdata(endpoint::AbstractString, body; timeout = 30.0)
    put_hdr = ["Content-Type" => "application/json", "connecttimeout" => timeout]
    res = HTTP.put(endpoint, put_hdr, JSON.json(body))
    payload = JSON.parse(String(res.body))["payload"]

    d = Dict("time" => payload["time"])
    for col in body["point_names"]
        d[col] = payload[col]
    end

    return d
end


function _getpoints(endpoint::AbstractString)
	yvars_res = HTTP.get(endpoint)
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


## Public API
"""
    initboptestservice!(boptest_url, testcase, dt[; init_vals, scenario, verbose])

Initialize a testcase in BOPTEST service with step size dt.

# Arguments
- `boptest_url`: URL of the BOPTEST-Service API to initialize.
- `testcase` : Name of the test case.
- `dt`: Time step in seconds.
- `init_vals::Dict`: Parameters for the initialization.
- `scenario::Dict` : Parameters for scenario selection.
- `verbose::Bool`: Print something to stdout.

Return a `BOPTestServicePlant` instance, or throw an `ErrorException` on error.

"""
function initboptestservice!(
    boptest_url::AbstractString,
    testcase::AbstractString,
    dt::Real;
    kwargs...
)
    # Select testcase
    res = HTTP.post(
        "$boptest_url/testcases/$testcase/select",
        ["Content-Type" => "application/json"],
        JSON.json(Dict()) # This is needed as empty body
    )
    res.status != 200 && error("Could not select BOPTest testcase")

    payload = JSON.parse(String(res.body))
    testid = payload["testid"]

    api_endpoint = BOPTestServiceEndpoint(boptest_url, testid)

    return initboptest!(api_endpoint, dt; kwargs...)

end


"""
    initboptest!(boptest_url, dt[; init_vals, scenario, verbose])

Initialize the BOPTEST server with step size dt.

# Arguments
- `boptest_url`: URL of the BOPTEST server to initialize.
- `dt`: Time step in seconds.
- `init_vals::Dict`: Parameters for the initialization.
- `scenario::Dict` : Parameters for scenario selection.
- `verbose::Bool`: Print something to stdout.

Return a `BOPTestPlant` instance, or throw an `ErrorException` on error.

"""
function initboptest!(
    api_endpoint::AbstractBOPTestEndpoint,
    dt::Real;
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    scenario::Union{Nothing, AbstractDict} = nothing,
    verbose::Bool = false,
)

    # Initialize
    res = HTTP.put(
        api_endpoint("initialize"),
        ["Content-Type" => "application/json"],
        JSON.json(init_vals)
    )
    res.status != 200 && error("Error initializing testcase")

    # Set simulation step
    res = HTTP.put(
        api_endpoint("step"),
        ["Content-Type" => "application/json"],
        JSON.json(Dict("step" => dt))
    )
    res.status != 200 && error("Error setting time step")

    res = HTTP.get(api_endpoint("name"))
    testcase = JSON.parse(String(res.body))["payload"]["name"]
    verbose && println("Initialized testcase=$testcase with step=$(dt)s")
    
    # Set scenario (electricity prices, ...)
    if !isnothing(scenario)
        res = HTTP.put(
            api_endpoint("scenario"),
            ["Content-Type" => "application/json"],
            JSON.json(scenario)
        )
        verbose && println("Initialized scenario with ", repr(scenario))
    else
        scenario = Dict()
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

function initboptest!(boptest_url::AbstractString, args...; kwargs...)
    api_endpoint = BOPTestEndpoint(boptest_url)
    return initboptest!(api_endpoint, args...; kwargs...)
end


"""
    getkpi(plant::AbstractBOPTestPlant)

Get KPI from BOPTEST server as `Dict`.
"""
function getkpi(plant::AbstractBOPTestPlant)
    res = HTTP.get(plant.api_endpoint("kpi"))
    return JSON.parse(String(res.body))["payload"]
end


"""
    getmeasurements(plant::AbstractBOPTestPlant, starttime, finaltime[, points])

Query measurements from BOPTEST server and return as `DataFrame`.

# Arguments
- `plant` : The plant to query measurements from.
- `starttime::Real` : Start time for measurements time series, in seconds.
- `finaltime::Real` : Final time for measurements time series, in seconds.
- `points::AbstractVector{AbstractString}` : The measurement point names to query. Optional.
## Keyword Arguments
- `convert_f64::Bool` : whether to convert column types to `Float64`, default `true`. If
set to `false`, the columns will have type `Any`.

To obtain available measurement points, use `plant.measurement_points`, which is a 
`DataFrame` with a column `:Name` that contains all available signals.
"""
function getmeasurements(
    plant::AbstractBOPTestPlant,
    starttime::Real,
    finaltime::Real,
    points = plant.measurement_points.Name;
    convert_f64::Bool = true,
    kwargs...
)
    body = Dict(
        "point_names" => points,
        "start_time" => starttime,
        "final_time" => finaltime,
    )
    data = _getdata(plant.api_endpoint("results"), body; kwargs...)
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
    getforecasts(plant::AbstractBOPTestPlant, horizon, interval[, points])

Query forecast from BOPTEST server and return as `DataFrame`.

# Arguments
- `plant` : The plant to query forecast from.
- `horizon::Real` : Forecast time horizon from current time step, in seconds.
- `interval::Real` : Time step size for the forecast data, in seconds.
- `points::AbstractVector{AbstractString}` : The forecast point names to query. Optional.
## Keyword Arguments
- `convert_f64::Bool` : whether to convert column types to `Float64`, default `true`. If
set to `false`, the columns will have type `Any`.

Available forecast points are stored in `plant.forecast_points`. 
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

# Arguments
- `plant::AbstractBOPTestPlant`: Plant to advance.
- `u::AbstractDict`: Control inputs for the active test case.

Returns the payload as `Dict{String, Vector}`.
"""
function advance!(plant::AbstractBOPTestPlant, u::AbstractDict)
	res = HTTP.post(
		plant.api_endpoint("advance"),
		["Content-Type" => "application/json"],
		JSON.json(u);
		retry_non_idempotent=true
	)
	
	payload_dict = JSON.parse(String(res.body))["payload"]
    return payload_dict
end


"""
    stop!(plant::AbstractBOPTestPlant)

Stop a `BOPTestPlant` from running.

This method does nothing for plants run in normal BOPTEST 
(i.e. not BOPTEST-Service).
"""
function stop!(plant::BOPTestPlant{BOPTestServiceEndpoint})
    try
        res = HTTP.put(plant.api_endpoint("stop"))
        res.status == 200 && println(
            "Successfully stopped testid ", plant.api_endpoint.testid
        )
    catch e
        if e isa HTTP.Exceptions.StatusError
            payload = JSON.parse(String(e.response.body))
            println(payload["errors"][1]["msg"])
        else
            rethrow(e)
        end
    end
end

# Hopefully avoids user confusion
function stop!(::BOPTestPlant{BOPTestEndpoint})
    println("Only plants in BOPTEST-Service can be stopped")
end


"""
    controlinputs([f::Function, ]plant::AbstractBOPTestPlant)

Return `Dict` with control signals for BOPTEST.

This method calls `inputpoints(plant)` to gather available inputs,
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