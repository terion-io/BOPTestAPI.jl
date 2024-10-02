module BOPTestAPI

export BOPTestServicePlant, BOPTestPlant
export SignalTransform, controlinputs, plantoutputs
export initboptest!, initboptestservice!, advance!, openloopsim!, stop!
export forecastpoints, inputpoints, measurementpoints
export getforecast, getresults, getkpi
export BOPTEST_DEF_URL, BOPTEST_SERVICE_DEF_URL

using HTTP
using JSON
using DataFrames

const BOPTEST_DEF_URL = "http://127.0.0.1:5000"
const BOPTEST_SERVICE_DEF_URL = "http://api.boptest.net"

abstract type AbstractBOPTestPlant end

# BOPTEST-Service (https://github.com/NREL/boptest-service)
# runs several test cases in parallel
Base.@kwdef struct BOPTestServicePlant <: AbstractBOPTestPlant
    boptest_url::AbstractString
    testid::AbstractString
    testcase::AbstractString
    scenario::AbstractDict
end

# BOPTEST (https://github.com/ibpsa/project1-boptest/) 
# runs a single test case and thus doesn't have a testid
Base.@kwdef struct BOPTestPlant <: AbstractBOPTestPlant
    boptest_url::AbstractString
    testcase::AbstractString
    scenario::AbstractDict
end

## Private functions
@inline function _endpoint(plant::BOPTestServicePlant, service::AbstractString)
    return "$(plant.boptest_url)/$service/$(plant.testid)"
end

@inline function _endpoint(plant::BOPTestPlant, service::AbstractString)
    return "$(plant.boptest_url)/$service"
end


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


function _getpoints(plant::AbstractBOPTestPlant, path)
    endpoint = _endpoint(plant, path)
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
    SignalTransform(names, transform)

Bundle information for transforming data to and from BOPTEST.

# Arguments
- names : Vector of signal names. **OBS:** Leave out suffixes 
'_u' and '_activate' for control signals.
- transform : Function to transform between BOPTEST and controller.
"""
struct SignalTransform
    names::AbstractVector{AbstractString}
    transform::Function
end


"""
    controlinputs(transformer, u, overwrite)

Return `Dict` with control signals for BOPTEST.

The function calls the transform on `u`, and then creates
a `Dict` with 2 entries per signal name in `transformer`:
1. `"<signal_name>_u" => u`
2. `"<signal_name>_activate" => overwrite`
"""
function controlinputs(
    transformer::SignalTransform,
    u::AbstractVector,
    overwrite::AbstractVector{<:Integer}
)
    u = transformer.transform(u)
    d = Dict{AbstractString, Any}()
    for (i, s) in enumerate(transformer.names)
        d[s * "_u"] = u[i]
        d[s * "_activate"] = Int(overwrite[i])			
    end
    return d
end


function controlinputs(dfmap::Function, plant::AbstractBOPTestPlant)
    # Default for u: override all controls -> "*_activate" = 1
    # and send u = dfmap(Name)
    inputs = DataFrame(inputpoints(plant))
    override_sigs = subset(inputs, :Name => s -> endswith.(s, "_activate"))
    u_sigs = subset(inputs, :Name => s -> endswith.(s, "_u"))

    u = Dict(
        Pair.(override_sigs.Name, 1)...,
        Pair.(u_sigs.Name, dfmap(u_sigs))...,
    )
    return u
end

controlinputs(p::AbstractBOPTestPlant) = controlinputs(df -> df[!, :Minimum], p)


"""
    plantoutput(transformer, d)

Return `Matrix` with scaled outputs from BOPTEST.

The function unpacks `d::Dict` into a matrix where each row
corresponds to a signal entry that is both in the dict and in
`transformer.names`, and multiple values (i.e. time) are in the
column dimension.
"""
function plantoutputs(transformer::SignalTransform, d::AbstractDict)
    m = length(d[transformer.names[1]])
    x = zeros(length(transformer.names), m)
    for (i, s) in enumerate(transformer.names)
        # If scalar value returned (e.g. from /advance), broadcast
        # since the array is 2D (but with ncols=1)
        x[i, :] .= d[s]
    end
    return transformer.transform(x)
end


"""
    initboptestservice!(boptest_url, testcase, dt[; init_vals, scenario, verbose])

Initialize a testcase in BOPTEST service with step size dt.

# Arguments
- `boptest_url`: URL of the BOPTEST server to initialize.
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
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    scenario::Union{Nothing, AbstractDict} = nothing,
    verbose::Bool = false,
)
    # Select testcase
    res = HTTP.post(
        "$boptest_url/testcases/$testcase/select",
        ["Content-Type" => "application/json"],
        JSON.json(init_vals)
    )
    res.status != 200 && error("Could not select BOPTest testcase")

    payload = JSON.parse(String(res.body))
    testid = payload["testid"]

    # Set simulation step
    init_vals = Dict(init_vals..., "step" => dt)
    res = HTTP.put(
        "$boptest_url/initialize/$testid",
        ["Content-Type" => "application/json"],
        JSON.json(init_vals)
    )
    res.status != 200 && error("Error initializing testcase")

    verbose && println("Initialized testcase=$testcase with step=$dt s")

    if !isnothing(scenario)
        res = HTTP.put(
            "$boptest_url/scenario/$testid",
            ["Content-Type" => "application/json"],
            JSON.json(scenario)
        )
        verbose && println("Initialized scenario with ", repr(scenario))
    else
        scenario = Dict()
    end

    return BOPTestServicePlant(; boptest_url, testid, testcase, scenario)
end


function stop!(plant::BOPTestServicePlant)
    try
        res = HTTP.put(_endpoint(plant, "stop"))
        res.status == 200 && println("Successfully stopped testid ", plant.testid)
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
stop!(p::BOPTestPlant) = println("Only plants in BOPTEST-Service can be stopped")


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
    boptest_url::AbstractString,
    dt::Real;
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    scenario::Union{Nothing, AbstractDict} = nothing,
    verbose::Bool = false,
)
    # Set simulation step
    init_vals = Dict(init_vals..., "step" => dt)
    res = HTTP.put(
        "$boptest_url/initialize",
        ["Content-Type" => "application/json"],
        JSON.json(init_vals)
    )
    res.status != 200 && error("Error initializing testcase")

    res = HTTP.get("$boptest_url/name")
    testcase = JSON.parse(String(res.body))["payload"]["name"]
    verbose && println("Initialized testcase=$testcase with step=$dt s")
    
    if !isnothing(scenario)
        res = HTTP.put(
            "$boptest_url/scenario",
            ["Content-Type" => "application/json"],
            JSON.json(scenario)
        )
        verbose && println("Initialized scenario with ", repr(scenario))
    else
        scenario = Dict()
    end

    return BOPTestPlant(; boptest_url, testcase, scenario)
end


function printinfo(plant::AbstractBOPTestPlant, d::AbstractDict)
    println("TEST CASE INFORMATION ------------- \n")
    for (k, v) in d
        res = HTTP.get("$(plant.boptest_url)/$v")
        payload = JSON.parse(String(res.body))["payload"]
        if res.status == 200
            pretty_pl = json(payload, 2)
            println("$k = ")
            println(pretty_pl)
        end
    end
end


inputpoints(plant::AbstractBOPTestPlant) = _getpoints(plant, "inputs")
measurementpoints(plant::AbstractBOPTestPlant) = _getpoints(plant, "measurements")
forecastpoints(plant::AbstractBOPTestPlant) =  _getpoints(plant, "forecast_points")


"""
Get KPI from BOPTEST server as `Dict`.
"""
function getkpi(plant::AbstractBOPTestPlant)
    res = HTTP.get(_endpoint(plant, "kpi"))
    return JSON.parse(String(res.body))["payload"]
end


"""
Query results from BOPTEST server.
"""
function getresults(plant::AbstractBOPTestPlant, points, starttime, finaltime; timeout=30.0)
    body = Dict(
        "point_names" => points,
        "start_time" => starttime,
        "final_time" => finaltime,
    )
    return _getdata(_endpoint(plant, "results"), body; timeout=timeout)
end

"""
Query forecast from BOPTEST server.
"""
function getforecast(plant::AbstractBOPTestPlant, points, horizon, interval; timeout=30.0)
    body = Dict(
        "point_names" => points,
        "horizon" => horizon,
        "interval" => interval
    )
    return _getdata(_endpoint(plant, "forecast"), body; timeout=timeout)
end

"""
    advance!(plant, u)

Step the plant using control input u.

# Arguments
- `plant::AbstractBOPTestPlant`: Plant to advance.
- `u::Dict`: Control inputs for the active test case.

Returns the payload as `Dict{String, Vector}``.
"""
function advance!(plant::AbstractBOPTestPlant, u)
	res = HTTP.post(
		_endpoint(plant, "advance"),
		["Content-Type" => "application/json"],
		JSON.json(u);
		retry_non_idempotent=true
	)
	
	payload_dict = JSON.parse(String(res.body))["payload"]
    return payload_dict
end


"""
    openloopsim!(boptest_url, N, dt[; u, include_forecast, verbose])

Run the plant in open loop simulation for N steps of time dt.

# Arguments
- `boptest_url`: URL of the BOPTEST server to step.
- `N::Int`: Number of steps
- `dt::Real`: Time step size
- `u`: Control inputs for the active test case. See below for options.
- `include_forecast::Bool`: Include forecasts in the returned `DataFrame`.
- `verbose::Bool`: Print something to stdout.

# Control inputs
Control inputs are passed through parameter `u`. The options are:
- `AbstractVector{Dict}`, where item `i` is control input at time step `i`.
- `Dict`, which means a constant control input at all time steps.
- `nothing`, in which case all control inputs are overwritten with `0.0`.

The dictionaries should contain mappings `"<signal_name>" => <value>`.
Use `getinputs(boptest_url)` to query available inputs. Input signals not found
in the dictionary will use the (testcase-specific) default instead. You can
pass an empty `Dict()` in order to use default values for all signals, i.e.
the baseline control.
"""
function openloopsim!(
    plant::AbstractBOPTestPlant, N::Int;
    u = Dict(),
    include_forecast::Bool = false,
    print_every::Int = 0,
)
    res = HTTP.get(_endpoint(plant, "step"))
    dt = JSON.parse(String(res.body))["payload"]
    
    if include_forecast
        fcpts = DataFrame(forecastpoints(plant))
        forecast = getforecast(boptest_url, fcpts.Name, N*dt, dt)
    else
        forecast = Dict()
    end

    if !(u isa AbstractVector)
        # Constant control inputs
        u = fill(u, N)
    end


    length(u) >= N || throw(DimensionMismatch("Need at least $N control input entries."))

	measurements = DataFrame(measurementpoints(plant))
    y_transform = SignalTransform(measurements.Name, y -> y)

    print_every > 0 && println("Starting open-loop simulation")

    Y = zeros(size(measurements, 1), N+1)
    y0d = getresults(plant, measurements.Name, 0.0, 0.0)
    Y[:, 1] = plantoutputs(y_transform, y0d)

    for j = 2:N+1
        (print_every > 0) && (j % print_every == 0) && println("Current time step = ",  j)
        _d = advance!(plant, u[j-1])
		Y[:, j] = plantoutputs(y_transform, _d)
	end

	# This solution would always return 30-sec interval data:
    # res = BOPTestAPI.getresults(endpoint, measurements.Name, 0, N*dt)
	df = DataFrame(Y', measurements.Name)

    # Add forecast variables (no cols if not queried)
    for (k, v) in forecast
        insertcols!(df, k => v)
    end

    return df
end

end