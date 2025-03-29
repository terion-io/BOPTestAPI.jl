module BOPTestRLExt


import BOPTestAPI: AbstractBOPTestPlant
import DomainSets: ProductDomain, Rectangle
import IntervalSets: AbstractInterval

using BOPTestAPI
using DataFrames
using IntervalArithmetic
using LinearAlgebra # for cross operator
using Random
using ReinforcementLearning
using StaticArrays

testcase = "bestest_hydronic_heat_pump"

abstract type BOPTestTestCase end

struct BestestHydronic <: BOPTestTestCase end
struct BestestHydronicHeatPump <: BOPTestTestCase end


Base.@kwdef mutable struct BOPTestRLEnv{TC <: BOPTestTestCase} <: AbstractEnv
    plant::CachedBOPTestPlant
    t::Int
    rng::AbstractRNG
end

function BOPTestRLEnv{TC}(p::AbstractBOPTestPlant) where {TC <: BOPTestTestCase}
    return BOPTestRLEnv{TC}(p, 0,  Random.default_rng())
end

RLBase.StateStyle(::BOPTestRLEnv) = (
    Observation{AbstractVector{Float64}}(),
)

RLBase.NumAgentStyle(::BOPTestRLEnv) = SINGLE_AGENT
RLBase.DynamicStyle(::BOPTestRLEnv) = SEQUENTIAL
RLBase.ActionStyle(::BOPTestRLEnv) = MINIMAL_ACTION_SET
RLBase.InformationStyle(::BOPTestRLEnv) = IMPERFECT_INFORMATION
RLBase.RewardStyle(::BOPTestRLEnv) = STEP_REWARD
RLBase.ChanceStyle(::BOPTestRLEnv) = DETERMINISTIC


function _extract_limits(plant::AbstractBOPTestPlant, signals::AbstractVector{<:AbstractString})
    ipts = plant.input_points
    limits = subset(ipts, :Name => c -> in.(c, Ref(signals)))
    limits = limits[!, [:Name, :Minimum, :Maximum]]
    disallowmissing!(limits)

    d = Dict{String, Vector{Float64}}()
    for i in axes(limits, 1)
        d[limits.Name[i]] = [limits[i, :Minimum]; limits[i, :Maximum]]
    end
    return d
end

function RLBase.action_space(env::BOPTestRLEnv{BestestHydronic})
    limits = _extract_limits(env.plant, ["oveTSetHea_u"])
    Tmin, Tmax = limits["oveTSetHea_u"][1], limits["oveTSetHea_u"][2]
    return (Tmin .. Tmax)
end

RLBase.action_space(::BOPTestRLEnv{BestestHydronicHeatPump}) = 0.0 .. 1.0

function RLBase.state(env::BOPTestRLEnv{BestestHydronic}, ::Observation{AbstractVector{Float64}})
    y = env.plant.measurements[end, "reaTRoo_y"]::Float64
    T_sp = env.plant.forecasts[1, "LowerSetp[1]"]::Float64
    return SA[y, T_sp]
end

function RLBase.state(env::BOPTestRLEnv{BestestHydronicHeatPump}, ::Observation{AbstractVector{Float64}})
    y = env.plant.measurements[end, "reaTZon_y"]::Float64
    T_sp = env.plant.forecasts[1, "LowerSetp[1]"]::Float64
    return SA[y, T_sp]
end


function RLBase.state_space(env::BOPTestRLEnv{BestestHydronic})
    ipts = env.plant.input_points
    T_min = ipts[ipts.Name .== "oveTSetHea_u", :Minimum] .- 10
    T_max = ipts[ipts.Name .== "oveTSetCoo_u", :Maximum] .+ 10
    iv = (T_min[]::Float64 .. T_max[]::Float64)
    return cross(iv, iv)
end

RLBase.state_space(::BOPTestRLEnv{BestestHydronicHeatPump}) = cross((250.0 .. 340.0), (285.0 .. 300.0))


function RLBase.reward(env::BOPTestRLEnv, weight_fun = dict -> -1 * dict["tdis_tot"])
    kpi = getkpi(env.plant)
    return weight_fun(kpi)
end

RLBase.is_terminated(env::BOPTestRLEnv) = env.t >= 24 * 14

function RLBase.reset!(env::BOPTestRLEnv) 
    initialize!(env.plant)
    env.t = 0
    return nothing
end

function RLBase.act!(env::BOPTestRLEnv{BestestHydronic}, action)
    d = Dict(
        "oveTSetHea_activate" => 1,
        "oveTSetHea_u" => action,
    )
    advance!(env.plant, d; timeout = 120)
    env.t += 1
    return nothing
end

function RLBase.act!(env::BOPTestRLEnv{BestestHydronicHeatPump}, action)
    d = Dict("oveHeaPumY_activate" => 1, "oveHeaPumY_u" => action)
    advance!(env.plant, d; timeout = 120)
    env.t += 1
    return nothing
end


function _discretize_action_space(A)
    r = maximum(A) - minimum(A)
    return Base.OneTo(ceil(Int, r + 1))
end


function _discretize_state_space(S::AbstractInterval)
    r = maximum(S) - minimum(S)
    return Base.OneTo(ceil(Int, r + 1))
end

function _discretize_state_space(S::Rectangle)
    r = S.b .- S.a
    domains = Base.OneTo.(ceil.(Int, r .+ 1))
    return ProductDomain(domains...)
end

Ts = 3600.0
plant = CachedBOPTestPlant("http://localhost", "bestest_hydronic", 24)
env = BOPTestRLEnv{BestestHydronic}(plant)

S_env = state_space(env)

action_disc_env = ActionTransformedEnv(
    env;
    action_mapping = a -> a - 1,
    action_space_mapping = A -> _discretize_action_space(A),
)

state_disc_env = StateTransformedEnv(
    action_disc_env;
    state_mapping = s -> round.(Int, s .- S_env.a),
    state_space_mapping = S -> _discretize_state_space(S)
)


end