import BOPTestAPI: AbstractBOPTestPlant

using BOPTestAPI
using DataFrames
using Test

@testset "BOPTestAPI.jl" begin
    testcase = "bestest_hydronic"
    dt = 300.0
    scenario = Dict(
        "electricity_price" => "highly_dynamic",
    # Note: This seems to not work on the server side
    #    "time_period" => "typical_heat_day" 
    )

    # To use BOPTEST-service
    # base_url = "http://localhost"
    base_url = "http://api.boptest.net"
    plant = BOPTestPlant(
        base_url, testcase;
        dt, scenario, verbose = true
    )
    
    try
        @test plant isa AbstractBOPTestPlant
        
        fcpts = plant.forecast_points
        @test "Name" in names(fcpts)
        @test size(fcpts, 1) > 0

        @test size(plant.measurement_points, 1) > 0

        dfres = getmeasurements(plant, 0.0, 0.0) # DataFrame
        @test "time" in names(dfres)
        @test dfres[!, "reaPPum_y"] isa AbstractVector{Float64}

        # Get forecast
        N = 12
        fc = getforecasts(plant, N * 3600, 3600, ["lat", "lon"])
        @test size(fc, 1) == N + 1
        @test size(fc, 2) == 3

        # Control inputs
        u = controlinputs(plant)
        @test "ovePum_activate" in keys(u)
        @test u["ovePum_activate"] == 1

        # Baseline open-loop control
        res = []
        u = Dict()
        for t = 1:N
            y = advance!(plant, u)
            push!(res, y)
        end

        df = DataFrame(res)
        @test df.time[2] - df.time[1] == dt
        @test size(df, 1) == N

        # KPI
        kpi = getkpi(plant)
        @test "ener_tot" in keys(kpi)
        @test kpi["ener_tot"] > 0

        # Reset
        initialize!(plant)
        kpi = getkpi(plant)
        @test kpi["ener_tot"] == 0

    catch e
        rethrow(e)
    finally
        stop!(plant)
    end
end
