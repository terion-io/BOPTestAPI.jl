var documenterSearchIndex = {"docs":
[{"location":"#BOPTestAPI.jl","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"","category":"section"},{"location":"#Quickstart","page":"BOPTestAPI.jl","title":"Quickstart","text":"","category":"section"},{"location":"#Installation","page":"BOPTestAPI.jl","title":"Installation","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"BOPTestAPI is available from the Julia general registry. Thus, you can add it like","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"import Pkg; Pkg.add(\"BOPTestAPI\")","category":"page"},{"location":"#Self-contained-example","page":"BOPTestAPI.jl","title":"Self-contained example","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"See further below for some explanations.","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"using BOPTestAPI\nusing DataFrames\nusing Plots\nusing Latexify # hide\n\ndt = 900.0 # time step in seconds\ntestcase = \"bestest_hydronic\"\n\nplant = initboptestservice!(BOPTEST_SERVICE_DEF_URL, testcase, dt)\n\n# Get available measurement points\nmpts = plant.measurement_points\nmdtable(mpts[1:3, :], latex=false) # hide","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"(Output truncated)","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"N = 100\n\n# Get forecast data as well (for plotting later)\nfc = getforecasts(plant, N * dt, dt)\n\n# Run N time steps of baseline control\nres = []\nfor t = 1:N\n    u = Dict() # here you would put your own controller\n    y = advance!(plant, u)\n    push!(res, y)\nend\nstop!(plant)\n\ndfres = DataFrame(res)\nmdtable(mapcols(c -> round.(c, digits=2), dfres[1:5, 3:6]), latex=false) # hide","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"(Output truncated in both columns and rows)","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"And that's it! You successfully simulated a building HVAC system in the cloud using  BOPTEST-Service. The following code will just make some plots of the results.","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"# Create single df with all data\ndf = leftjoin(dfres, fc, on = :time => :time)\n\npl1 = plot(\n    df.time ./ 3600,\n    Matrix(df[!, [\"reaTRoo_y\", \"LowerSetp[1]\"]]);\n    xlabel=\"t [h]\",\n    ylabel=\"T [K]\",\n    labels=[\"actual\" \"target\"],\n)\npl2 = plot(\n    df.time ./ 3600, df.reaQHea_y ./ 1000;\n    xlabel=\"t [h]\",\n    ylabel=\"Qdot [kW]\",\n    labels=\"Heating\"\n)\nplot(pl1, pl2; layout=(2, 1))","category":"page"},{"location":"#Usage","page":"BOPTestAPI.jl","title":"Usage","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"(See also the README on Github)","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"The general idea is that the BOPTEST services are abstracted away as a BOPTestPlant, which only stores metadata about the plant such as the endpoints to use.","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"The package then defines common functions to operate on the plant, which are translated to REST API calls and the required data formattings.","category":"page"},{"location":"#Initialization","page":"BOPTestAPI.jl","title":"Initialization","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"It is recommended to create plants using the initialization functions:","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"dt = 900.0 # time step in seconds\nlocal_plant = initboptest!(BOPTEST_DEF_URL, dt)\n\n# and / or\ntestcase = \"bestest_hydronic\"\nremote_plant = initboptestservice!(BOPTEST_SERVICE_DEF_URL, testcase, dt)","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"The initialization functions also query and store the available signals (as DataFrame), since they are constant for a testcase. The signals are available as","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"plant.forecast_points\nplant.input_points\nplant.measurement_points","category":"page"},{"location":"#Interaction-with-the-plant","page":"BOPTestAPI.jl","title":"Interaction with the plant","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"The package then defines common functions to operate on the plant, namely","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"getforecasts, getmeasurements to get the actual time series data for forecast or past measurements\ngetkpi to get the KPI for the test case (calculated by BOPTEST)\nadvance!, to step the plant one time step with user-specified control input\nstop!, to stop a test case (BOPTEST-Service only)","category":"page"},{"location":"#Querying-data","page":"BOPTestAPI.jl","title":"Querying data","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"The time series functions return a DataFrame with the time series. By default, a conversion to Float64 is attempted (else the datatypes would be Any). You can use the keyword argument convert_f64=false to disable conversion.","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"# Query forecast data for 24 hours, with 1/dt sampling frequency\n# The column \"Name\" contains all available forecast signal names\nfc = getforecasts(plant, 24*3600, dt, plant.forecast_points.Name)","category":"page"},{"location":"#Advancing","page":"BOPTestAPI.jl","title":"Advancing","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"The advance! function requires the control inputs u as a Dict. Allowed control inputs are test case specific, but can be queried as property input_points.","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"ipts = plant.input_points\n\n# Alternative: Create a simple Dict directly\n# This will by default overwrite all baseline values with the lowest allowed value\nu = controlinputs(plant)\n\n# Simulate 100 steps open-loop\nres_ol = [advance!(plant, u) for _ = 1:100]\ndf_ol = DataFrame(res_ol)\n\n# KPI\nkpi = getkpi(plant)","category":"page"},{"location":"#Stop","page":"BOPTestAPI.jl","title":"Stop","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"When using BOPTEST-Service, be nice to NREL (or whoever is hosting) and stop a test case when no longer needed:","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"stop!(remote_plant)","category":"page"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"This function does nothing when called on a \"normal\" BOPTestPlant","category":"page"},{"location":"#API","page":"BOPTestAPI.jl","title":"API","text":"","category":"section"},{"location":"","page":"BOPTestAPI.jl","title":"BOPTestAPI.jl","text":"BOPTEST_DEF_URL\nBOPTEST_SERVICE_DEF_URL\nBOPTestPlant\ninitboptest!\ninitboptestservice!\ngetforecasts\ngetmeasurements\ngetkpi\ncontrolinputs\nadvance!\nstop!","category":"page"},{"location":"#BOPTestAPI.BOPTEST_DEF_URL","page":"BOPTestAPI.jl","title":"BOPTestAPI.BOPTEST_DEF_URL","text":"const BOPTEST_DEF_URL = \"http://127.0.0.1:5000\"\n\nDefault URL when starting BOPTEST locally,\n\n\n\n\n\n","category":"constant"},{"location":"#BOPTestAPI.BOPTEST_SERVICE_DEF_URL","page":"BOPTestAPI.jl","title":"BOPTestAPI.BOPTEST_SERVICE_DEF_URL","text":"const BOPTEST_SERVICE_DEF_URL = \"http://api.boptest.net\"\n\nURL of the NREL BOPTEST-Service API.\n\n\n\n\n\n","category":"constant"},{"location":"#BOPTestAPI.BOPTestPlant","page":"BOPTestAPI.jl","title":"BOPTestAPI.BOPTestPlant","text":"struct BOPTestPlant <: AbstractBOPTestPlant\n\nMetadata for a BOPTEST plant.\n\n\n\n\n\n","category":"type"},{"location":"#BOPTestAPI.initboptest!","page":"BOPTestAPI.jl","title":"BOPTestAPI.initboptest!","text":"initboptest!(boptest_url, dt[; init_vals, scenario, verbose])\n\nInitialize the BOPTEST server with step size dt.\n\nArguments\n\nboptest_url: URL of the BOPTEST server to initialize.\ndt: Time step in seconds.\ninit_vals::Dict: Parameters for the initialization.\nscenario::Dict : Parameters for scenario selection.\nverbose::Bool: Print something to stdout.\n\nReturn a BOPTestPlant instance, or throw an ErrorException on error.\n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.initboptestservice!","page":"BOPTestAPI.jl","title":"BOPTestAPI.initboptestservice!","text":"initboptestservice!(boptest_url, testcase, dt[; init_vals, scenario, verbose])\n\nInitialize a testcase in BOPTEST service with step size dt.\n\nArguments\n\nboptest_url: URL of the BOPTEST-Service API to initialize.\ntestcase : Name of the test case, list here.\ndt: Time step in seconds.\ninit_vals::Dict: Parameters for the initialization.\nscenario::Dict : Parameters for scenario selection.\nverbose::Bool: Print something to stdout.\n\nReturn a BOPTestPlant instance, or throw an ErrorException on error.\n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.getforecasts","page":"BOPTestAPI.jl","title":"BOPTestAPI.getforecasts","text":"getforecasts(plant::AbstractBOPTestPlant, horizon, interval[, points])\n\nQuery forecast from BOPTEST server and return as DataFrame.\n\nArguments\n\nplant : The plant to query forecast from.\nhorizon::Real : Forecast time horizon from current time step, in seconds.\ninterval::Real : Time step size for the forecast data, in seconds.\npoints::AbstractVector{AbstractString} : The forecast point names to query. Optional.\n\nKeyword Arguments\n\nconvert_f64::Bool : whether to convert column types to Float64, default true. If set to false, the columns will have type Any.\n\nAvailable forecast points are stored in plant.forecast_points. \n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.getmeasurements","page":"BOPTestAPI.jl","title":"BOPTestAPI.getmeasurements","text":"getmeasurements(plant::AbstractBOPTestPlant, starttime, finaltime[, points])\n\nQuery measurements from BOPTEST server and return as DataFrame.\n\nArguments\n\nplant : The plant to query measurements from.\nstarttime::Real : Start time for measurements time series, in seconds.\nfinaltime::Real : Final time for measurements time series, in seconds.\npoints::AbstractVector{AbstractString} : The measurement point names to query. Optional.\n\nKeyword Arguments\n\nconvert_f64::Bool : whether to convert column types to Float64, default true. If set to false, the columns will have type Any.\n\nTo obtain available measurement points, use plant.measurement_points, which is a  DataFrame with a column :Name that contains all available signals.\n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.getkpi","page":"BOPTestAPI.jl","title":"BOPTestAPI.getkpi","text":"getkpi(plant::AbstractBOPTestPlant)\n\nGet KPI from BOPTEST server as Dict.\n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.controlinputs","page":"BOPTestAPI.jl","title":"BOPTestAPI.controlinputs","text":"controlinputs([f::Function, ]plant::AbstractBOPTestPlant)\n\nReturn Dict with control signals for BOPTEST.\n\nThis method calls inputpoints(plant) to gather available inputs, and then creates a Dict with the available inputs as keys and default values defined by function f.\n\nf is a function that is applied to a DataFrame constructed from the input points that have a suffix \"_u\", i.e. control inputs. The DataFrame normally has columns :Name, :Minimum, :Maximum, :Unit, :Description.\n\nThe default for f is df -> df[!, :Minimum], i.e. use the minimum allowed  input.\n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.advance!","page":"BOPTestAPI.jl","title":"BOPTestAPI.advance!","text":"advance!(plant::AbstractBOPTestPlant, u::AbstractDict)\n\nStep the plant using control input u.\n\nArguments\n\nplant::AbstractBOPTestPlant: Plant to advance.\nu::AbstractDict: Control inputs for the active test case.\n\nReturns the payload as Dict{String, Vector}.\n\n\n\n\n\n","category":"function"},{"location":"#BOPTestAPI.stop!","page":"BOPTestAPI.jl","title":"BOPTestAPI.stop!","text":"stop!(plant::AbstractBOPTestPlant)\n\nStop a BOPTestPlant from running.\n\nThis method does nothing for plants run in normal BOPTEST  (i.e. not BOPTEST-Service).\n\n\n\n\n\n","category":"function"}]
}
