import BOPTestAPI: AbstractBOPTestPlant

using BOPTestAPI
using DataFrames
using Test

@testset "BOPTestPlant" begin
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
        dt, scenario
    )
    
    try
        @test plant isa AbstractBOPTestPlant
        
        fcpts = forecast_points(plant)
        @test "Name" in names(fcpts)
        @test size(fcpts, 1) > 0

        @test size(measurement_points(plant), 1) > 0

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

        new_scenario = setscenario!(plant, Dict("electricity_price" => "dynamic"))
        @test "electricity_price" in keys(new_scenario)

    catch e
        rethrow(e)
    finally
        stop!(plant)
    end
end


@testset "CachedBOPTestPlant" begin
    testcase = "bestest_hydronic_heat_pump"
    dt = 300.0
    scenario = Dict(
        "electricity_price" => "highly_dynamic",
    # Note: This seems to not work on the server side
    #    "time_period" => "typical_heat_day" 
    )
    N = 12

    # To use BOPTEST-service
    # base_url = "http://localhost"
    base_url = "http://api.boptest.net"
    plant = CachedBOPTestPlant(
        base_url, testcase, N;
        dt, scenario
    )
    try
        @test plant isa AbstractBOPTestPlant

        # Added fields
        @test plant.dt == dt
        @test plant.N == N

        # To check Base.getproperty accessor
        @test input_points(plant) isa AbstractDataFrame

        @test size(forecasts(plant), 1) == N + 1
        @test size(measurements(plant), 1) == 1
        
        u = Dict("oveHeaPumY_activate" => 1, "oveHeaPumY_u" => 0.3)
        N_advance = 10
        for t = 1:N_advance
            advance!(plant, u)
        end

        p_i = inputs_sent(plant)
        @test size(p_i, 1) == N_advance
        @test all(ismissing.(p_i[!, :oveTSet_u]))
        @test all(p_i[!, :oveHeaPumY_u] .== 0.3)

        p_i = inputs_sent(plant, rows = 1:3, columns = ["time", "oveHeaPumY_u"])
        @test size(p_i, 1) == 3
        @test size(p_i, 2) == 2

        m = measurements(plant)
        @test size(m, 1) == N_advance + 1
        @test all(diff(m.time) .== dt)

        fc = forecasts(plant)
        @test minimum(fc.time) == N_advance * dt

        initialize!(plant)
        m = measurements(plant)
        @test size(m, 1) == 1

        i = inputs_sent(plant)
        @test size(i, 1) == 0
        @test "time" in names(i)
        
        fc = forecasts(plant)       
        @test minimum(fc.time) == 0.0
        
    catch e
        rethrow(e)
    finally
        stop!(plant)
    end
end

