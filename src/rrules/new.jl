@eval _new_pullback!!(dy) = (NoRData(), NoRData(), map(_value, dy.fields)...)
@eval _new_pullback!!(dy::Union{Tuple, NamedTuple}) = (NoRData(), NoRData(), dy...)

for N in 0:32
    @eval @inline function _new_(::Type{T}, x::Vararg{Any, $N}) where {T}
        return $(Expr(:new, :T, map(n -> :(x[$n]), 1:N)...))
    end
    @eval function rrule!!(
        ::CoDual{typeof(_new_)}, ::CoDual{Type{P}}, x::Vararg{CoDual, $N}
    ) where {P}
        y = $(Expr(:new, :P, map(n -> :(primal(x[$n])), 1:N)...))
        F = fdata_type(tangent_type(P))
        R = rdata_type(tangent_type(P))
        dy = F == NoFData ? NoFData() : build_fdata(P, tuple_map(tangent, x))
        pb!! = R == NoRData ? NoPullback((NoRData(), NoRData(), tuple_map(zero_rdata, tuple_map(tangent, x))...)) : _new_pullback!!
        return CoDual(y, dy), pb!!
    end
end

@inline @generated function build_fdata(::Type{P}, fdata::Tuple) where {P}
    names = fieldnames(P)
    arg_types = fdata.parameters
    fdata_exprs = map(eachindex(names)) do n
        F = fdata_field_type(P, n)
        if n <= length(arg_types)
            data_expr = Expr(:call, getfield, :fdata, n)
            return F <: PossiblyUninitTangent ? Expr(:call, F, data_expr) : data_expr
        else
            return :($F())
        end
    end
    fdata_tuple = Expr(:call, tuple, fdata_exprs...)
    return :(FData(NamedTuple{$names}($fdata_tuple)))
end

@inline function build_fdata(::Type{P}, fdata::Tuple) where {P<:NamedTuple}
    return fdata_type(tangent_type(P))(fdata)
end

@is_primitive MinimalCtx Tuple{typeof(_new_), Vararg}

function generate_hand_written_rrule!!_test_cases(rng_ctor, ::Val{:new})
    test_cases = Any[
        (false, :stability_and_allocs, nothing, _new_, @NamedTuple{}),
        (false, :stability_and_allocs, nothing, _new_, @NamedTuple{y::Float64}, 5.0),
        (false, :stability_and_allocs, nothing, _new_, @NamedTuple{y::Int, x::Int}, 5, 4),
        (
            false, :stability_and_allocs, nothing,
            _new_, @NamedTuple{y::Float64, x::Int}, 5.0, 4,
        ),
        (
            false, :stability_and_allocs, nothing,
            _new_, @NamedTuple{y::Vector{Float64}, x::Int}, randn(2), 4,
        ),
        (
            false, :stability_and_allocs, nothing,
            _new_, @NamedTuple{y::Vector{Float64}}, randn(2),
        ),
        # (
        #     false, :stability_and_allocs, nothing,
        #     _new_, TestResources.TypeStableStruct{Float64}, 5, 4.0,
        # ),
        # (
        #     false, :stability_and_allocs, nothing,
        #     _new_, TestResources.TypeStableMutableStruct{Float64}, 5.0, 4.0,
        # ),
        # (
        #     false, :none, nothing,
        #     _new_, TestResources.TypeStableMutableStruct{Any}, 5.0, 4.0,
        # ),
        (false, :stability_and_allocs, nothing, _new_, UnitRange{Int64}, 5, 4),
    ]
    memory = Any[]
    return test_cases, memory
end

function generate_derived_rrule!!_test_cases(rng_ctor, ::Val{:new})
    test_cases = Any[]
    memory = Any[]
    return test_cases, memory
end