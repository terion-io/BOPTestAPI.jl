using BOPTestAPI
using DataFrames
using Test

@testset "BOPTestAPI.jl" begin
    testcase = "bestest_hydronic"
    dt = 300.0

    # To use BOPTEST-service
    plant = initboptestservice!(BOPTEST_SERVICE_DEF_URL, testcase, dt)
    
    # To use BOPTEST
    # plant = initboptest!(BOPTEST_DEF_URL, dt)
    try
        @test plant isa BOPTestAPI.AbstractBOPTestPlant
        
        fcpts = DataFrame(forecastpoints(plant))
        @test "Name" in names(fcpts)
        @test size(fcpts, 1) > 0

        # Piping syntax should also work
        mpts = plant |> measurementpoints |> DataFrame
        @test size(mpts, 1) > 0

        res = getresults(plant, mpts.Name, 0.0, 0.0) # Dict
        @test "time" in keys(res)
        @test res["reaPPum_y"] isa AbstractVector

        # Get forecast
        N = 12
        fc = getforecast(plant, fcpts.Name, N * 3600, 3600) |> DataFrame
        @test size(fc, 1) == N + 1

        # Control inputs
        u = controlinputs(plant)
        @test "ovePum_activate" in keys(u)
        @test u["ovePum_activate"] == 1

        # Baseline open-loop control
        df = openloopsim!(plant, N, include_forecast = true)
        @test df.time[2] - df.time[1] == dt
        @test size(df, 1) == N + 1

        # KPI
        kpi = getkpi(plant)
        @test "ener_tot" in keys(kpi)

    catch e
        rethrow(e)
    finally
        stop!(plant)
    end
end
