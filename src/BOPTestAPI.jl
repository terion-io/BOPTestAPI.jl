module BOPTestAPI

export SignalTransform, to_boptest, to_matrix
export initboptest!, advanceboptest!, openloopsim!
export getforecast, getresults, getkpi, getmeasurements
export BOPTEST_DEF_URL

using HTTP
using JSON
using DataFrames

const BOPTEST_DEF_URL = "http://127.0.0.1:5000"


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
    scenario::AbstractString
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
    res = HTTP.put(endpoint, put_hdr, JSON.json(body); retry_non_idempotent=true)
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
    SignalTransform(names, transform, inv_transform)

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
    to_boptest(transformer, u, overwrite)

Return `Dict` with control signals for BOPTEST.

The function calls the transform on `u`, and then creates
a `Dict` with 2 entries per signal name in the `transformer`:
1. `"<signal_name>_u" => u`
2. `"<signal_name>_activate" => overwrite`
"""
function to_boptest(
    transformer::SignalTransform,
    u::AbstractVector,
    overwrite::AbstractVector{Bool}
)
    u = transformer.transform(u)
    d = Dict{AbstractString, Any}()
    for (i, s) in enumerate(transformer.names)
        d[s * "_u"] = u[i]
        d[s * "_activate"] = Int(overwrite[i])			
    end
    return d
end


"""
    to_matrix(transformer, d)

Return `Matrix` with scaled outputs from BOPTEST.

The function unpacks `d::Dict` into a matrix where each row
corresponds to a signal entry that is both in the dict and in
`transformer.names`, and multiple values (i.e. time) are in the
column dimension.
"""
function to_matrix(transformer::SignalTransform, d::AbstractDict)
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
    initboptest!(boptest_url, dt[; init_vals, verbose])

Initialize the BOPTEST server with step size dt.

# Arguments
- `boptest_url`: URL of the BOPTEST server to initialize.
- `dt`: Time step in seconds.
- `init_vals::Dict`: Parameters for the initialization.
- `verbose::Bool`: Print something to stdout.

Return `true` on success, and `false` on error.

"""
function initboptestservice!(
    boptest_url::AbstractString,
    testcase::AbstractString,
    dt::Real;
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    scenario::Union{Nothing, AbstractDict} = nothing,
    verbose::Bool = false,
)
    
    res = HTTP.post(
        "$boptest_url/testcases/$testcase/select",
        ["Content-Type" => "application/json"],
        JSON.json(init_vals)
    )
    if res.status != 200
        error("Could not select BOPTest testcase")
    end

    payload = JSON.parse(String(res.body))

    testid = payload["testid"]

    # Set simulation step
    init_dict = Dict(init_vals..., "step" => dt)
    res = HTTP.put(
        "$boptest_url/initialize/$testid",
        ["Content-Type" => "application/json"],
        JSON.json(init_dict)
    )
    if res.status != 200
        error("Error initializing testcase")
    end
    verbose && println("Initialized testcase=$testcase with step=$step")

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
        HTTP.put(_endpoint(plant, "stop"))
    catch e
        println()
    end
end

function printinfo(boptest_url, d::Dict)
    println("TEST CASE INFORMATION ------------- \n")
    for (k, v) in d
        res = HTTP.get("$boptest_url/$v")
        payload = JSON.parse(String(res.body))["payload"]
        if res.status == 200
            pretty_pl = json(payload, 2)
            println("$k = ")
            println(pretty_pl)
        end
    end
end


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
function getresults(plant::AbstractBOPTestPlant, colnames, starttime, finaltime; timeout=30.0)
    body = Dict(
        "point_names" => colnames,
        "start_time" => starttime,
        "final_time" => finaltime,
    )
    return _getdata(_endpoint(plant, "results"), body; timeout=timeout)
end


getinputs(plant) = _getpoints(plant, "inputs")
getmeasurements(plant) = _getpoints(plant, "measurements")
getforecastpoints(plant) =  _getpoints(plant, "forecast_points")

"""
Query forecast from BOPTEST server.
"""
function getforecast(plant::AbstractBOPTestPlant, colnames, horizon, interval; timeout=30.0)
    body = Dict(
        "point_names" => colnames,
        "horizon" => horizon,
        "interval" => interval
    )
    return _getdata(_endpoint(plant, "forecast"), body; timeout=timeout)
end

"""
    advanceboptest!(boptest_url, u, ycols)

Step the plant using control input u.

# Arguments
- `boptest_url`: URL of the BOPTEST server to step.
- `u::Dict`: Control inputs for the active test case.

Returns the payload as `Dict{String, Vector}``.
"""
function advanceboptest!(plant::AbstractBOPTestPlant, u)
	res = HTTP.post(
		_endpoint(plant, "advance"),
		["Content-Type" => "application/json"],
		JSON.json(u);
		retry_non_idempotent=true
	)
	
	payload_dict = JSON.parse(String(res.body))["payload"]
    return payload_dict
end


function controlinputs(
    plant::AbstractBOPTestPlant;
    dfmap::Function = df -> df[!, :Minimum]
)
    # Default for u: override all controls -> "*_activate" = 1
    # and send u = dfmap(Name)
    inputs = DataFrame(getinputs(plant))
    override_sigs = subset(inputs, :Name => s -> endswith.(s, "_activate"))
    u_sigs = subset(inputs, :Name => s -> endswith.(s, "_u"))

    u = Dict(
        Pair.(override_sigs.Name, 1)...,
        Pair.(u_sigs.Name, dfmap(u_sigs))...,
    )
    return u
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
)
    res = HTTP.get(_endpoint(plant, "step"))
    dt = JSON.parse(String(res.body))["payload"]
    
    if include_forecast
        fcpts = DataFrame(getforecastpoints(plant))
        forecast = getforecast(boptest_url, fcpts.Name, N*dt, dt)
    else
        forecast = Dict()
    end

    if !(u isa AbstractVector)
        u = fill(u, N)
    end


    length(u) >= N || throw(DimensionMismatch("Need at least $N control input entries."))

	measurements = DataFrame(getmeasurements(plant))
    y_transform = SignalTransform(measurements.Name, y -> y)

    Y = zeros(size(measurements, 1), N+1)
    y0d = getresults(plant, measurements.Name, 0.0, 0.0)
    Y[:, 1] = to_matrix(y_transform, y0d)
	for j = 2:N+1
        d_ = advanceboptest!(plant, u[j-1])
		Y[:, j] = to_matrix(y_transform, d_)
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