module BOPTestAPI

export initboptest!, advanceboptest!, openloopsim!
export getforecast, getresults, getkpi, getmeasurements
export BOPTEST_DEF_URL

using HTTP
using JSON
using DataFrames

const BOPTEST_DEF_URL = "http://127.0.0.1:5000"


struct SignalMapper
    names::AbstractVector{AbstractString}
    forward_scaler::Function
    backward_scaler::Function
end

function to_boptest(
    mapper::SignalMapper,
    x::AbstractMatrix,
    overwrite::AbstractVector{Bool}
)
    x = mapper.forward_scaler(x)
    d = Dict{AbstractString, Any}()
    for (i, s) in enumerate(mapper.names)
        d[s * "_u"] = x[i, :]
        d[s * "_activate"] = overwrite[i]			
    end
    return d
end

function to_matrix(mapper::SignalMapper, d::Dict)
    m = length(d[mapper.names[1]])
    x = zeros(length(mapper.names), m)
    for (i, s) in enumerate(mapper.names)
        x[i, :] = d[s]
    end
    return mapper.backward_scaler(x)
end


## Private functions
function _payload2array(payload::Dict; cols=collect(keys(payload)))::Matrix{Float64}
	n = length(payload[cols[1]])
    y = zeros(length(cols), n)
	for (i, k) in enumerate(cols)
		y[i, :] .= payload[k]
	end
    return y
end


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
- `ycols::AbstractVector`: Names of columns to be returned.

Returns an m-by-one `Matrix` where each row corresponds to the
name from `ycols`.
"""
function advanceboptest!(boptest_url, u; ymapper = y -> y)
	res = HTTP.post(
		"$boptest_url/advance",
		["Content-Type" => "application/json"],
		JSON.json(u);
		retry_non_idempotent=true
	)
	
	payload_dict = JSON.parse(String(res.body))["payload"]
    return ymapper(payload_dict)
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
    u::Union{AbstractVector{Dict}, Dict, Nothing} = nothing,
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

    Y = zeros(size(measurements, 1), N+1)
    y0d = getresults(boptest_url, measurements.Name, 0.0, 0.0)
    Y[:, 1] = _payload2array(y0d; cols=measurements.Name)
	for j = 2:N+1
		Y[:, j] = advanceboptest!(
            boptest_url, u[j-1];
            ymapper = y -> _payload2array(y; cols=measurements.Name)
        )
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