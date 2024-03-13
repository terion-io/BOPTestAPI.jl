module BOPTestAPI

export initboptest!, advanceboptest!, openloopsim!
export getforecast, getresults, getkpi, getmeasurements
export BOPTEST_DEF_URL

using HTTP
using JSON
using DataFrames

const BOPTEST_DEF_URL = "http://127.0.0.1:5000"


function initboptest!(endpoint, step; verbose=true)
    init_vals = Dict("start_time" => 0,"warmup_period" => 0)
    res = HTTP.put("$endpoint/initialize",
                   ["Content-Type" => "application/json"],
                   JSON.json(init_vals)
    )
    if res.status != 200
        return false
    end
    if verbose
        println("Successfully initialized the simulation")
    end
    
    # Set simulation step
    res = HTTP.put("$endpoint/step",
                   ["Content-Type" => "application/json"],
                   JSON.json(Dict("step" => step))
    )
    if res.status != 200
        return false
    end
    if verbose
       println("Set simulation step to $step")
    end
    return true
end

# TODO: Adjust to generic controllers, or remove
function simulate(controller, Ns, colidx; endpoint=BOPTEST_DEF_URL)
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
        res = HTTP.post("$endpoint/advance",
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


function printinfo(endpoint, d::Dict)
    println("TEST CASE INFORMATION ------------- \n")
    for (k, v) in d
        res = HTTP.get("$endpoint/$v")
        payload = JSON.parse(String(res.body))["payload"]
        if res.status == 200
            pretty_pl = json(payload, 2)
            println("$k = ")
            println(pretty_pl)
        end
    end
end


function getkpi(endpoint)
    res = HTTP.get("$endpoint/kpi")
    return JSON.parse(String(res.body))["payload"]
end


function _getdata(query_url, body; timeout=30.0)
    put_hdr = ["Content-Type" => "application/json", "connecttimeout" => timeout]
    res = HTTP.put(query_url, put_hdr, JSON.json(body); retry_non_idempotent=true)
    payload = JSON.parse(String(res.body))["payload"]

    d = Dict("time" => payload["time"])
    for col in body["point_names"]
        d[col] = payload[col]
    end

    return d
end


function getresults(endpoint, colnames, starttime, finaltime; timeout=30.0)
    body = Dict(
        "point_names" => colnames,
        "start_time" => starttime,
        "final_time" => finaltime,
    )
    return _getdata("$endpoint/results", body; timeout=timeout)
end


function _getpoints(endpoint, path)
	yvars_res = HTTP.get("$endpoint/$path")
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


getinputs(endpoint) = _getpoints(endpoint, "inputs")
getmeasurements(endpoint) = _getpoints(endpoint, "measurements")
getforecastpoints(endpoint) =  _getpoints(endpoint, "forecast_points")


function getforecast(endpoint, colnames, horizon, interval; timeout=30.0)
    body = Dict(
        "point_names" => colnames,
        "horizon" => horizon,
        "interval" => interval
    )
    return _getdata("$endpoint/forecast", body; timeout=timeout)
end


function _payload2array(payload::Dict; cols=collect(keys(payload)))::Matrix{Float64}
	n = length(payload[cols[1]])
    y = zeros(length(cols), n)
	for (i, k) in enumerate(cols)
		y[i, :] .= payload[k]
	end
    return y
end


function advanceboptest!(endpoint, u, ycols)
	res = HTTP.post(
		"$endpoint/advance",
		["Content-Type" => "application/json"],
		JSON.json(u);
		retry_non_idempotent=true
	)
	
	y_j = JSON.parse(String(res.body))["payload"]
    return _payload2array(y_j; cols=ycols)
end


function openloopsim!(
    endpoint, N::Int, dt;
    u::Union{Dict, Nothing}=nothing,
    include_forecast::Bool=false,
    verbose::Bool=false,
)
	BOPTestAPI.initboptest!(endpoint, dt; verbose=verbose)

    if include_forecast
        fcpts = DataFrame(getforecastpoints(endpoint))
        forecast = getforecast(endpoint, fcpts.Name, N*dt, dt)
    else
        forecast = Dict()
    end


    # Default for u: override all controls -> "*_activate" = 1
    # and send u = 0 -> "*_u" = 0.0
	if isnothing(u)
		inputs = DataFrame(BOPTestAPI.getinputs(endpoint))
		override_sigs = subset(inputs, :Name => s -> endswith.(s, "_activate"))
        u_sigs = subset(inputs, :Name => s -> endswith.(s, "_u"))
	
		u = Dict(
            Pair.(override_sigs.Name, 1)...,
            Pair.(u_sigs.Name, 0.0)...,
        )
	end

	measurements = DataFrame(BOPTestAPI.getmeasurements(endpoint))

    Y = zeros(size(measurements, 1), N+1)
    y0d = BOPTestAPI.getresults(endpoint, measurements.Name, 0.0, 0.0)
    Y[:, 1] = _payload2array(y0d; cols=measurements.Name)
	for j = 2:N+1
		Y[:, j] = BOPTestAPI.advanceboptest!(endpoint, u, measurements.Name)
	end

	# This solution always returns 30-sec interval data:
    # res = BOPTestAPI.getresults(endpoint, measurements.Name, 0, N*dt)
	df = DataFrame(Y', measurements.Name)

    # Add forecast variables (no cols if not queried)
    for (k, v) in forecast
        insertcols!(df, k=> v)
    end

    return df
end

end