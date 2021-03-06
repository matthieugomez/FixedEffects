##############################################################################
##
## FixedEffect
##
## The categoricalarray may have pools that are never referred. Note that the pool does not appear in FixedEffect anyway.
##
##############################################################################

struct FixedEffect{R <: AbstractVector{<:Integer}, I <: AbstractVector{<:Real}}
	refs::R                 # refs must be between 0 and n
	interaction::I          # the continuous interaction
	n::Int                  # Number of potential values (= maximum(refs))
	function FixedEffect{R, I}(refs, interaction, n) where {R <: AbstractVector{<:Integer}, I <: AbstractVector{<: Real}}
		length(refs) == length(interaction) || throw(DimensionMismatch(
			"cannot match refs of length $(length(refs)) with interaction of length $(length(interaction))"))
		return new(refs, interaction, n)
	end
end

function FixedEffect(args...; interaction::AbstractVector = uweights(length(args[1])))
	g = group(args...)
	FixedEffect{typeof(g.refs), typeof(interaction)}(g.refs, interaction, g.n)
end

Base.show(io::IO, ::FixedEffect) = print(io, "Fixed Effects")

function Base.show(io::IO, ::MIME"text/plain", fe::FixedEffect)
	print(io, fe, ':')
	print(io, "\n  refs (", length(fe.refs), "-element ", typeof(fe.refs), "):")
	print(io, "\n    [", string.(Int.(fe.refs[1:min(5, length(fe.refs))])).*", "..., "... ]")
	if fe.interaction isa UnitWeights
		print(io, "\n  interaction (UnitWeights):")
		print(io, "\n    none")
	else
		print(io, "\n  interaction (", length(fe.interaction), "-element ", typeof(fe.interaction), "):")
		print(io, "\n    [", (sprint(show, x; context=:compact=>true)*", " for x in fe.interaction[1:min(5, length(fe.interaction))])..., "... ]")
	end
end

Base.size(fe::FixedEffect) = size(fe.refs)
Base.length(fe::FixedEffect) = length(fe.refs)
Base.eltype(::FixedEffect{R,I}) where {R,I} = eltype(I)

Base.getindex(fe::FixedEffect, ::Colon) = fe

@propagate_inbounds function Base.getindex(fe::FixedEffect, esample)
	@boundscheck checkbounds(fe.refs, esample)
	@boundscheck checkbounds(fe.interaction, esample)
	@inbounds refs = fe.refs[esample]
	@inbounds interaction = fe.interaction[esample]
	return FixedEffect{typeof(fe.refs), typeof(fe.interaction)}(refs, interaction, fe.n)
end

##############################################################################
##
## group combines multiple refs
## Missings have a ref of 0
## 
##############################################################################

mutable struct GroupedArray{N} <: AbstractArray{UInt32, N}
	refs::Array{UInt32, N}   # refs must be between 0 and n. 0 means missing
	n::Int                   # Number of potential values (= maximum(refs))
end
Base.size(g::GroupedArray) = size(g.refs)
@propagate_inbounds Base.getindex(g::GroupedArray, i::Number) = getindex(g.refs, i::Number)
@propagate_inbounds Base.getindex(g::GroupedArray, I...) = getindex(g.refs, I...)
Base.firstindex(g::GroupedArray) = firstindex(g.refs)
Base.lastindex(g::GroupedArray) = lastindex(g.refs)

group(xs::GroupedArray) = xs

function group(xs::AbstractArray)
	_group(DataAPI.refarray(xs), DataAPI.refpool(xs))
end


function _group(xs, ::Nothing)
	refs = Array{UInt32}(undef, size(xs))
	invpool = Dict{eltype(xs), UInt32}()
	n = UInt32(0)
	i = UInt32(0)
	@inbounds for x in xs
		i += 1
		if x === missing
			refs[i] = 0
		else
			lbl = get(invpool, x, UInt32(0))
			if !iszero(lbl)
				refs[i] = lbl
			else
				n += 1
				refs[i] = n
				invpool[x] = n
			end
		end
	end
	return GroupedArray{ndims(xs)}(refs, n)
end

function _group(ra, rp)
	refs = Array{UInt32}(undef, size(ra))
	hashes = Array{UInt32}(undef, length(rp))
	firp = firstindex(rp)
	n = 0
	for i in eachindex(hashes)
		if rp[i+firp-1] === missing
			hashes[i] = UInt32(0)
		else
			n += 1
			hashes[i] = n
		end
	end
	fira = firstindex(ra)
	@inbounds for i in eachindex(refs)
		refs[i] = hashes[ra[i+fira-1]-firp+1]
	end
	return GroupedArray{ndims(refs)}(refs, n)
end

function group(args...)
	g1 = deepcopy(group(args[1]))
	for j = 2:length(args)
		gj = group(args[j])
		size(g1) == size(gj) || throw(DimensionMismatch(
            "cannot match array of size $(size(g1)) with array of size $(size(gj))"))
		combine!(g1, gj)
	end
	factorize!(g1)
end

function combine!(g1::GroupedArray, g2::GroupedArray)
	@inbounds for i in eachindex(g1.refs, g2.refs)
		# if previous one is missing or this one is missing, set to missing
		g1.refs[i] = (g1.refs[i] == 0 || g2.refs[i] == 0) ? 0 : g1.refs[i] + (g2.refs[i] - 1) * g1.n
	end
	g1.n = g1.n * g2.n
	return g1
end

# An in-place version of group() that relabels the refs
function factorize!(g::GroupedArray{N}) where {N}
    refs = g.refs
    invpool = Dict{UInt32, UInt32}()
    n = 0
	z = UInt32(0)
    @inbounds for i in eachindex(refs)
        x = refs[i]
        if !iszero(x)
            lbl = get(invpool, x, z)
            if !iszero(lbl)
                refs[i] = lbl
            else
                n += 1
                refs[i] = n
                invpool[x] = n
            end
        end
    end
    return GroupedArray{N}(refs, n)
end

##############################################################################
##
## Find connected components
## 
##############################################################################
# Return a vector of sets that contains the indices of each unique value
function refsrev(fe::FixedEffect)
	out = Vector{Int}[Int[] for _ in 1:fe.n]
	for i in eachindex(fe.refs)
		push!(out[fe.refs[i]], i)
	end
	return out
end

# Returns a vector of all components
# A component is a vector that, for each fixed effect, 
# contains all the refs that are included in the component.
function components(fes::AbstractVector{<:FixedEffect})
	refs_vec = Vector{UInt32}[fe.refs for fe in fes]
	refsrev_vec = Vector{Vector{Int}}[refsrev(fe) for fe in fes]
	visited = falses(length(refs_vec[1]))
	out = Vector{Set{Int}}[]
	for i in eachindex(visited)
		if !visited[i]
			# obs not visited yet, so create new component
			component_vec = Set{UInt32}[Set{UInt32}() for _ in 1:length(refsrev_vec)]
			# visit all obs in the same components
			tovisit = Set{Int}(i)
			while !isempty(tovisit)
				for (component, refs, refsrev) in zip(component_vec, refs_vec, refsrev_vec)
					ref = refs[i]
					# if group is not in component yet
					if ref ∉ component
						# add group to the component
						push!(component, ref)
						# visit other observations in same group
						union!(tovisit, refsrev[ref])
					end
				end
				# mark obs as visited
				i = pop!(tovisit)
				visited[i] = true
			end            
			push!(out, component_vec)
		end
	end
	return out
end

##############################################################################
##
## normalize! a vector of fixedeffect coefficients using connected components
## 
##############################################################################

function normalize!(fecoefs::AbstractVector{<: Vector{<: Real}}, fes::AbstractVector{<:FixedEffect}; kwargs...)
	# The solution is generally not unique. Find connected components and scale accordingly
	idx = findall(fe -> isa(fe.interaction, UnitWeights), fes)
	length(idx) >= 2 && rescale!(view(fecoefs, idx), view(fes, idx))
	return fecoefs
end

function rescale!(fecoefs::AbstractVector{<: Vector{<: Real}}, fes::AbstractVector{<:FixedEffect})
	for component_vec in components(fes)
		m = 0.0
		# demean all fixed effects except the first
		for j in length(fecoefs):(-1):2
			fecoef, component = fecoefs[j], component_vec[j]
			mj = 0.0
			for k in component
				mj += fecoef[k]
			end
			mj = mj / length(component)
			for k in component
				fecoef[k] -= mj
			end
			m += mj
		end
		# rescale the first fixed effects
		fecoef, component = fecoefs[1], component_vec[1]
		for k in component
			fecoef[k] += m
		end
	end
end

function full(fecoefs::AbstractVector{<: Vector{<: Real}}, fes::AbstractVector{<:FixedEffect})
	[fecoef[fe.refs] for (fecoef, fe) in zip(fecoefs, fes)]
end
