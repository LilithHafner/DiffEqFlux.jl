abstract type NeuralDELayer <: Function end
basic_tgrad(u,p,t) = zero(u)
Flux.trainable(m::NeuralDELayer) = (m.p,)

"""
Constructs a continuous-time recurrant neural network, also known as a neural
ordinary differential equation (neural ODE), with a fast gradient calculation
via adjoints [1]. At a high level this corresponds to solving the forward
differential equation, using a second differential equation that propagates the
derivatives of the loss backwards in time.

```julia
NeuralODE(model,tspan,alg=nothing,args...;kwargs...)
```

Arguments:

- `model`: A Chain or Lux.AbstractExplicitLayer neural network that defines the ̇x.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to an adjoint method, and with `Lux.AbstractExplicitLayer` it defaults to utilizing
  a tape-compiled ReverseDiff vector-Jacobian product for extra efficiency. Seee
  the [Local Sensitivity Analysis](https://diffeq.sciml.ai/dev/analysis/sensitivity/)
  documentation for more details.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

References:

[1] Pontryagin, Lev Semenovich. Mathematical theory of optimal processes. CRC press, 1987.

"""
struct NeuralODE{M,P,RE,T,A,K} <: NeuralDELayer
    model::M
    p::P
    re::RE
    tspan::T
    args::A
    kwargs::K

    function NeuralODE(model,tspan,args...;p = nothing,kwargs...)
        _p,re = Flux.destructure(model)
        if p === nothing
            p = _p
        end
        new{typeof(model),typeof(p),typeof(re),
            typeof(tspan),typeof(args),typeof(kwargs)}(
            model,p,re,tspan,args,kwargs)
    end

    function NeuralODE(model::Lux.AbstractExplicitLayer,tspan,args...;p=nothing,kwargs...)
      re = nothing
      new{typeof(model),typeof(p),typeof(re),
          typeof(tspan),typeof(args),typeof(kwargs)}(
          model,p,re,tspan,args,kwargs)
    end
end

function (n::NeuralODE)(x,p=n.p)
    dudt_(u,p,t) = n.re(p)(u)
    ff = ODEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = ODEProblem{false}(ff,x,getfield(n,:tspan),p)
    sense = InterpolatingAdjoint(autojacvec=ZygoteVJP())
    solve(prob,n.args...;sensealg=sense,n.kwargs...)
end

function (n::NeuralODE{M})(x,p,st) where {M<:Lux.AbstractExplicitLayer}
  function dudt(u,p,t)
    u_, st = n.model(u,p,st)
    return u_
  end
  ff = ODEFunction{false}(dudt,tgrad=basic_tgrad)
  prob = ODEProblem{false}(ff,x,n.tspan,p)
  sense = InterpolatingAdjoint(autojacvec=ZygoteVJP())
  return solve(prob,n.args...;sensealg=sense,n.kwargs...), st
end

"""
Constructs a neural stochastic differential equation (neural SDE) with diagonal noise.

```julia
NeuralDSDE(model1,model2,tspan,alg=nothing,args...;
           sensealg=TrackerAdjoint(),kwargs...)
NeuralDSDE(model1::Lux.AbstractExplicitLayer,model2::Lux.AbstractExplicitLayer,tspan,alg=nothing,args...;
           sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model1`: A Chain or Lux.AbstractExplicitLayer neural network that defines the drift function.
- `model2`: A Chain or Lux.AbstractExplicitLayer neural network that defines the diffusion function.
  Should output a vector of the same size as the input.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
struct NeuralDSDE{M,P,RE,M2,RE2,T,A,K} <: NeuralDELayer
    p::P
    len::Int
    model1::M
    re1::RE
    model2::M2
    re2::RE2
    tspan::T
    args::A
    kwargs::K
    function NeuralDSDE(model1,model2,tspan,args...;p = nothing, kwargs...)
        p1,re1 = Flux.destructure(model1)
        p2,re2 = Flux.destructure(model2)
        if p === nothing
            p = [p1;p2]
        end
        new{typeof(model1),typeof(p),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(args),typeof(kwargs)}(p,
            length(p1),model1,re1,model2,re2,tspan,args,kwargs)
    end

    function NeuralDSDE(model1::Lux.Chain,model2::Lux.Chain,tspan,args...;
                        p = nothing, kwargs...)
        re1 = nothing
        re2 = nothing
        new{typeof(model1),typeof(p),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(args),typeof(kwargs)}(p,
            Int(1),model1,re1,model2,re2,tspan,args,kwargs)
    end
end

function (n::NeuralDSDE)(x,p=n.p)
    dudt_(u,p,t) = n.re1(p[1:n.len])(u)
    g(u,p,t) = n.re2(p[(n.len+1):end])(u)
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p)
    solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralDSDE{M})(x,p,st1,st2) where {M<:Lux.AbstractExplicitLayer}
    function dudt_(u,p,t)
      u_, st1 = n.model1(u,p[1],st1)
      return u_
    end
    function g(u,p,t)
      u_, st2 = n.model2(u,p[2],st2)
      return u_
    end
    
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p)
    return solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...), st1, st2
end

"""
Constructs a neural stochastic differential equation (neural SDE).

```julia
NeuralSDE(model1,model2,tspan,nbrown,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
NeuralSDE(model1::Lux.AbstractExplicitLayer,model2::Lux.AbstractExplicitLayer,tspan,nbrown,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model1`: A Chain or Lux.AbstractExplicitLayer neural network that defines the drift function.
- `model2`: A Chain or Lux.AbstractExplicitLayer neural network that defines the diffusion function.
  Should output a matrix that is nbrown x size(x,1).
- `tspan`: The timespan to be solved on.
- `nbrown`: The number of Brownian processes
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
struct NeuralSDE{P,M,RE,M2,RE2,T,A,K} <: NeuralDELayer
    p::P
    len::Int
    model1::M
    re1::RE
    model2::M2
    re2::RE2
    tspan::T
    nbrown::Int
    args::A
    kwargs::K
    function NeuralSDE(model1,model2,tspan,nbrown,args...;p=nothing,kwargs...)
        p1,re1 = Flux.destructure(model1)
        p2,re2 = Flux.destructure(model2)
        if p === nothing
            p = [p1;p2]
        end
        new{typeof(p),typeof(model1),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(args),typeof(kwargs)}(
            p,length(p1),model1,re1,model2,re2,tspan,nbrown,args,kwargs)
    end

    function NeuralSDE(model1::Lux.Chain,model2::Lux.Chain,tspan,nbrown,args...;p=nothing,kwargs...)
        re1 = nothing
        re2 = nothing
        new{typeof(p),typeof(model1),typeof(re1),typeof(model2),typeof(re2),
            typeof(tspan),typeof(args),typeof(kwargs)}(
            p,Int(1),model1,re1,model2,re2,tspan,nbrown,args,kwargs)
      end
end

function (n::NeuralSDE)(x,p=n.p)
    dudt_(u,p,t) = n.re1(p[1:n.len])(u)
    g(u,p,t) = n.re2(p[(n.len+1):end])(u)
    ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
    prob = SDEProblem{false}(ff,g,x,n.tspan,p,noise_rate_prototype=zeros(Float32,length(x),n.nbrown))
    solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralSDE{M})(x,p,st1,st2) where {M<:Lux.AbstractExplicitLayer}
  function dudt_(u,p,t)
    u_, st1 = n.model1(u,p[1],st1)
    return u_
  end
  function g(u,p,t)
    u_, st2 = n.model2(u,p[2],st2)
    return u_
  end
  ff = SDEFunction{false}(dudt_,g,tgrad=basic_tgrad)
  prob = SDEProblem{false}(ff,g,x,n.tspan,p,noise_rate_prototype=zeros(Float32,length(x),n.nbrown))
  return solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...), st1, st2
end

"""
Constructs a neural delay differential equation (neural DDE) with constant
delays.

```julia
NeuralCDDE(model,tspan,hist,lags,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
NeuralCDDE(model::Lux.AbstractExplicitLayer,tspan,hist,lags,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model`: A Chain or Lux.AbstractExplicitLayer neural network that defines the derivative function.
  Should take an input of size `[x;x(t-lag_1);...;x(t-lag_n)]` and produce and
  output shaped like `x`.
- `tspan`: The timespan to be solved on.
- `hist`: Defines the history function `h(t)` for values before the start of the
  integration.
- `lags`: Defines the lagged values that should be utilized in the neural network.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
struct NeuralCDDE{M,P,RE,H,L,T,A,K} <: NeuralDELayer
    model::M
    p::P
    re::RE
    hist::H
    lags::L
    tspan::T
    args::A
    kwargs::K

    function NeuralCDDE(model,tspan,hist,lags,args...;p=nothing,kwargs...)
        _p,re = Flux.destructure(model)
        if p === nothing
            p = _p
        end
        new{typeof(model),typeof(p),typeof(re),typeof(hist),typeof(lags),
            typeof(tspan),typeof(args),typeof(kwargs)}(model,p,
            re,hist,lags,tspan,args,kwargs)
    end

    function NeuralCDDE(model::Lux.Chain,tspan,hist,lags,args...;p=nothing,kwargs...)
      re = nothing
      new{typeof(model),typeof(p),typeof(re),typeof(hist),typeof(lags),
          typeof(tspan),typeof(args),typeof(kwargs)}(model,p,
          re,hist,lags,tspan,args,kwargs)
    end
end

function (n::NeuralCDDE)(x,p=n.p)
    function dudt_(u,h,p,t)
        _u = vcat(u,(h(p,t-lag) for lag in n.lags)...)
        n.re(p)(_u)
    end
    ff = DDEFunction{false}(dudt_,tgrad=basic_tgrad)
    prob = DDEProblem{false}(ff,x,n.hist,n.tspan,p,constant_lags = n.lags)
    solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralCDDE{M})(x,p,st) where {M<:Lux.AbstractExplicitLayer}
  function dudt_(u,h,p,t)
      _u = vcat(u,(h(p,t-lag) for lag in n.lags)...)
      u_, st = n.model(_u,p,st)
      return u_
  end
  ff = DDEFunction{false}(dudt_,tgrad=basic_tgrad)
  prob = DDEProblem{false}(ff,x,n.hist,n.tspan,p,constant_lags = n.lags)
  return solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...), st
end

"""
Constructs a neural differential-algebraic equation (neural DAE).

```julia
NeuralDAE(model,constraints_model,tspan,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
NeuralDAE(model::Lux.AbstractExplicitLayer,constraints_model,tspan,alg=nothing,args...;
          sensealg=TrackerAdjoint(),kwargs...)
```

Arguments:

- `model`: A Chain or Lux.AbstractExplicitLayer neural network that defines the derivative function.
  Should take an input of size `x` and produce the residual of `f(dx,x,t)`
  for only the differential variables.
- `constraints_model`: A function `constraints_model(u,p,t)` for the fixed
  constaints to impose on the algebraic equations.
- `tspan`: The timespan to be solved on.
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to using reverse-mode automatic differentiation via Tracker.jl
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
struct NeuralDAE{M,P,M2,D,RE,T,DV,A,K} <: NeuralDELayer
    model::M
    p::P
    constraints_model::M2
    du0::D
    re::RE
    tspan::T
    differential_vars::DV
    args::A
    kwargs::K

    function NeuralDAE(model,constraints_model,tspan,du0=nothing,args...;p=nothing,differential_vars=nothing,kwargs...)
        _p,re = Flux.destructure(model)

        if p === nothing
            p = _p
        end

        new{typeof(model),typeof(p),typeof(constraints_model),
            typeof(du0),typeof(re),typeof(tspan),
            typeof(differential_vars),typeof(args),typeof(kwargs)}(
            model,p,constraints_model,du0,re,tspan,differential_vars,
            args,kwargs)
    end

    function NeuralDAE(model::Lux.Chain,constraints_model,tspan,du0=nothing,args...;p=nothing,differential_vars=nothing,kwargs...)

      new{typeof(model),typeof(p),typeof(constraints_model),
          typeof(du0),typeof(re),typeof(tspan),
          typeof(differential_vars),typeof(args),typeof(kwargs)}(
          model,p,constraints_model,du0,re,tspan,differential_vars,
          args,kwargs)
  end
end

function (n::NeuralDAE)(x,du0=n.du0,p=n.p)
    function f(du,u,p,t)
        nn_out = n.re(p)(vcat(u,du))
        alg_out = n.constraints_model(u,p,t)
        iter_nn = 0
        iter_consts = 0
        map(n.differential_vars) do isdiff
            if isdiff
                iter_nn += 1
                nn_out[iter_nn]
            else
                iter_consts += 1
                alg_out[iter_consts]
            end
        end
    end
    prob = DAEProblem{false}(f,du0,x,n.tspan,p,differential_vars=n.differential_vars)
    solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...)
end

function (n::NeuralDAE{M})(x,p,st,du0=n.du0) where {M<:Lux.AbstractExplicitLayer}
  function f(du,u,p,t)
      _u = vcat(u,du)
      nn_out, st = n.model(_u, p, st)
      alg_out = n.constraints_model(u,p,t)
      iter_nn = 0
      iter_consts = 0
      map(n.differential_vars) do isdiff
          if isdiff
              iter_nn += 1
              nn_out[iter_nn]
          else
              iter_consts += 1
              alg_out[iter_consts]
          end
      end
  end
  prob = DAEProblem{false}(f,du0,x,n.tspan,p,differential_vars=n.differential_vars)
  return solve(prob,n.args...;sensealg=TrackerAdjoint(),n.kwargs...), st
end

"""
Constructs a physically-constrained continuous-time recurrant neural network,
also known as a neural differential-algebraic equation (neural DAE), with a
mass matrix and a fast gradient calculation via adjoints [1]. The mass matrix
formulation is:

```math
Mu' = f(u,p,t)
```

where `M` is semi-explicit, i.e. singular with zeros for rows corresponding to
the constraint equations.

```julia
NeuralODEMM(model,constraints_model,tspan,mass_matrix,alg=nothing,args...;kwargs...)
NeuralODEMM(model::Lux.AbstractExplicitLayer,tspan,mass_matrix,alg=nothing,args...;
          sensealg=InterpolatingAdjoint(autojacvec=DiffEqSensitivity.ReverseDiffVJP(true)),
          kwargs...)
```

Arguments:

- `model`: A Chain or Lux.AbstractExplicitLayer neural network that defines the ̇`f(u,p,t)`
- `constraints_model`: A function `constraints_model(u,p,t)` for the fixed
  constaints to impose on the algebraic equations.
- `tspan`: The timespan to be solved on.
- `mass_matrix`: The mass matrix associated with the DAE
- `alg`: The algorithm used to solve the ODE. Defaults to `nothing`, i.e. the
  default algorithm from DifferentialEquations.jl. This method requires an
  implicit ODE solver compatible with singular mass matrices. Consult the
  [DAE solvers](https://diffeq.sciml.ai/latest/solvers/dae_solve/) documentation for more details.
- `sensealg`: The choice of differentiation algorthm used in the backpropogation.
  Defaults to an adjoint method, and with `Lux.AbstractExplicitLayer` it defaults to utilizing
  a tape-compiled ReverseDiff vector-Jacobian product for extra efficiency. Seee
  the [Local Sensitivity Analysis](https://diffeq.sciml.ai/dev/analysis/sensitivity/)
  documentation for more details.
- `kwargs`: Additional arguments splatted to the ODE solver. See the
  [Common Solver Arguments](https://diffeq.sciml.ai/dev/basics/common_solver_opts/)
  documentation for more details.

"""
struct NeuralODEMM{M,M2,P,RE,T,MM,A,K} <: NeuralDELayer
    model::M
    constraints_model::M2
    p::P
    re::RE
    tspan::T
    mass_matrix::MM
    args::A
    kwargs::K

    function NeuralODEMM(model,constraints_model,tspan,mass_matrix,args...;
                         p = nothing, kwargs...)
        _p,re = Flux.destructure(model)

        if p === nothing
            p = _p
        end
        new{typeof(model),typeof(constraints_model),typeof(p),typeof(re),
            typeof(tspan),typeof(mass_matrix),typeof(args),typeof(kwargs)}(
            model,constraints_model,p,re,tspan,mass_matrix,args,kwargs)
    end

    function NeuralODEMM(model::Lux.Chain,constraints_model,tspan,mass_matrix,args...;
                          p=nothing,kwargs...)
        re = nothing
        new{typeof(model),typeof(constraints_model),typeof(p),typeof(re),
            typeof(tspan),typeof(mass_matrix),typeof(args),typeof(kwargs)}(
            model,constraints_model,p,re,tspan,mass_matrix,args,kwargs)
    end

end

function (n::NeuralODEMM)(x,p=n.p)
    function f(u,p,t)
        nn_out = n.re(p)(u)
        alg_out = n.constraints_model(u,p,t)
        vcat(nn_out,alg_out)
    end
    dudt_= ODEFunction{false}(f,mass_matrix=n.mass_matrix,tgrad=basic_tgrad)
    prob = ODEProblem{false}(dudt_,x,n.tspan,p)

    sense = InterpolatingAdjoint(autojacvec=ZygoteVJP())
    solve(prob,n.args...;sensealg=sense,n.kwargs...)
end

function (n::NeuralODEMM{M})(x,p,st) where {M<:Lux.AbstractExplicitLayer}
  function f(u,p,t)
      nn_out,st = n.model(u,p,st)
      alg_out = n.constraints_model(u,p,t)
      return vcat(nn_out,alg_out)
  end
  dudt_= ODEFunction{false}(f;mass_matrix=n.mass_matrix,tgrad=basic_tgrad)
  prob = ODEProblem{false}(dudt_,x,n.tspan,p)

  sense = InterpolatingAdjoint(autojacvec=ZygoteVJP())
  return solve(prob,n.args...;sensealg=sense,n.kwargs...), st
end

"""
Constructs an Augmented Neural Differential Equation Layer.

```julia
AugmentedNDELayer(nde, adim::Int)
```

Arguments:

- `nde`: Any Neural Differential Equation Layer
- `adim`: The number of dimensions the initial conditions should be lifted

References:

[1] Dupont, Emilien, Arnaud Doucet, and Yee Whye Teh. "Augmented neural ODEs." In Proceedings of the 33rd International Conference on Neural Information Processing Systems, pp. 3140-3150. 2019.

"""
struct AugmentedNDELayer{DE<:NeuralDELayer} <: NeuralDELayer
    nde::DE
    adim::Int
end

(ande::AugmentedNDELayer)(x, args...) = ande.nde(augment(x, ande.adim), args...)

augment(x::AbstractVector{S}, augment_dim::Int) where S =
    cat(x, zeros(S, (augment_dim,)), dims = 1)

augment(x::AbstractArray{S, T}, augment_dim::Int) where {S, T} =
    cat(x, zeros(S, (size(x)[1:(T - 2)]..., augment_dim, size(x, T))), dims = T - 1)

Base.getproperty(ande::AugmentedNDELayer, sym::Symbol) =
    hasproperty(ande, sym) ? getfield(ande, sym) : getfield(ande.nde, sym)
