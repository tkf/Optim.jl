# Notational note
# JMW's dx_history <=> NW's S
# JMW's dg_history <=> NW's Y

# Here alpha is a cache that parallels betas
# It is not the step-size
# q is also a cache
function twoloop!(s::Vector,
                  gr::Vector,
                  rho::Vector,
                  dx_history::Matrix,
                  dg_history::Matrix,
                  m::Integer,
                  pseudo_iteration::Integer,
                  alpha::Vector,
                  q::Vector,
                  scaleinvH0::Bool,
                  precon,
                  devec_fun #all data is passed to this function is flat vectors, but precon might expect something different. this function undoes the flattening
                  )
    # Count number of parameters
    n = length(s)

    # Determine lower and upper bounds for loops
    lower = pseudo_iteration - m
    upper = pseudo_iteration - 1

    # Copy gr into q for backward pass
    copy!(q, gr)

    # Backward pass
    for index in upper:-1:lower
        if index < 1
            continue
        end
        i   = mod1(index, m)
        dgi = view(dg_history, :, i)
        dxi = view(dx_history, :, i)
        @inbounds alpha[i] = rho[i] * vecdot(dxi, q)
        @inbounds q .-= alpha[i] .* dgi
    end

    # Copy q into s for forward pass
    # apply preconditioner if precon != nothing
    # (Note: preconditioner update was done outside of this function)
    if scaleinvH0 == true && pseudo_iteration > 1
        # Use the initial scaling guess if no preconditioner is used
        # See Nocedal & Wright (2nd ed), Equation (7.20)

        #=
        pseudo_iteration > 1 prevents this scaling from happening
        at the first iteration, but also at the first step after
        a reset due to invH being non-positive definite (pseudo_iteration = 1).
        TODO: Maybe we can still use the scaling as long as iteration > 1?
        =#
        i = mod1(upper, m)
        dxi = view(dx_history, :, i)
        dgi = view(dg_history, :, i)
        scaling = dot(dxi, dgi) / sum(abs2, dgi)
        @. s = scaling*q
    else
        A_ldiv_B!(devec_fun(s), precon, devec_fun(q))
    end
    # Forward pass
    for index in lower:1:upper
        if index < 1
            continue
        end
        i = mod1(index, m)
        dgi = view(dg_history, :, i)
        dxi = view(dx_history, :, i)
        @inbounds beta = rho[i] * vecdot(dgi, s)
        @inbounds s .+= dxi .* (alpha[i] - beta)
    end

    # Negate search direction
    scale!(s, -1)

    return
end

struct LBFGS{T, IL, L, Tprep<:Union{Function, Void}} <: Optimizer
    m::Int
    alphaguess!::IL
    linesearch!::L
    P::T
    precondprep!::Tprep
    manifold::Manifold
    scaleinvH0::Bool
end
"""
# LBFGS
## Constructor
```julia
LBFGS(; m::Integer = 10,
alphaguess = LineSearches.InitialStatic(),
linesearch = LineSearches.HagerZhang(),
P=nothing,
precondprep = (P, x) -> nothing,
manifold = Flat(),
scaleinvH0::Bool = true && (typeof(P) <: Void))
```
`LBFGS` has two special keywords; the memory length `m`,
and the `scaleinvH0` flag.
The memory length determines how many previous Hessian
approximations to store.
When `scaleinvH0 == true`,
then the initial guess in the two-loop recursion to approximate the
inverse Hessian is the scaled identity, as can be found in Nocedal and Wright (2nd edition) (sec. 7.2).

In addition, LBFGS supports preconditioning via the `P` and `precondprep`
keywords.

## Description
The `LBFGS` method implements the limited-memory BFGS algorithm as described in
Nocedal and Wright (sec. 7.2, 2006) and original paper by Liu & Nocedal (1989).
It is a quasi-Newton method that updates an approximation to the Hessian using
past approximations as well as the gradient.

## References
 - Wright, S. J. and J. Nocedal (2006), Numerical optimization, 2nd edition. Springer
 - Liu, D. C. and Nocedal, J. (1989). "On the Limited Memory Method for Large Scale Optimization". Mathematical Programming B. 45 (3): 503–528
"""
function LBFGS(; m::Integer = 10,
                 alphaguess = LineSearches.InitialStatic(), # TODO: benchmark defaults
                 linesearch = LineSearches.HagerZhang(),  # TODO: benchmark defaults
                 P=nothing,
                 precondprep = (P, x) -> nothing,
                 manifold::Manifold=Flat(),
                 scaleinvH0::Bool = true && (typeof(P) <: Void) )
    LBFGS(Int(m), alphaguess, linesearch, P, precondprep, manifold, scaleinvH0)
end

Base.summary(::LBFGS) = "L-BFGS"

mutable struct LBFGSState{T,N,M,G}
    x::Array{T,N}
    x_previous::Array{T,N}
    g_previous::G
    rho::Vector{T}
    dx_history::Array{T,M}
    dg_history::Array{T,M}
    dx::Array{T,N}
    dg::Array{T,N}
    u::Array{T,N}
    f_x_previous::T
    twoloop_q
    twoloop_alpha
    pseudo_iteration::Int
    s::Array{T,N}
    @add_linesearch_fields()
end

function initial_state(method::LBFGS, options, d, initial_x::Array{T}) where T
    n = length(initial_x)
    initial_x = copy(initial_x)
    retract!(method.manifold, real_to_complex(d,initial_x))

    # Force evaluation of the objective, gradient
    value_gradient!(d, initial_x)

    project_tangent!(method.manifold, real_to_complex(d,gradient(d)), real_to_complex(d,initial_x))
    LBFGSState(initial_x, # Maintain current state in state.x
              similar(initial_x), # Maintain previous state in state.x_previous
              similar(gradient(d)), # Store previous gradient in state.g_previous
              Vector{T}(method.m), # state.rho
              Matrix{T}(n, method.m), # Store changes in position in state.dx_history
              Matrix{T}(n, method.m), # Store changes in gradient in state.dg_history
              similar(initial_x), # Buffer for new entry in state.dx_history
              similar(initial_x), # Buffer for new entry in state.dg_history
              similar(initial_x), # Buffer stored in state.u
              T(NaN), # Store previous f in state.f_x_previous
              similar(initial_x), #Buffer for use by twoloop
              Vector{T}(method.m), #Buffer for use by twoloop
              0,
              similar(initial_x), # Store current search direction in state.s
              @initial_linesearch()...) # Maintain a cache for line search results in state.lsr
end

function update_state!(d, state::LBFGSState{T}, method::LBFGS) where T
    n = length(state.x)
    # Increment the number of steps we've had to perform
    state.pseudo_iteration += 1

    project_tangent!(method.manifold, real_to_complex(d,gradient(d)), real_to_complex(d,state.x))

    # update the preconditioner
    method.precondprep!(method.P, real_to_complex(d,state.x))

    # Determine the L-BFGS search direction # FIXME just pass state and method?
    devec_fun(x) = real_to_complex(d,reshape(x, size(state.s)))
    twoloop!(vec(state.s), vec(gradient(d)), vec(state.rho), state.dx_history, state.dg_history,
             method.m, state.pseudo_iteration,
             state.twoloop_alpha, vec(state.twoloop_q), method.scaleinvH0, method.P, devec_fun)
    project_tangent!(method.manifold, real_to_complex(d,state.s), real_to_complex(d,state.x))

    # Save g value to prepare for update_g! call
    copy!(state.g_previous, gradient(d))

    # Determine the distance of movement along the search line
    lssuccess = perform_linesearch!(state, method, ManifoldObjective(method.manifold, d))

    # Update current position
    state.dx .= state.alpha .* state.s
    state.x .= state.x .+ state.dx
    retract!(method.manifold, real_to_complex(d,state.x))

    lssuccess == false # break on linesearch error
end


function update_h!(d, state, method::LBFGS)
    n = length(state.x)
    # Measure the change in the gradient
    state.dg .= gradient(d) .- state.g_previous

    # Update the L-BFGS history of positions and gradients
    rho_iteration = one(eltype(state.dx)) / vecdot(state.dx, state.dg)
    if isinf(rho_iteration)
        # TODO: Introduce a formal error? There was a warning here previously
        return true
    end
    idx = mod1(state.pseudo_iteration, method.m)
    @inbounds state.dx_history[:, idx] .= vec(state.dx)
    @inbounds state.dg_history[:, idx] .= vec(state.dg)
    @inbounds state.rho[idx] = rho_iteration
end

function assess_convergence(state::LBFGSState, d, options)
  default_convergence_assessment(state, d, options)
end


function trace!(tr, d, state, iteration, method::LBFGS, options)
  common_trace!(tr, d, state, iteration, method, options)
end
