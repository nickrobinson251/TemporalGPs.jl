abstract type AbstractSSM end

"""
    LGSSM <: AbstractSSM

A linear-Gaussian state-space model. Represented in terms of a Gauss-Markov model `gmm` and
a vector of observation covariance matrices.
"""
struct LGSSM{Tgmm<:GaussMarkovModel, TΣ<:AV{<:AM{<:Real}}} <: AbstractSSM
    gmm::Tgmm
    Σ::TΣ
end

Base.:(==)(x::LGSSM, y::LGSSM) = (x.gmm == y.gmm) && (x.Σ == y.Σ)

Base.length(ft::LGSSM) = length(ft.gmm)

dim_obs(ft::LGSSM) = dim_obs(ft.gmm)

dim_latent(ft::LGSSM) = dim_latent(ft.gmm)

Base.eltype(ft::LGSSM) = eltype(ft.gmm)

storage_type(ft::LGSSM) = storage_type(ft.gmm)

Zygote.@nograd storage_type

function is_of_storage_type(ft::LGSSM, s::StorageType)
    return is_of_storage_type((ft.gmm, ft.Σ), s)
end

is_time_invariant(model::LGSSM) = false
is_time_invariant(model::LGSSM{<:GaussMarkovModel, <:Fill}) = is_time_invariant(model.gmm)

Base.getindex(model::LGSSM, n::Int) = (gmm = model.gmm[n], Σ = model.Σ[n])

mean(model::LGSSM) = mean(model.gmm)

function cov(model::LGSSM)
    S = Stheno.cov(model.gmm)
    Σ = Stheno.block_diagonal(model.Σ)
    return S + Σ
end


# Convert a latent Gaussian marginal into an observed Gaussian marginal.
to_observed(H::AM, h::AV, x::Gaussian) = Gaussian(H * x.m + h, H * x.P * H')


"""
    smooth(model::LGSSM, ys::AbstractVector)

Filter, smooth, and compute the log marginal likelihood of the data. Returns all
intermediate quantities.
"""
function smooth(model::LGSSM, ys::AbstractVector)

    lml, x_filter = _filter(model, ys)
    ε = convert(eltype(model), 1e-12)

    # Smooth
    x_smooth = Vector{typeof(last(x_filter))}(undef, length(ys))
    x_smooth[end] = x_filter[end]
    for k in reverse(1:length(x_filter) - 1)
        x = x_filter[k]
        x′ = predict(model[k + 1], x)

        U = cholesky(Symmetric(x′.P + ε * I)).U
        Gt = U \ (U' \ (model.gmm.A[k + 1] * x.P))
        x_smooth[k] = Gaussian(
            _compute_ms(x.m, Gt, x_smooth[k + 1].m, x′.m),
            _compute_Ps(x.P, Gt, x_smooth[k + 1].P, x′.P),
        )
    end

    Hs = model.gmm.H
    hs = model.gmm.h
    return to_observed.(Hs, hs, x_filter), to_observed.(Hs, hs, x_smooth), lml
end

"""
    _compute_ms(mf::AV, Gt::AM, ms′::AV, mp′::AV)

Compute the smoothing mean `ms`, given the filtering mean `mf`, transpose of the smoothing
gain `Gt`, smoothing mean at the next time step `ms′`, and predictive mean at next time step
`mp′`.
"""
_compute_ms(mf::AV, Gt::AM, ms′::AV, mp′::AV) = mf + Gt' * (ms′ - mp′)

"""
    _compute_Ps(Pf::AM, Gt::AM, Ps′::AM, Pp′::AM)

Compute the smoothing covariance `Ps`, given the filtering covariance `Pf`, transpose of the
smoothing gain `Gt`, smoothing covariance at the next time step `Ps′`, and the predictive
covariance at the next time step `Pp′`.
"""
_compute_Ps(Pf::AM, Gt::AM, Ps′::AM, Pp′::AM) = Pf + Gt' * (Ps′ - Pp′) * Gt

function _compute_Ps(
    Pf::Symmetric{<:Real, <:Matrix},
    Gt::Matrix,
    Ps′::Symmetric{<:Real, <:Matrix},
    Pp′::Matrix,
)
    return Symmetric(Pf + Gt' * (Ps′ - Pp′) * Gt)
end

function predict(model::NamedTuple{(:gmm, :Σ)}, x)
    gmm = model.gmm
    return Gaussian(predict(x.m, x.P, gmm.A, gmm.a, gmm.Q)...)
end

function observe(model::NamedTuple{(:gmm, :Σ)}, x::Gaussian)
    gmm = model.gmm
    m_obs = gmm.H * x.m + gmm.h
    P_obs = gmm.H * x.P * gmm.H' + model.Σ
    return Gaussian(m_obs, P_obs)
end

"""
    posterior_rand(rng::AbstractRNG, model::LGSSM, ys::Vector{<:AV{<:Real}})

Draw samples from the posterior over an LGSSM. This is not, currently, an especially
efficient implementation.
"""
function posterior_rand(
    rng::AbstractRNG,
    model::LGSSM,
    ys::Vector{<:AV{<:Real}},
    N_samples::Int,
)
    _, x_filter = _filter(model, ys)

    chol_Q = cholesky.(Symmetric.(model.gmm.Q .+ Ref(1e-15I)))

    x_T = rand(rng, x_filter[end], N_samples)
    x_sample = Vector{typeof(x_T)}(undef, length(ys))
    x_sample[end] = x_T
    for t in reverse(1:length(ys) - 1)

        # Produce joint samples.
        x̃ = rand(rng, x_filter[t], N_samples)
        x̃′ = model.gmm.A[t] * x̃ + model.gmm.a[t] + chol_Q[t].U' * randn(rng, size(x_T)...)

        # Applying conditioning transformation.
        AP = model.gmm.A[t] * x_filter[t].P
        S = Symmetric(model.gmm.A[t] * Matrix(transpose(AP)) + model.gmm.Q[t])
        chol_S = cholesky(S)

        x_sample[t] = x̃ + AP' * (chol_S.U \ (chol_S.U' \ (x_sample[t+1] - x̃′)))
    end

    return map(n -> model.gmm.H[n] * x_sample[n] .+ model.gmm.h[n], eachindex(x_sample))
end

function posterior_rand(rng::AbstractRNG, model::LGSSM, y::Vector{<:Real}, N_samples::Int)
    return posterior_rand(rng, model, [SVector{1}(yn) for yn in y], N_samples)
end



#
# This dispatch to methods specialised to the array type used to represent the LGSSM.
#

decorrelate(model::AbstractSSM, y::AbstractVector) = decorrelate(model, y, copy_first)
correlate(model::AbstractSSM, y::AbstractVector) = correlate(model, y, copy_first)



#
# Things defined in terms of decorrelate
#

whiten(model::AbstractSSM, ys::AbstractVector) = decorrelate(model, ys)[2]

# For _some_ reason beyond my comprehension, this adjoint ensures type-stability.
function Zygote._pullback(
    ctx::Zygote.Context, ::typeof(whiten), model::AbstractSSM, ys::AbstractVector,
)
    out, pb = Zygote._pullback(ctx, decorrelate, model, ys, copy_first)
    function whiten_pullback(Δ)
        _, Δmodel, Δys, _ = pb((0, Δ))
        return nothing, Δmodel, Δys
    end
    return out[2], whiten_pullback
end

Stheno.logpdf(model::AbstractSSM, ys::AbstractVector) = first(decorrelate(model, ys))

_filter(model::AbstractSSM, ys::AbstractVector) = decorrelate(model, ys, pick_last)

#
# Things defined in terms of correlate
#

function Random.rand(rng::AbstractRNG, model::AbstractSSM)
    return correlate(model, rand_αs(rng, model))[2] # last isn't type-stable inside AD.
end

unwhiten(model::AbstractSSM, αs::AbstractVector) = correlate(model, αs)[2]

# For _some_ reason beyond my comprehension, this adjoint ensures type-stability.
function Zygote._pullback(
    ctx::Zygote.Context, ::typeof(unwhiten), model::AbstractSSM, αs::AbstractVector,
)
    out, pb = Zygote._pullback(ctx, correlate, model, αs, copy_first)
    function unwhiten_pullback(Δ)
        _, Δmodel, Δαs, _ = pb((0, Δ))
        return nothing, Δmodel, Δαs
    end
    return out[2], unwhiten_pullback
end

function logpdf_and_rand(rng::AbstractRNG, model::AbstractSSM)
    return correlate(model, rand_αs(rng, model))
end

function rand_αs(rng::AbstractRNG, model::AbstractSSM)
    D = dim_obs(model)
    α = randn(rng, eltype(model), length(model) * D)
    return [α[(n - 1) * D + 1:n * D] for n in 1:length(model)]
end

function rand_αs(rng::AbstractRNG, model::LGSSM{<:GaussMarkovModel{<:AV{<:SArray}}})
    D = dim_obs(model)
    ot = output_type(model)
    α = randn(rng, eltype(model), length(model) * D)

    # For some type-stability reasons, we have to ensure that
    αs = Vector{output_type(model)}(undef, length(model))
    map(n -> setindex!(αs, ot(α[(n - 1) * D + 1:n * D]), n), 1:length(model))
    return αs
end

ChainRulesCore.@non_differentiable rand_αs(::AbstractRNG, ::AbstractSSM)

output_type(ft::LGSSM{<:GaussMarkovModel{<:AV{<:SArray}}}) = eltype(ft.gmm.h)
