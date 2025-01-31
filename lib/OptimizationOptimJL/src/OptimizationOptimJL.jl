module OptimizationOptimJL

using Reexport
@reexport using Optim, Optimization
using Optimization.SciMLBase, SparseArrays
decompose_trace(trace::Optim.OptimizationTrace) = last(trace)
decompose_trace(trace::Optim.OptimizationState) = trace

SciMLBase.allowsconstraints(::IPNewton) = true
SciMLBase.requiresconstraints(::IPNewton) = true
SciMLBase.allowsbounds(opt::Optim.AbstractOptimizer) = true
SciMLBase.allowsbounds(opt::Optim.SimulatedAnnealing) = false
SciMLBase.requiresbounds(opt::Optim.Fminbox) = true
SciMLBase.requiresbounds(opt::Optim.SAMIN) = true

struct OptimJLOptimizationCache{F, RC, LB, UB, LC, UC, S, O, D, P, C} <:
       SciMLBase.AbstractOptimizationCache
    f::F
    reinit_cache::RC
    lb::LB
    ub::UB
    lcons::LC
    ucons::UC
    sense::S
    opt::O
    data::D
    progress::P
    callback::C
    solver_args::NamedTuple
end

function Base.getproperty(cache::OptimJLOptimizationCache, x::Symbol)
    if x in fieldnames(Optimization.ReInitCache)
        return getfield(cache.reinit_cache, x)
    end
    return getfield(cache, x)
end

function OptimJLOptimizationCache(prob::OptimizationProblem, opt, data; progress, callback,
                                  kwargs...)
    reinit_cache = Optimization.ReInitCache(prob.u0, prob.p) # everything that can be changed via `reinit`
    num_cons = prob.ucons === nothing ? 0 : length(prob.ucons)
    f = Optimization.instantiate_function(prob.f, reinit_cache, prob.f.adtype, num_cons)

    !(opt isa Optim.ZerothOrderOptimizer) && f.grad === nothing &&
        error("Use OptimizationFunction to pass the derivatives or automatically generate them with one of the autodiff backends")

    opt isa Optim.ConstrainedOptimizer && f.cons_j === nothing &&
        error("This optimizer requires derivative definitions for nonlinear constraints. If the problem does not have nonlinear constraints, choose a different optimizer. Otherwise define the derivative for cons using OptimizationFunction either directly or automatically generate them with one of the autodiff backends")

    return OptimJLOptimizationCache(f, reinit_cache, prob.lb, prob.ub, prob.lcons,
                                    prob.ucons, prob.sense,
                                    opt, data, progress, callback, NamedTuple(kwargs))
end

SciMLBase.supports_opt_cache_interface(opt::Optim.AbstractOptimizer) = true
SciMLBase.supports_opt_cache_interface(opt::Union{Optim.Fminbox, Optim.SAMIN}) = true
SciMLBase.supports_opt_cache_interface(opt::Optim.ConstrainedOptimizer) = true
SciMLBase.has_reinit(cache::OptimJLOptimizationCache) = true
function SciMLBase.reinit!(cache::OptimJLOptimizationCache; p = missing, u0 = missing)
    if p === missing && u0 === missing
        p, u0 = cache.p, cache.u0
    else # at least one of them has a value
        if p === missing
            p = cache.p
        end
        if u0 === missing
            u0 = cache.u0
        end
        if (eltype(p) <: Pair && !isempty(p)) || (eltype(u0) <: Pair && !isempty(u0)) # one is a non-empty symbolic map
            hasproperty(cache.f, :sys) && hasfield(typeof(cache.f.sys), :ps) ||
                throw(ArgumentError("This cache does not support symbolic maps with `remake`, i.e. it does not have a symbolic origin." *
                                    " Please use `remake` with the `p` keyword argument as a vector of values, paying attention to parameter order."))
            hasproperty(cache.f, :sys) && hasfield(typeof(cache.f.sys), :states) ||
                throw(ArgumentError("This cache does not support symbolic maps with `remake`, i.e. it does not have a symbolic origin." *
                                    " Please use `remake` with the `u0` keyword argument as a vector of values, paying attention to state order."))
            p, u0 = SciMLBase.process_p_u0_symbolic(cache, p, u0)
        end
    end

    cache.reinit_cache.p = p
    cache.reinit_cache.u0 = u0

    return cache
end

function __map_optimizer_args(cache::OptimJLOptimizationCache,
                              opt::Union{Optim.AbstractOptimizer, Optim.Fminbox,
                                         Optim.SAMIN, Optim.ConstrainedOptimizer};
                              callback = nothing,
                              maxiters::Union{Number, Nothing} = nothing,
                              maxtime::Union{Number, Nothing} = nothing,
                              abstol::Union{Number, Nothing} = nothing,
                              reltol::Union{Number, Nothing} = nothing,
                              kwargs...)
    if !isnothing(abstol)
        @warn "common abstol is currently not used by $(opt)"
    end

    mapped_args = (; extended_trace = true, kwargs...)

    if !isnothing(callback)
        mapped_args = (; mapped_args..., callback = callback)
    end

    if !isnothing(maxiters)
        mapped_args = (; mapped_args..., iterations = maxiters)
    end

    if !isnothing(maxtime)
        mapped_args = (; mapped_args..., time_limit = maxtime)
    end

    if !isnothing(reltol)
        mapped_args = (; mapped_args..., f_tol = reltol)
    end

    return Optim.Options(; mapped_args...)
end

function SciMLBase.__init(prob::OptimizationProblem, opt::Optim.AbstractOptimizer,
                          data = Optimization.DEFAULT_DATA;
                          callback = (args...) -> (false),
                          maxiters::Union{Number, Nothing} = nothing,
                          maxtime::Union{Number, Nothing} = nothing,
                          abstol::Union{Number, Nothing} = nothing,
                          reltol::Union{Number, Nothing} = nothing,
                          progress = false,
                          kwargs...)
    if !isnothing(prob.lb) || !isnothing(prob.ub)
        if !(opt isa Union{Optim.Fminbox, Optim.SAMIN, Optim.AbstractConstrainedOptimizer})
            if opt isa Optim.ParticleSwarm
                opt = Optim.ParticleSwarm(; lower = prob.lb, upper = prob.ub,
                                          n_particles = opt.n_particles)
            elseif opt isa Optim.SimulatedAnnealing
                @warn "$(opt) can currently not be wrapped in Fminbox(). The lower and upper bounds thus will be ignored. Consider using a different optimizer or open an issue with Optim.jl"
            else
                opt = Optim.Fminbox(opt)
            end
        end
    end

    maxiters = if data != Optimization.DEFAULT_DATA
        length(data)
    else
        maxiters
    end

    maxiters = Optimization._check_and_convert_maxiters(maxiters)
    maxtime = Optimization._check_and_convert_maxtime(maxtime)
    return OptimJLOptimizationCache(prob, opt, data; callback, maxiters, maxtime, abstol,
                                    reltol, progress,
                                    kwargs...)
end

function SciMLBase.__solve(cache::OptimJLOptimizationCache{F, RC, LB, UB, LC, UC, S, O, D, P
                                                           }) where {
                                                                     F,
                                                                     RC,
                                                                     LB,
                                                                     UB, LC, UC,
                                                                     S,
                                                                     O <:
                                                                     Optim.AbstractOptimizer,
                                                                     D,
                                                                     P
                                                                     }
    local x, cur, state

    cur, state = iterate(cache.data)

    function _cb(trace)
        cb_call = cache.opt isa Optim.NelderMead ?
                  cache.callback(decompose_trace(trace).metadata["centroid"],
                                 x...) :
                  cache.callback(decompose_trace(trace).metadata["x"], x...)
        if !(typeof(cb_call) <: Bool)
            error("The callback should return a boolean `halt` for whether to stop the optimization process.")
        end
        nx_itr = iterate(cache.data, state)
        if isnothing(nx_itr)
            true
        else
            cur, state = nx_itr
            cb_call
        end
    end

    _loss = function (θ)
        x = cache.f.f(θ, cache.p, cur...)
        __x = first(x)
        return cache.sense === Optimization.MaxSense ? -__x : __x
    end

    fg! = function (G, θ)
        if G !== nothing
            cache.f.grad(G, θ, cur...)
            if cache.sense === Optimization.MaxSense
                G .*= false
            end
        end
        return _loss(θ)
    end

    if cache.opt isa Optim.KrylovTrustRegion
        hv = function (H, θ, v)
            cache.f.hv(H, θ, v, cur...)
            if cache.sense === Optimization.MaxSense
                H .*= false
            end
        end
        optim_f = Optim.TwiceDifferentiableHV(_loss, fg!, hv, cache.u0)
    else
        gg = function (G, θ)
            cache.f.grad(G, θ, cur...)
            if cache.sense === Optimization.MaxSense
                G .*= false
            end
        end

        hh = function (H, θ)
            cache.f.hess(H, θ, cur...)
            if cache.sense === Optimization.MaxSense
                H .*= false
            end
        end
        u0_type = eltype(cache.u0)
        optim_f = Optim.TwiceDifferentiable(_loss, gg, fg!, hh, cache.u0,
                                            real(zero(u0_type)),
                                            Optim.NLSolversBase.alloc_DF(cache.u0,
                                                                         real(zero(u0_type))),
                                            isnothing(cache.f.hess_prototype) ?
                                            Optim.NLSolversBase.alloc_H(cache.u0,
                                                                        real(zero(u0_type))) :
                                            convert.(u0_type, cache.f.hess_prototype))
    end

    opt_args = __map_optimizer_args(cache, cache.opt, callback = _cb,
                                    maxiters = cache.solver_args.maxiters,
                                    maxtime = cache.solver_args.maxtime,
                                    abstol = cache.solver_args.abstol,
                                    reltol = cache.solver_args.reltol;
                                    cache.solver_args...)

    t0 = time()
    opt_res = Optim.optimize(optim_f, cache.u0, cache.opt, opt_args)
    t1 = time()
    opt_ret = Symbol(Optim.converged(opt_res))

    SciMLBase.build_solution(cache, cache.opt,
                             opt_res.minimizer,
                             cache.sense === Optimization.MaxSense ? -opt_res.minimum :
                             opt_res.minimum; original = opt_res, retcode = opt_ret,
                             solve_time = t1 - t0)
end

function SciMLBase.__solve(cache::OptimJLOptimizationCache{F, RC, LB, UB, LC, UC, S, O, D, P
                                                           }) where {
                                                                     F,
                                                                     RC,
                                                                     LB,
                                                                     UB, LC, UC,
                                                                     S,
                                                                     O <:
                                                                     Union{
                                                                           Optim.Fminbox,
                                                                           Optim.SAMIN
                                                                           },
                                                                     D,
                                                                     P
                                                                     }
    local x, cur, state

    cur, state = iterate(cache.data)

    function _cb(trace)
        cb_call = !(cache.opt isa Optim.SAMIN) && cache.opt.method == Optim.NelderMead() ?
                  cache.callback(decompose_trace(trace).metadata["centroid"],
                                 x...) :
                  cache.callback(decompose_trace(trace).metadata["x"], x...)
        if !(typeof(cb_call) <: Bool)
            error("The callback should return a boolean `halt` for whether to stop the optimization process.")
        end
        nx_itr = iterate(cache.data, state)
        if isnothing(nx_itr)
            true
        else
            cur, state = nx_itr
            cb_call
        end
    end

    _loss = function (θ)
        x = cache.f.f(θ, cache.p, cur...)
        __x = first(x)
        return cache.sense === Optimization.MaxSense ? -__x : __x
    end
    fg! = function (G, θ)
        if G !== nothing
            cache.f.grad(G, θ, cur...)
            if cache.sense === Optimization.MaxSense
                G .*= false
            end
        end
        return _loss(θ)
    end

    gg = function (G, θ)
        cache.f.grad(G, θ, cur...)
        if cache.sense === Optimization.MaxSense
            G .*= false
        end
    end
    optim_f = Optim.OnceDifferentiable(_loss, gg, fg!, cache.u0)

    opt_args = __map_optimizer_args(cache, cache.opt, callback = _cb,
                                    maxiters = cache.solver_args.maxiters,
                                    maxtime = cache.solver_args.maxtime,
                                    abstol = cache.solver_args.abstol,
                                    reltol = cache.solver_args.reltol;
                                    cache.solver_args...)

    t0 = time()
    opt_res = Optim.optimize(optim_f, cache.lb, cache.ub, cache.u0, cache.opt, opt_args)
    t1 = time()
    opt_ret = Symbol(Optim.converged(opt_res))

    SciMLBase.build_solution(cache, cache.opt,
                             opt_res.minimizer, opt_res.minimum;
                             original = opt_res, retcode = opt_ret, solve_time = t1 - t0)
end

function SciMLBase.__solve(cache::OptimJLOptimizationCache{F, RC, LB, UB, LC, UC, S, O, D, P
                                                           }) where {
                                                                     F,
                                                                     RC,
                                                                     LB,
                                                                     UB, LC, UC,
                                                                     S,
                                                                     O <:
                                                                     Optim.ConstrainedOptimizer,
                                                                     D,
                                                                     P
                                                                     }
    local x, cur, state

    cur, state = iterate(cache.data)

    function _cb(trace)
        cb_call = cache.callback(decompose_trace(trace).metadata["x"], x...)
        if !(typeof(cb_call) <: Bool)
            error("The callback should return a boolean `halt` for whether to stop the optimization process.")
        end
        nx_itr = iterate(cache.data, state)
        if isnothing(nx_itr)
            true
        else
            cur, state = nx_itr
            cb_call
        end
    end

    _loss = function (θ)
        x = cache.f.f(θ, cache.p, cur...)
        __x = first(x)
        return cache.sense === Optimization.MaxSense ? -__x : __x
    end
    fg! = function (G, θ)
        if G !== nothing
            cache.f.grad(G, θ, cur...)
            if cache.sense === Optimization.MaxSense
                G .*= false
            end
        end
        return _loss(θ)
    end
    gg = function (G, θ)
        cache.f.grad(G, θ, cur...)
        if cache.sense === Optimization.MaxSense
            G .*= false
        end
    end

    hh = function (H, θ)
        cache.f.hess(H, θ, cur...)
        if cache.sense === Optimization.MaxSense
            H .*= false
        end
    end
    u0_type = eltype(cache.u0)
    optim_f = Optim.TwiceDifferentiable(_loss, gg, fg!, hh, cache.u0,
                                        real(zero(u0_type)),
                                        Optim.NLSolversBase.alloc_DF(cache.u0,
                                                                     real(zero(u0_type))),
                                        isnothing(cache.f.hess_prototype) ?
                                        Optim.NLSolversBase.alloc_H(cache.u0,
                                                                    real(zero(u0_type))) :
                                        convert.(u0_type, cache.f.hess_prototype))

    cons_hl! = function (h, θ, λ)
        res = [similar(h) for i in 1:length(λ)]
        cache.f.cons_h(res, θ)
        for i in 1:length(λ)
            h .+= λ[i] * res[i]
        end
    end

    lb = cache.lb === nothing ? [] : cache.lb
    ub = cache.ub === nothing ? [] : cache.ub
    optim_fc = Optim.TwiceDifferentiableConstraints(cache.f.cons, cache.f.cons_j, cons_hl!,
                                                    lb, ub,
                                                    cache.lcons, cache.ucons)

    opt_args = __map_optimizer_args(cache, cache.opt, callback = _cb,
                                    maxiters = cache.solver_args.maxiters,
                                    maxtime = cache.solver_args.maxtime,
                                    abstol = cache.solver_args.abstol,
                                    reltol = cache.solver_args.reltol;
                                    cache.solver_args...)

    t0 = time()
    opt_res = Optim.optimize(optim_f, optim_fc, cache.u0, cache.opt, opt_args)
    t1 = time()
    opt_ret = Symbol(Optim.converged(opt_res))

    SciMLBase.build_solution(cache, cache.opt,
                             opt_res.minimizer, opt_res.minimum;
                             original = opt_res, retcode = opt_ret)
end

end
