
"""
Abstract supertype for model wrappers like `Model`, useful
if you need to extend the behaviour of this package.


# Accessing `AbstactModel` parameters

Fields can be accessed with `getindex`:

```julia
model = Model(obj)
@assert model[:val] isa Tuple
@assert model[:val] == model[:val]
@assert model[:units] == model[:units]
```

To get a combined Tuple of `val` and `units`, use [`withunits`](@ref).

The type name of the parent model component, and the field name are also available:

```julia
model[:component]
model[:fieldname]
```


## Getting a `Vector` of parameter values

`Base` methods `collect`, `vec`, and `Array` return a vector of the result of 
`model[:val]`. To get a vector of other parameter fields, simply `collect` the tuple:

```julian
boundsvec = collect(model[:bounds])
```


## Tables.jl interface

All `AbstractModel`s define the Tables.jl interface. This means their paremeters
and parameter metadata can be converted to a `DataFrame` or CSV very easily:

```julia
df = DataFrame(model)
```

Tables.rows will also return all `Param`s as a `Vector` of `NamedTuple`.

To update a model with params from a table, use `update!` or `update`:

```julia
update!(model, table)
```


## `AbstractModel` Interface: Defining your own model wrappers

It may be simplest to use `ModelParameters.jl` on a wrapper type you also use for other 
things. This is what DynamicGrids.jl does with `Ruleset`. It's straightforward to extend 
the interface, nearly everything is taken care of by inheriting from `AbstractModel`. But 
in some circumstances you will need to define additional methods.

`AbstractModel` uses `Base.parent` to return the parent model object.
Either use a field `:parent` on your `<: AbstractModel` type, or add a 
method to `Base.parent`. 

With a custom `parent` field you will also need to define a method for 
[`setparent!`](@ref) and [`setparent`](@ref) that sets the correct field.

An `AbstractModel` with complicated type parameters may require a method of 
`ConstructionBase.constructorof`.

To add custom `show` methods but still print the parameter table, you can use:

```julia
printparams(io::IO, model)
```

That should be all you need to do.
"""
abstract type AbstractModel end

Base.parent(m::AbstractModel) = getfield(m, :parent)
setparent(m::AbstractModel, newparent) = @set m.parent = newparent

params(m::AbstractModel) = params(parent(m))
stripparams(m::AbstractModel) = stripparams(parent(m))
function update(x::T, values) where {T<:AbstractModel} 
    hasfield(T, :parent) || _updatenotdefined(T)
    setparent(x, update(parent(x), values))
end

@noinline _update_methoderror(T) = error("Interface method `update` is not defined for $T")

paramfieldnames(m) = Flatten.fieldnameflatten(parent(m), SELECT, IGNORE)
paramparenttypes(m) = Flatten.metaflatten(parent(m), _fieldparentbasetype, SELECT, IGNORE)

_fieldparentbasetype(T, ::Type{Val{N}}) where N = T.name.wrapper


# Tuple-like indexing and iterables interface

# It may seem expensive always calling `param`, but flattening the
# object occurs once at compile-time, and should have very little cost here.
Base.length(m::AbstractModel) = length(params(m))
Base.size(m::AbstractModel) = (length(params(m)),)
Base.first(m::AbstractModel) = first(params(m))
Base.last(m::AbstractModel) = last(params(m))
Base.firstindex(m::AbstractModel) = 1
Base.lastindex(m::AbstractModel) = length(params(m))
Base.getindex(m::AbstractModel, i) = getindex(params(m), i)
Base.iterate(m::AbstractModel) = (first(params(m)), 1)
Base.iterate(m::AbstractModel, s) = s > length(m) ? nothing : (params(m)[s], s + 1)

# Vector methods
Base.collect(m::AbstractModel) = collect(m.val)
Base.vec(m::AbstractModel) = collect(m)
Base.Array(m::AbstractModel) = vec(m)

# Dict methods - data as columns
Base.haskey(m::AbstractModel, key::Symbol) = key in keys(m)
Base.keys(m::AbstractModel) = _keys(params(m), m)

@inline function Base.setindex!(m::AbstractModel, x, nm::Symbol)
    if nm == :component
        erorr("cannot set :component index")
    elseif nm == :fieldname
        erorr("cannot set :fieldname index")
    else
        newparent = if nm in keys(m)
            _setindex(parent(m), Tuple(x), nm)
        else                                 
            _addindex(parent(m), Tuple(x), nm)
        end
        setparent!(m, newparent)
    end
end
# TODO do this with lenses
@inline function _setindex(obj, xs::Tuple, nm::Symbol)
    lens = Setfield.PropertyLens{nm}()
    newparams = map(params(obj), xs) do par, x
        Param(Setfield.set(parent(par), lens, x))
    end
    Flatten.reconstruct(obj, newparams, SELECT, IGNORE)
end
@inline function _addindex(obj, xs::Tuple, nm::Symbol)
    newparams = map(params(obj), xs) do par, x
        Param((; parent(par)..., (nm => x,)...))
    end
    Flatten.reconstruct(obj, newparams, SELECT, IGNORE)
end

_keys(params::Tuple, m::AbstractModel) = (:component, :fieldname, keys(first(params))...)
_keys(params::Tuple{}, m::AbstractModel) = ()

@inline function Base.getindex(m::AbstractModel, nm::Symbol)
    if nm == :component
        paramparenttypes(m)
    elseif nm == :fieldname
        paramfieldnames(m)
    else
        map(p -> getindex(p, nm), params(m))
    end
end

function Base.show(io::IO, ::MIME"text/plain", m::AbstractModel)
    show(typeof(m))
    println(io, " with parent object of type: \n")
    show(typeof(parent(m)))
    println(io, "\n\n")
    printparams(io::IO, m)
end

printparams(m) = printparams(stdout, m)
function printparams(io::IO, m::AbstractModel)
    if length(m) > 0
        println(io, "Parameters:")
        PrettyTables.pretty_table(io, m, [keys(m)...])
    end
end

setparent!(m::AbstractModel, newparent) = setfield!(m, :parent, newparent)

update!(m::AbstractModel, vals::AbstractVector{<:AbstractParam}) = update!(m, Tuple(vals))
function update!(params::Tuple{<:AbstractParam,Vararg{<:AbstractParam}})
    setparent!(m, Flatten.reconstruct(parent(m), params, SELECT, IGNORE))
end
function update!(m::AbstractModel, table)
    cols = (c for c in Tables.columnnames(table) if !(c in (:component, :fieldname)))
    for col in cols
        setindex!(m, Tables.getcolumn(table, col), col)
    end
    m
end

"""
    Model(x)

A wrapper type for any model containing [`Param`](@ref) parameters - essentially marking 
that a custom struct or Tuple holds `Param` fields.

This allows you to index into the model as if it is a linear list of parameters, or named 
columns of values and paramiter metadata. You can treat it as an iterable, or use the 
Tables.jl interface to save or update the model to/from csv, a `DataFrame` or any source 
that implements the Tables.jl interface.
"""
mutable struct Model <: AbstractModel
    parent
    function Model(parent)
        # Need at least 1 AbstractParam field to be a Model
        if hasparam(parent)
            # Make sure all params have all the same keys.
            expandedpars = _expandkeys(params(parent))
            parent = Flatten.reconstruct(parent, expandedpars, SELECT, IGNORE)
        else
            _noparamwarning()
        end
        new(parent)
    end
end
Model(m::AbstractModel) = Model(parent(m))

Base.getproperty(m::Model, key::Symbol) = getindex(m, key::Symbol)
Base.setproperty!(m::Model, key::Symbol, x) = setindex!(m, x, key::Symbol)

update(x, values::AbstractVector) = update(x, Tuple(values))
function update(x, values)
    newparams = map(params(x), values) do param, value
        Param(NamedTuple{keys(param)}((value, Base.tail(parent(param))...)))
    end
    Flatten.reconstruct(x, newparams, SELECT, IGNORE)
end

"""
    StaticModel(x)

Like [`Model`](@ref) but immutable. This means it can't be used as a
handle to add columns to your model or update it in a user interface.
"""
struct StaticModel{P} <: AbstractModel
    parent::P
    function StaticModel(parent)
        # Need at least 1 AbstractParam field to be a Model
        if hasparam(parent)
            expandedpars = _expandkeys(params(parent))
            parent = Flatten.reconstruct(parent, expandedpars, SELECT, IGNORE)
        else
            _noparamwarning()
        end
        # Make sure all params have all the same keys.
        new{typeof(parent)}(parent)
    end
end
StaticModel(m::AbstractModel) = StaticModel(parent(m))

Base.getproperty(m::StaticModel, key::Symbol) = getindex(m, key::Symbol)
Base.setproperty!(m::StaticModel, key::Symbol, x) = setindex!(m, x, key::Symbol)

# Model Utils

_expandpars(x) = Flatten.reconstruct(parent, _expandkeys(parent), SELECT, IGNORE)
# Expand all Params to have the same keys, filling with `nothing`
# This probably will allocate due to `union` returning `Vector`
function _expandkeys(x)
    pars = params(x)
    allkeys = Tuple(union(map(keys, pars)...))
    newpars = map(pars) do par
        vals = map(allkeys) do key
            get(par, key, nothing)
        end
        Param(NamedTuple{allkeys}(vals))
    end
end

_noparamwarning() = @warn "Model has no Param fields"
