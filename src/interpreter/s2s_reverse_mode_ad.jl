#=
    SharedDataPairs()

A data structure used to manage the captured data in the `OpaqueClosures` which implement
the bulk of the forwards- and reverse-passes of AD. An entry `(id, data)` at element `n`
of the `pairs` field of this data structure means that `data` will be available at register
`id` during the forwards- and reverse-passes of `AD`.

This is achieved by storing all of the data in the `pairs` field in the captured tuple which
is passed to an `OpaqueClosure`, and extracting this data into registers associated to the
corresponding `ID`s.
=#
struct SharedDataPairs
    pairs::Vector{Tuple{ID, Any}}
    SharedDataPairs() = new(Tuple{ID, Any}[])
end

#=
    add_data!(p::SharedDataPairs, data)::ID

Puts `data` into `p`, and returns the `id` associated to it. This `id` should be assumed to
be available during the forwards- and reverse-passes of AD, and it should further be assumed
that the value associated to this `id` is always `data`.
=#
function add_data!(data_pairs::SharedDataPairs, data)::ID
    id = ID()
    push!(data_pairs.pairs, (id, data))
    return id
end

#=
    shared_data_tuple(data_pairs::SharedDataPairs)::Tuple

Create the tuple that will constitute the captured variables in the forwards- and reverse-
pass `OpaqueClosure`s.

For example, if the `pairs` field of `data_pairs.pairs` is
```julia
[(ID(5), 5.0), (ID(3), "hello")]
```
then the output of this function is
```julia
(5.0, "hello")
```
=#
shared_data_tuple(data_pairs::SharedDataPairs) = tuple(map(last, data_pairs.pairs)...)

#=
    shared_data_stmts(data_pairs::SharedDataPairs)::Vector{Tuple{ID, Any}}

Produce a sequence of id-statment pairs which will extract the data from
`shared_data_tuple(data_pairs)` such that the correct value is associated to the correct
`ID`.

For example, if the `pairs` field of `data_pairs.pairs` is
```julia
[(ID(5), 5.0), (ID(3), "hello")]
```
then the output of this function is
```julia
Tuple{ID, Any}[
    (ID(5), :(getfield(_1, 1))),
    (ID(3), :(getfield(_1, 2))),
]
```
=#
function shared_data_stmts(data_pairs::SharedDataPairs)::Vector{Tuple{ID, Any}}
    stmts = Vector{Tuple{ID, Any}}(undef, length(data_pairs.pairs))
    for (n, p) in enumerate(data_pairs.pairs)
        stmts[n] = (p[1], Expr(:call, getfield, Argument(1), n))
    end
    return stmts
end

#=
    ADInfo

This data structure is used to hold "global" information associated to a particular call to
`build_rrule`. It is used as a means of communication between `make_ad_stmts!` and the
codegen which produces the forwards- and reverse-passes.

- `interp`: a `TapedInterpreter`.
- `block_stack_id`: the ID associated to the block stack -- the stack which keeps track of
    which blocks we visited during the forwards-pass, and which is used on the reverse-pass
    to determine which blocks to visit. The location in the shared data storage associated
    to this can be retrieved using `block_stack_index`.
- `block_stack`: the block stack. Can always be found at `block_stack_id` in the forwards-
    and reverse-passes.
- `entry_id`: special ID associated to saying "there was no predecessor to this block".
- `shared_data_pairs`: the `SharedDataPairs` associated to th.
- `arg_types`: a map from `Argument` to its static type.
- `ssa_types`: a map from `ID` associated to lines to their static type.
=#
struct ADInfo
    interp::TInterp
    block_stack_id::ID
    block_stack::Stack{Int}
    entry_id::ID
    shared_data_pairs::SharedDataPairs
    arg_types::Dict{Argument, Any}
    ssa_types::Dict{ID, Any}
end

# The constructor that you should use for ADInfo.
function ADInfo(interp::TInterp, arg_types::Dict{Argument, Any}, ssa_types::Dict{ID, Any})
    shared_data_pairs = SharedDataPairs()
    bs = Stack{Int}()
    bs_id = add_data!(shared_data_pairs, bs)
    return ADInfo(interp, bs_id, bs, ID(), shared_data_pairs, arg_types, ssa_types)
end

# Returns the statically-inferred type associated to `x`.
get_primal_type(info::ADInfo, x::Argument) = info.arg_types[x]
get_primal_type(info::ADInfo, x::ID) = info.ssa_types[x]
get_primal_type(::ADInfo, x::QuoteNode) = _typeof(x.value)
get_primal_type(::ADInfo, x) = _typeof(x)
function get_primal_type(::ADInfo, x::GlobalRef)
    return isconst(x) ? _typeof(getglobal(x.mod, x.name)) : x.binding.ty
end

#=
    ADStmtInfo

Data structure which contains the result of `make_ad_stmts!`. Fields are
- `line`: the ID associated to the primal line from which this is derived
- `fwds`: the instruction which runs the forwards-pass of AD
- `rvs`: the instruction which runs the reverse-pass of AD / the pullback

For `rvs`, a value of `nothing` indicates that there should be no instruction associated
to the primal statement in the pullback.
=#
struct ADStmtInfo
    line::ID
    fwds::Vector{Tuple{ID, Any}}
    rvs
end

ad_stmt_info(line::ID, fwds::Vector{Tuple{ID, Any}}, rvs) = ADStmtInfo(line, fwds, rvs)
ad_stmt_info(line::ID, fwds, rvs) = ADStmtInfo(line, Tuple{ID, Any}[(line, fwds)], rvs)

#=
    make_ad_stmts(stmt, line::ID, info::ADInfo)::ADStmtInfo

Every line in the primal code is associated to exactly one line in the forwards-pass of AD,
and either one or zero lines in the pullback (many nodes do not need to appear in the
pullback at all). This function specifies this translation for every type of node.

Translates the statement `stmt`, associated to `line` in the primal, into a specification of
what should happen for this statement in the forwards- and reverse-passes of AD, and what
data should be shared between the forwards- and reverse-passes. Returns this in the form of
an `ADStmtInfo`.

`info` is a data structure containing various bits of global information that certain types
of nodes need access to.
=#
function make_ad_stmts! end

# `nothing` as a statement in Julia IR indicates the presence of a line which will later be
# removed. We emit a no-op on both the forwards- and reverse-passes. No shared data.
make_ad_stmts!(::Nothing, line::ID, ::ADInfo) = ad_stmt_info(line, nothing, nothing)

# Identity forwards-pass, no-op reverse. No shared data.
function make_ad_stmts!(stmt::ReturnNode, line::ID, info::ADInfo)
    if !isdefined(stmt, :val) || isa(stmt.val, Union{Argument, ID})
        return ad_stmt_info(line, inc_arg_numbers(stmt), nothing)
    else
        aug_reg = augmented_const_components(stmt.val, info)
        return ad_stmt_info(line, ReturnNode(aug_reg), nothing)
    end
end

# Identity forwards-pass, no-op reverse. No shared data.
function make_ad_stmts!(stmt::IDGotoNode, line::ID, ::ADInfo)
    return ad_stmt_info(line, inc_arg_numbers(stmt), nothing)
end

# Identity forwards-pass, no-op reverse. No shared data.
function make_ad_stmts!(stmt::IDGotoIfNot, line::ID, ::ADInfo)
    stmt = inc_arg_numbers(stmt)
    if stmt.cond isa Union{Argument, ID}
        # If cond refers to a register, then the primal must be extracted.
        cond_id = ID()
        cond = Expr(:call, primal, stmt.cond)
        fwds = Tuple{ID, Any}[(cond_id, cond), (line, IDGotoIfNot(cond_id, stmt.dest))]
        return ad_stmt_info(line, fwds, nothing)
    else
        # If something other than a register, then there is nothing to do.
        return ad_stmt_info(line, stmt, nothing)
    end
end

# Identity forwards-pass, no-op reverse. No shared data.
function make_ad_stmts!(stmt::IDPhiNode, line::ID, info::ADInfo)
    values = stmt.values
    new_values = Vector{Any}(undef, length(values))
    for n in eachindex(values)
        isassigned(values, n) || continue
        if values[n] isa Union{Argument, ID}
            new_values[n] = __inc(values[n])
        else
            if tangent_type(_typeof(get_primal_value(values[n]))) == NoTangent
                new_values[n] = build_const_reg(values[n])
            else
                new_values[n] = augmented_const_components(values[n], info)
            end
        end
    end
    return ad_stmt_info(line, IDPhiNode(stmt.edges, new_values), nothing)
end

function make_ad_stmts!(stmt::PiNode, line::ID, info::ADInfo)
    isa(stmt.val, Union{Argument, ID}) || unhandled_feature("PiNode: $stmt")

    # Create line which sharpens the register type as much as possible.
    sharp_primal_type = _get_type(stmt.typ)
    sharpened_register_type = AugmentedRegister{codual_type(_get_type(sharp_primal_type))}
    new_pi_line = ID()
    new_pi = PiNode(__inc(stmt.val), sharpened_register_type)

    # Create a statement which moves data from the loosely-typed register to a more
    # strictly typed one, which is possible because of the `PiNode`.
    tangent_stack = make_tangent_stack(sharp_primal_type)
    tangent_stack_id = add_data!(info.shared_data_pairs, tangent_stack)
    val_type = get_primal_type(info, stmt.val)
    tangent_ref_stack = make_tangent_ref_stack(tangent_ref_type_ub(val_type))
    tangent_ref_stack_id = add_data!(info.shared_data_pairs, tangent_ref_stack)
    new_line = Expr(:call, __pi_fwds!, tangent_stack_id, tangent_ref_stack_id, new_pi_line)

    # Assemble the above lines and construct reverse-pass.
    return ADStmtInfo(
        line,
        Tuple{ID, Any}[(new_pi_line, new_pi), (line, new_line)],
        Expr(:call, __pi_rvs!, tangent_stack_id, tangent_ref_stack_id),
    )
end

@inline function __pi_fwds!(tangent_stack, tangent_ref_stack, reg::AugmentedRegister)
    push!(tangent_ref_stack, reg.tangent_ref)
    push!(tangent_stack, tangent(reg.codual))
    return AugmentedRegister(reg.codual, top_ref(tangent_stack))
end

@inline function __pi_rvs!(tangent_stack, tangent_ref_stack)
    increment_ref!(pop!(tangent_ref_stack), pop!(tangent_stack))
    return nothing
end

# Constant GlobalRefs are handled. See const_register. Non-constant
# GlobalRefs are not handled by Taped -- an appropriate error is thrown.
make_ad_stmts!(stmt::GlobalRef, line::ID, info::ADInfo) = const_register(stmt, line, info)

# QuoteNodes are constant. See make_const_register for details.
make_ad_stmts!(stmt::QuoteNode, line::ID, info::ADInfo) = const_register(stmt, line, info)

# Literal constant. See const_register for details.
make_ad_stmts!(stmt, line::ID, info::ADInfo) = const_register(stmt, line, info)

# If `primal_type` is provably non-differentiable, return statement with no tangent stack.
# Otherwise return an AugmentedRegister whose tangent_stack is stored in shared data.
function const_register(stmt, line::ID, info::ADInfo)
    primal_value = get_primal_value(stmt)
    if tangent_type(_typeof(primal_value)) == NoTangent
        return ad_stmt_info(line, build_const_reg(primal_value), nothing)
    else
        const_reg_id = augmented_const_components(stmt, info)
        return ad_stmt_info(line, Expr(:call, identity, const_reg_id), nothing)
    end
end

# line should always be the primal line associated to the instruction you are producing.
function augmented_const_components(stmt, info::ADInfo)
    return add_data!(info.shared_data_pairs, build_const_reg(stmt))
end

function build_const_reg(stmt)
    primal_value = get_primal_value(stmt)
    tangent_stack = make_tangent_stack(_typeof(primal_value))
    tangent = uninit_tangent(primal_value)
    push!(tangent_stack, tangent)
    return AugmentedRegister(CoDual(primal_value, tangent), top_ref(tangent_stack))
end

function get_primal_value(x::GlobalRef)
    isconst(x) || unhandled_feature("Non-constant GlobalRef not supported")
    return getglobal(x.mod, x.name)
end
get_primal_value(x::QuoteNode) = x.value
get_primal_value(x) = x

# Taped does not yet handle `PhiCNode`s. Throw an error if one is encountered.
function make_ad_stmts!(stmt::Core.PhiCNode, ::ID, ::ADInfo)
    unhandled_feature("Encountered PhiCNode: $stmt")
end

# Taped does not yet handle `UpsilonNode`s. Throw an error if one is encountered.
function make_ad_stmts!(stmt::Core.UpsilonNode, ::ID, ::ADInfo)
    unhandled_feature("Encountered UpsilonNode: $stmt")
end

# There are quite a number of possible `Expr`s that can be encountered. Each case has its
# own comment, explaining what is going on.
function make_ad_stmts!(stmt::Expr, line::ID, info::ADInfo)
    is_invoke = Meta.isexpr(stmt, :invoke)
    if Meta.isexpr(stmt, :call) || is_invoke

        # Find the types of all arguments to this call / invoke.
        args = ((is_invoke ? stmt.args[2:end] : stmt.args)..., )
        arg_types = map(arg -> get_primal_type(info, arg), args)

        # Construct signature, and determine how the rrule is to be computed.
        sig = Tuple{arg_types...}
        rule = if is_primitive(context_type(info.interp), sig)
            rrule!! # intrinsic / builtin / thing we provably have rule for
        elseif is_invoke
            LazyDerivedRule(info.interp, sig) # Static dispatch
        else
            DynamicDerivedRule(info.interp)  # Dynamic dispatch
        end

        # Create data shared between the forwards- and reverse-passes.
        data = (
            rule=rule,
            pb_stack=build_pb_stack(_typeof(rule), arg_types),
            my_tangent_stack=make_tangent_stack(get_primal_type(info, line)),
            arg_tangent_ref_stacks=map(__make_arg_tangent_ref_stack, arg_types, args),
        )

        # Get a location in the global captures in which `data` can live.
        data_id = add_data!(info.shared_data_pairs, data)

        # Create a call to `fwds_pass!`, which runs the forwards-pass. `Argument(0)` always
        # contains the global collection of captures.
        inc_args = map(__inc, args)
        return_type = register_type(get_primal_type(info, line))
        fwds = Expr(:call, __fwds_pass!, data_id, return_type, inc_args...)
        rvs = Expr(:call, __rvs_pass!, data_id)
        return ad_stmt_info(line, fwds, rvs)

    elseif Meta.isexpr(stmt, :boundscheck)
        tmp = AugmentedRegister(zero_codual(true), NoTangentStack())
        return ad_stmt_info(line, tmp, nothing)

    elseif Meta.isexpr(stmt, :code_coverage_effect)
        # Code coverage irrelevant for derived code.
        return ad_stmt_info(line, nothing, nothing)

    elseif Meta.isexpr(stmt, :loopinfo)
        # Cannot pass loopinfo back through the optimiser for some reason.
        # At the time of writing, I am unclear why this is not possible.
        return ad_stmt_info(line, nothing, nothing)

    elseif stmt.head in [
        :gc_preserve_begin,
        :gc_preserve_end,
        :enter,
        :leave,
        :pop_exception,
        :throw_undef_if_not
    ]
        # Expressions which do not require any special treatment.
        return ad_stmt_info(line, stmt, nothing)
    else
        # Encountered an expression that we've not seen before.
        throw(error("Unrecognised expression $stmt"))
    end
end

function __make_arg_tangent_ref_stack(arg_type, arg)
    is_active(arg) || return InactiveStack(InactiveRef(__zero_tangent(arg)))
    return make_tangent_ref_stack(tangent_ref_type_ub(arg_type))
end

is_active(::Union{Argument, ID}) = true
is_active(::Any) = false

__zero_tangent(arg) = zero_tangent(arg)
__zero_tangent(arg::GlobalRef) = zero_tangent(getglobal(arg.mod, arg.name))
__zero_tangent(arg::QuoteNode) = zero_tangent(arg.value)

function build_pb_stack(Trule, arg_types)
    T_pb!! = Core.Compiler.return_type(Tuple{Trule, map(codual_type, arg_types)...})
    if T_pb!! <: Tuple && T_pb!! !== Union{}
        F = T_pb!!.parameters[2]
        return Base.issingletontype(F) ? SingletonStack{F}() : Stack{F}()
    else
        return Stack{Any}()
    end
end

# Used in `make_ad_stmts!` method for `Expr(:call, ...)` and `Expr(:invoke, ...)`.
#
# Executes the fowards-pass. `data` is the data shared between the forwards-pass and
# pullback. It must be a `NamedTuple` with fields `arg_tangent_stacks`, `rule`,
# `my_tangent_stack`, and `pb_stack`.
@inline function __fwds_pass!(data, ::Type{R}, f::F, raw_args::Vararg{Any, N}) where {R, F, N}

    raw_args = (f, raw_args...)

    # Log the location of the tangents associated to each argument.
    tangent_refs = map(x -> isa(x, AugmentedRegister) ? x.tangent_ref : nothing, raw_args)
    map(__push_ref_stack, data.arg_tangent_ref_stacks, tangent_refs)

    # Run the rule.
    args = map(x -> isa(x, AugmentedRegister) ? x.codual : uninit_codual(x), raw_args)
    out, pb!! = data.rule(args...)

    # Log the results and return.
    push!(data.my_tangent_stack, tangent(out))
    push!(data.pb_stack, pb!!)
    return AugmentedRegister(out, top_ref(data.my_tangent_stack))::R
end

@inline __push_ref_stack(tangent_ref_stack, ref) = push!(tangent_ref_stack, ref)
@inline __push_ref_stack(::InactiveStack, ref) = nothing
@inline __push_ref_stack(::NoTangentRefStack, ref) = nothing

# Used in `make_ad_stmts!` method for `Expr(:call, ...)` and `Expr(:invoke, ...)`.
#
# Executes the reverse-pass. `data` is the `NamedTuple` shared with `fwds_pass!`.
# Much of this pass will be optimised away in practice.
@inline function __rvs_pass!(data)::Nothing

    # Get the tangent w.r.t. output, and the pullback, from this instructions' stacks.
    dout = pop!(data.my_tangent_stack)
    pb!! = pop!(data.pb_stack)

    # Get the tangent w.r.t. each argument of the primal.
    tangent_stacks = tuple_map(pop!, data.arg_tangent_ref_stacks)

    # Run the pullback and increment the argument tangents.
    dargs = tuple_map(set_immutable_to_zero ∘ getindex, tangent_stacks)
    new_dargs = pb!!(dout, dargs...)
    map(increment_ref!, tangent_stacks, new_dargs)

    return nothing
end

#
# Runners for generated code.
#

struct Pullback{Tpb, Tret_ref, Targ_tangent_stacks, Tisva, Tnargs}
    pb_oc::Tpb
    ret_ref::Tret_ref
    arg_tangent_stacks::Targ_tangent_stacks
    isva::Tisva
    nargs::Tnargs
end

function (pb::Pullback{P, Q})(dy, dargs::Vararg{Any, N}) where {P, Q, N}
    dargs = __unflatten_varargs(pb.isva, dargs, pb.nargs)
    map(setindex!, map(top_ref, pb.arg_tangent_stacks), dargs)
    increment_ref!(pb.ret_ref, dy)
    pb.pb_oc(dy, dargs...)
    return __flatten_varargs(pb.isva, map(pop!, pb.arg_tangent_stacks))
end

struct DerivedRule{Tfwds_oc, Targ_tangent_stacks, Tpb_oc, Tisva<:Val, Tnargs<:Val}
    fwds_oc::Tfwds_oc
    pb_oc::Tpb_oc
    arg_tangent_stacks::Targ_tangent_stacks
    block_stack::Stack{Int}
    entry_id::ID
    isva::Tisva
    nargs::Tnargs
end

function (fwds::DerivedRule{P, Q, S})(args::Vararg{CoDual, N}) where {P, Q, S, N}

    # Load arguments in to stacks, and create tuples.
    args = __unflatten_codual_varargs(fwds.isva, args, fwds.nargs)
    args_with_tangent_stacks = map(args, fwds.arg_tangent_stacks) do arg, arg_tangent_stack
        push!(arg_tangent_stack, tangent(arg))
        return AugmentedRegister(arg, top_ref(arg_tangent_stack))
    end

    # Run forwards-pass.
    reg = fwds.fwds_oc(args_with_tangent_stacks...)::AugmentedRegister

    # Extract result and assemble pullback.
    return reg.codual, Pullback(fwds.pb_oc, reg.tangent_ref, fwds.arg_tangent_stacks, fwds.isva, fwds.nargs)
end

# Compute the concrete type of the rule that will be returned from `build_rrule`. This is
# important for performance in dynamic dispatch, and to ensure that recursion works
# properly.
function rule_type(interp::TapedInterpreter{C}, ::Type{sig}) where {C, sig}
    is_primitive(C, sig) && return typeof(rrule!!)

    ir, Treturn = lookup_ir(interp, sig)
    isva, _ = is_vararg_sig_and_sparam_names(sig)

    arg_types = map(_get_type, ir.argtypes)
    arg_tangent_types = map(tangent_type, arg_types)
    return DerivedRule{
        Core.OpaqueClosure{Tuple{map(register_type, arg_types)...}, register_type(Treturn)},
        Tuple{map(tangent_stack_type ∘ _get_type, ir.argtypes)...},
        Core.OpaqueClosure{Tuple{tangent_type(Treturn), arg_tangent_types...}, Nothing},
        Val{isva},
        Val{length(ir.argtypes)},
    }
end

# if isva and nargs=2, then inputs (5.0, 4.0, 3.0) are transformed into (5.0, (4.0, 3.0)).
function __unflatten_varargs(::Val{isva}, args, ::Val{nargs}) where {isva, nargs}
    return isva ? (args[1:nargs-1]..., args[nargs:end]) : args
end

# If isva, inputs (5.0, (4.0, 3.0)) are transformed into (5.0, 4.0, 3.0).
function __flatten_varargs(::Val{isva}, args) where {isva}
    return isva ? (args[1:end-1]..., args[end]...) : args
end

# If isva and nargs=2, then inputs `(CoDual(5.0, 0.0), CoDual(4.0, 0.0), CoDual(3.0, 0.0))`
# are transformed into `(CoDual(5.0, 0.0), CoDual((5.0, 4.0), (0.0, 0.0)))`.
function __unflatten_codual_varargs(::Val{isva}, args, ::Val{nargs}) where {isva, nargs}
    isva || return args
    grouped_args = CoDual(map(primal, args[nargs:end]), map(tangent, args[nargs:end]))
    return (args[1:nargs-1]..., grouped_args)
end

"""
    build_rrule(args...)

Helper method. Only uses static information from `args`.
"""
build_rrule(args...) = build_rrule(TapedInterpreter(), Tuple{map(_typeof, args)...})

"""
    build_rrule(interp::TInterp{C}, sig::Type{<:Tuple}) where {C}

Returns a `DerivedRule` which is an `rrule!!` for `sig` in context `C`.
"""
function build_rrule(interp::TInterp{C}, sig::Type{<:Tuple}) where {C}

    # If we have a hand-coded rule, just use that.
    is_primitive(C, sig) && return rrule!!

    # Grab code associated to the primal.
    ir, Treturn = lookup_ir(interp, sig)

    # Normalise the IR, and generated BBCode version of it.
    isva, spnames = is_vararg_sig_and_sparam_names(sig)
    ir = normalise!(ir, spnames)
    primal_ir = BBCode(ir)

    # Compute global info.
    arg_types = Dict{Argument, Any}(
        map(((n, t),) -> (Argument(n) => _get_type(t)), enumerate(ir.argtypes))
    )
    ssa_types = Dict{ID, Any}(
        map((id, t) -> (id, _get_type(t)), concatenate_ids(primal_ir), ir.stmts.type)
    )
    info = ADInfo(interp, arg_types, ssa_types)

    # For each block in the fwds and pullback BBCode, translate all statements.
    ad_stmts_blocks = map(primal_ir.blocks) do primal_blk
        ids = concatenate_ids(primal_blk)
        primal_stmts = concatenate_stmts(primal_blk)
        return (primal_blk.id, make_ad_stmts!.(primal_stmts, ids, Ref(info)))
    end

    # Make shared data, and construct BBCode for forwards-pass and pullback.
    shared_data = shared_data_tuple(info.shared_data_pairs)
    fwds_ir = forwards_pass_ir(primal_ir, ad_stmts_blocks, info, _typeof(shared_data))
    pb_ir = pullback_ir(primal_ir, Treturn, ad_stmts_blocks, info, _typeof(shared_data))

    # Construct opaque closures and arg tangent stacks, and build the rule.
    # println("ir")
    # display(ir)
    # println("fwds")
    # display(IRCode(fwds_ir))
    # display("fwds_optimised")
    # display(optimise_ir!(IRCode(fwds_ir); do_inline=false))
    # println("pb")
    # display(IRCode(pb_ir))
    # println("pb optimised")
    # display(optimise_ir!(IRCode(pb_ir); do_inline=false))
    fwds_oc = OpaqueClosure(optimise_ir!(IRCode(fwds_ir)), shared_data...; do_compile=true)
    pb_oc = OpaqueClosure(optimise_ir!(IRCode(pb_ir)), shared_data...; do_compile=true)
    arg_tangent_stacks = (map(make_tangent_stack ∘ _get_type, primal_ir.argtypes)..., )
    return DerivedRule(
        fwds_oc,
        pb_oc,
        arg_tangent_stacks,
        info.block_stack,
        info.entry_id,
        Val(isva),
        Val(length(ir.argtypes)),
    )
end

const ADStmts = Vector{Tuple{ID, Vector{ADStmtInfo}}}

#=
    forwards_pass_ir(ir::BBCode, ad_stmts_blocks::ADStmts, info::ADInfo, Tshared_data)

Produce the IR associated to the `OpaqueClosure` which runs most of the forwards-pass.
=#
function forwards_pass_ir(ir::BBCode, ad_stmts_blocks::ADStmts, info::ADInfo, Tshared_data)

    # Insert a block at the start which extracts all items from the captures field of the
    # `OpaqueClosure`, which contains all of the data shared between the forwards- and
    # reverse-passes. These are assigned to the `ID`s given by the `SharedDataPairs`.
    # Additionally, push the entry id onto the block stack.
    entry_stmts = vcat(
        shared_data_stmts(info.shared_data_pairs),
        (ID(), Expr(:call, push!, info.block_stack_id, info.entry_id.id))
    )
    entry_block = BBlock(info.entry_id, entry_stmts)

    # Construct augmented version of each basic block from the primal. For each block:
    # 1. pull the translated basic block statements from ad_stmts_blocks.
    # 2. insert a statement which logs the ID of the current block to the block stack.
    # 3. construct and return a BBlock.
    blocks = map(ad_stmts_blocks) do (block_id, ad_stmts)
        fwds_stmts = reduce(vcat, map(x -> x.fwds, ad_stmts))
        ins_loc = length(fwds_stmts) + (isa(fwds_stmts[end][2], Terminator) ? 0 : 1)
        ins_stmt = (ID(), Expr(:call, push!, info.block_stack_id, block_id.id))
        return BBlock(block_id, insert!(fwds_stmts, ins_loc, ins_stmt))
    end

    # Create and return the `BBCode` for the forwards-pass.
    arg_types = vcat(Tshared_data, map(register_type ∘ _get_type, ir.argtypes))
    return BBCode(vcat(entry_block, blocks), arg_types, ir.sptypes, ir.linetable, ir.meta)
end

#=
    pullback_ir(ir::BBCode, Tret, ad_stmts_blocks::ADStmts, info::ADInfo, Tshared_data)

Produce the IR associated to the `OpaqueClosure` which runs most of the pullback.
=#
function pullback_ir(ir::BBCode, Tret, ad_stmts_blocks::ADStmts, info::ADInfo, Tshared_data)

    # Compute the argument types associated to the reverse-pass.
    darg_types = map(tangent_type ∘ _get_type, ir.argtypes)
    arg_types = vcat(Tshared_data, tangent_type(Tret), darg_types)

    # Compute the blocks which return in the primal.
    primal_exit_blocks_inds = findall(is_reachable_return_node ∘ terminator, ir.blocks)

    # If there are no blocks which successfully return in the primal, then the primal never
    # terminates without throwing, meaning that if AD hits this function, it definitely
    # won't succeed on the forwards-pass. As such, the reverse-pass can just be a no-op.
    if isempty(primal_exit_blocks_inds)
        blocks = [BBlock(ID(), Tuple{ID, Any}[(ID(), ReturnNode(nothing))])]
        return BBCode(blocks, arg_types, ir.sptypes, ir.linetable, ir.meta)
    end

    # Create entry block, which pops the block_stack, and switches to whichever block we
    # were in at the end of the forwards-pass.
    exit_blocks_ids = map(n -> ir.blocks[n].id, primal_exit_blocks_inds)
    data_stmts = shared_data_stmts(info.shared_data_pairs)
    switch_stmts = make_switch_stmts(exit_blocks_ids, info)
    entry_block = BBlock(ID(), vcat(data_stmts, switch_stmts))

    # For each basic block in the primal:
    # 1. pull the translated basic block statements from ad_stmts_blocks
    # 2. reverse the statements
    # 3. pop block stack to get the predecessor block
    # 4. insert a switch statement to determine which block to jump to. Restrict blocks
    #   considered to only those which are predecessors of this one. If in the first block,
    #   check whether or not the block stack is empty. If empty, jump to the exit block.
    main_blocks = map(ad_stmts_blocks, enumerate(ir.blocks)) do (blk_id, ad_stmts), (n, blk)
        rvs_stmts = reverse(Tuple{ID, Any}[(x.line, x.rvs) for x in ad_stmts])
        pred_ids = vcat(predecessors(blk, ir), n == 1 ? [info.entry_id] : ID[])
        switch_stmts = make_switch_stmts(pred_ids, info)
        return BBlock(blk_id, vcat(rvs_stmts, switch_stmts))
    end

    # Create an exit block. Simply returns nothing.
    exit_block = BBlock(info.entry_id, Tuple{ID, Any}[(ID(), ReturnNode(nothing))])

    # Create and return `BBCode` for the pullback.
    blks = vcat(entry_block, main_blocks, exit_block)
    return _sort_blocks!(BBCode(blks, arg_types, ir.sptypes, ir.linetable, ir.meta))
end

#=
    make_switch_stmts(pred_ids::Vector{ID}, info::ADInfo)

`preds_ids` comprises the `ID`s associated to all possible predecessor blocks to the primal
block under consideration. Suppose its value is `[ID(1), ID(2), ID(3)]`, then
`make_switch_stmts` emits code along the lines of

```julia
prev_block = pop!(block_stack)
not_pred_was_1 = !(prev_block == ID(1))
not_pred_was_2 = !(prev_block == ID(2))
switch(
    not_pred_was_1 => ID(1),
    not_pred_was_2 => ID(2),
    ID(3)
)
```

In words: `make_switch_stmts` emits code which jumps to whichever block preceded the current
block during the forwards-pass.
=#
function make_switch_stmts(pred_ids::Vector{ID}, info::ADInfo)

    # If there are no predecessors, then we can't possible have hit this block. This can
    # happen when all of the statements in a block have been eliminated, but the Julia
    # optimiser has not removed the block entirely from the `IRCode`. This often presents as
    # a block containing only a single `nothing` statement.
    # Consequently, we just direct this block back towards the entry node. This is safe, as
    # this block will never get hit, and ensures that the block is safe under re-ordering.
    isempty(pred_ids) && return Tuple{ID, Any}[(ID(), IDGotoNode(info.entry_id))]

    # Get the predecessor that we actually had in the primal.
    prev_blk_id = ID()
    prev_blk = Expr(:call, pop!, info.block_stack_id)

    # Compare predecessor from primal with all possible predecessors.
    conds = Tuple{ID, Any}[
        (ID(), Expr(:call, __switch_case, id.id, prev_blk_id)) for id in pred_ids[1:end-1]
    ]

    # Switch statement to change to the predecessor.
    switch = (ID(), Switch(Any[c[1] for c in conds], pred_ids[1:end-1], pred_ids[end]))

    return vcat((prev_blk_id, prev_blk), conds, switch)
end

# Helper function emitted by `make_switch_stmts`.
__switch_case(id::Int, predecessor_id::Int) = !(id === predecessor_id)


#=
    DynamicDerivedRule(interp::TapedInterpreter)

For internal use only.

A callable data structure which, when invoked, calls an rrule specific to the dynamic types
of its arguments. Stores rules in an internal cache to avoid re-deriving.

This is used to implement dynamic dispatch.
=#
struct DynamicDerivedRule{T, V}
    interp::T
    cache::V
end

DynamicDerivedRule(interp::TapedInterpreter) = DynamicDerivedRule(interp, Dict{Any, Any}())

function (dynamic_rule::DynamicDerivedRule)(args::Vararg{Any, N}) where {N}
    sig = Tuple{map(_typeof, map(primal, args))...}
    is_primitive(context_type(dynamic_rule.interp), sig) && return rrule!!(args...)
    rule = get(dynamic_rule.cache, sig, nothing)
    if rule === nothing
        rule = build_rrule(dynamic_rule.interp, sig)
        dynamic_rule.cache[sig] = rule
    end
    rule = rule::rule_type(dynamic_rule.interp, sig)
    return rule(args...)
end

#=
    LazyDerivedRule(interp, sig)

For internal use only.

A type-stable wrapper around a `DerivedRule`, which only instantiates the `DerivedRule`
when it is first called. This is useful, as it means that if a rule does not get run, it
does not have to be derived.
=#
mutable struct LazyDerivedRule{Trule, T, V}
    interp::T
    sig::V
    rule::Trule
    function LazyDerivedRule(interp::T, sig::V) where {T<:TInterp, V<:Type{<:Tuple}}
        return new{rule_type(interp, sig), T, V}(interp, sig)
    end
end

function (rule::LazyDerivedRule)(args::Vararg{Any, N}) where {N}
    if !isdefined(rule, :rule)
        rule.rule = build_rrule(rule.interp, rule.sig)
    end
    return rule.rule(args...)
end