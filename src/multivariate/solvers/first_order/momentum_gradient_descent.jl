# See p. 280 of Murphy's Machine Learning
# x_k1 = x_k - alpha * gr + mu * (x - x_previous)

struct MomentumGradientDescent{IL,L} <: Optimizer
    mu::Float64
    alphaguess!::IL
    linesearch!::L
    manifold::Manifold
end

Base.summary(::MomentumGradientDescent) = "Momentum Gradient Descent"

function MomentumGradientDescent(; mu::Real = 0.01,
                                 alphaguess = LineSearches.InitialPrevious(), # TODO: investigate good defaults
                                 linesearch = LineSearches.HagerZhang(),        # TODO: investigate good defaults
                                 manifold::Manifold=Flat())
    MomentumGradientDescent(Float64(mu), alphaguess, linesearch, manifold)
end

mutable struct MomentumGradientDescentState{T,N}
    x::Array{T,N}
    x_previous::Array{T,N}
    x_momentum::Array{T,N}
    f_x_previous::T
    s::Array{T,N}
    @add_linesearch_fields()
end

function initial_state(method::MomentumGradientDescent, options, d, initial_x::Array{T}) where T
    initial_x = copy(initial_x)
    retract!(method.manifold, real_to_complex(d,initial_x))

    # Force evaluation of the objective, gradient
    value_gradient!(d, initial_x)
    value_gradient!(d, initial_x)

    project_tangent!(method.manifold, real_to_complex(d,gradient(d)), real_to_complex(d,initial_x))

    MomentumGradientDescentState(initial_x, # Maintain current state in state.x
                                 copy(initial_x), # Maintain previous state in state.x_previous
                                 similar(initial_x), # Record momentum correction direction in state.x_momentum
                                 T(NaN), # Store previous f in state.f_x_previous
                                 similar(initial_x), # Maintain current search direction in state.s
                                 @initial_linesearch()...) # Maintain a cache for line search results in state.lsr
end

function update_state!(d, state::MomentumGradientDescentState{T}, method::MomentumGradientDescent) where T
    project_tangent!(method.manifold, real_to_complex(d,gradient(d)), real_to_complex(d,state.x))
    # Search direction is always the negative gradient
    state.s .= .-gradient(d)

    # Update position, and backup current one
    state.x_momentum .= state.x .- state.x_previous

    # Determine the distance of movement along the search line
    lssuccess = perform_linesearch!(state, method, ManifoldObjective(method.manifold, d))

    state.x .+= state.alpha.*state.s .+ method.mu.*state.x_momentum
    retract!(method.manifold, real_to_complex(d,state.x))
    lssuccess == false # break on linesearch error
end

function assess_convergence(state::MomentumGradientDescentState, d, options)
  default_convergence_assessment(state, d, options)
end

function trace!(tr, d, state, iteration, method::MomentumGradientDescent, options)
  common_trace!(tr, d, state, iteration, method, options)
end
