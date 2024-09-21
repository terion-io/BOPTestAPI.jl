module BOPTestAPI

export SignalTransform, to_boptest, to_matrix
export initboptest!, advanceboptest!, openloopsim!
export getforecast, getresults, getkpi, getmeasurements
export BOPTEST_DEF_URL

using HTTP
using JSON
using DataFrames

const BOPTEST_DEF_URL = "http://127.0.0.1:5000"


## Private functions
function _getdata(endpoint, body; timeout=30.0)
    put_hdr = ["Content-Type" => "application/json", "connecttimeout" => timeout]
    res = HTTP.put(endpoint, put_hdr, JSON.json(body); retry_non_idempotent=true)
    payload = JSON.parse(String(res.body))["payload"]

    d = Dict("time" => payload["time"])
    for col in body["point_names"]
        d[col] = payload[col]
    end

    return d
end


function _getpoints(boptest_url, path)
	yvars_res = HTTP.get("$boptest_url/$path")
	yvars_dict = JSON.parse(String(yvars_res.body))["payload"]
	yvars = []
	for (k, v) in yvars_dict
		d_ = Dict(
			"Name" => k,
			"Description" => v["Description"],
			"Unit" => v["Unit"],
		)

		push!(yvars, d_)
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
function initboptest!(
    boptest_url, dt;
    init_vals = Dict("start_time" => 0, "warmup_period" => 0),
    verbose::Bool = false,
)
    res = HTTP.put(
        "$boptest_url/initialize",
        ["Content-Type" => "application/json"],
        JSON.json(init_vals)
    )
    if res.status != 200
        return false
    end
    verbose && println("Successfully initialized the simulation")
    
    # Set simulation step
    res = HTTP.put(
        "$boptest_url/step",
        ["Content-Type" => "application/json"],
        JSON.json(Dict("step" => dt))
    )
    if res.status != 200
        return false
    end
    verbose && println("Set simulation step to $step")

    return true
end

# TODO: Adjust to generic controllers, or remove
function simulate(controller, Ns, colidx; boptest_url=BOPTEST_DEF_URL)
    y = zeros(length(colidx), Ns)

    # simulation loop
    for j = 1:Ns
        if j < 2
        # Initialize u
            u = initialize!(controller)
        else
        # Compute next control signal
            y_ = @view y[:, j-1]
            u = advance!(controller, y_, colidx)
        end
        # Advance in simulation
        res = HTTP.post("$boptest_url/advance",
                       ["Content-Type" => "application/json"],
                        JSON.json(u);
                        retry_non_idempotent=true
        )
        y_j = JSON.parse(String(res.body))["payload"]

        # Attach new values to time series
        for (k, i) in colidx
            y[i, j] = y_j[k]
        end
    end
    return y
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
function getkpi(boptest_url)
    res = HTTP.get("$boptest_url/kpi")
    return JSON.parse(String(res.body))["payload"]
end


"""
Query results from BOPTEST server.
"""
function getresults(boptest_url, colnames, starttime, finaltime; timeout=30.0)
    body = Dict(
        "point_names" => colnames,
        "start_time" => starttime,
        "final_time" => finaltime,
    )
    return _getdata("$boptest_url/results", body; timeout=timeout)
end


getinputs(boptest_url) = _getpoints(boptest_url, "inputs")
getmeasurements(boptest_url) = _getpoints(boptest_url, "measurements")
getforecastpoints(boptest_url) =  _getpoints(boptest_url, "forecast_points")

"""
Query forecast from BOPTEST server.
"""
function getforecast(boptest_url, colnames, horizon, interval; timeout=30.0)
    body = Dict(
        "point_names" => colnames,
        "horizon" => horizon,
        "interval" => interval
    )
    return _getdata("$boptest_url/forecast", body; timeout=timeout)
end

"""
    advanceboptest!(boptest_url, u, ycols)

Step the plant using control input u.

# Arguments
- `boptest_url`: URL of the BOPTEST server to step.
- `u::Dict`: Control inputs for the active test case.

Returns the payload as `Dict{String, Vector}``.
"""
function advanceboptest!(boptest_url, u)
	res = HTTP.post(
		"$boptest_url/advance",
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
    boptest_url, N::Int, dt;
    u = nothing,
    include_forecast::Bool = false,
    verbose::Bool = false,
)
	initboptest!(boptest_url, dt; verbose=verbose)

    if include_forecast
        fcpts = DataFrame(getforecastpoints(boptest_url))
        forecast = getforecast(boptest_url, fcpts.Name, N*dt, dt)
    else
        forecast = Dict()
    end


    # Default for u: override all controls -> "*_activate" = 1
    # and send u = 0 -> "*_u" = 0.0
	if isnothing(u)
		inputs = DataFrame(getinputs(boptest_url))
		override_sigs = subset(inputs, :Name => s -> endswith.(s, "_activate"))
        u_sigs = subset(inputs, :Name => s -> endswith.(s, "_u"))
	
		u = Dict(
            Pair.(override_sigs.Name, 1)...,
            Pair.(u_sigs.Name, 0.0)...,
        )
	end

    if !(u isa AbstractVector)
        u = fill(u, N)
    end


    length(u) >= N || throw(DimensionMismatch("Need at least $N control input entries."))

	measurements = DataFrame(getmeasurements(boptest_url))
    y_transform = SignalTransform(measurements.Name, y -> y)

    Y = zeros(size(measurements, 1), N+1)
    y0d = getresults(boptest_url, measurements.Name, 0.0, 0.0)
    Y[:, 1] = to_matrix(y_transform, y0d)
	for j = 2:N+1
        d_ = advanceboptest!(boptest_url, u[j-1])
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