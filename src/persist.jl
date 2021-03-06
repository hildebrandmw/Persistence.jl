module Persist

# TODO: Implement Arrays
# TODO: Handle Circular References
# TODO: Cleanup loading and storing code
#   - Review existing constructs - there may be a simpler implementation
#   - Make generic persisting and storing type stable, either through code tricks or by
#       using @generated.
#
# TODO: write tests!

export Persistent, persist, retrieve

import Base: getproperty, setproperty!, size, getindex, setindex!, IndexStyle, sizeof

using ..Lib
using ..Transaction

abstract type AbstractClass end

struct Fallback <: AbstractClass end
struct IsBits <: AbstractClass end

class(::Type{T}) where {T} = isbitstype(T) ? IsBits() : Fallback()
class(x::T) where {T} = class(T)

"""
Persistent wrapper for (mostly) arbitrary types. The layout of a `Persistent{T}` is similar
similar to the layout of standard Julia object with the following modifications

* If a field element is `isbits`, the element is stored inline
* If a field element is not `isbits`, then we store a `PersistentOID` to that object. This
    means that fields offsets below the non `isbits` object may have to be shifted down to
    accomodate the 16 bytes required for a `PersistentOID`.
"""
struct Persistent{T}
    __oid::PersistentOID{T}
end
getoid(P::Persistent) = getfield(P, :__oid)
getpool(P::Persistent) = Lib.pool(getoid(P))


#####
##### persist
#####

persist(pool, x::T) where {T} = transaction(() -> store(pool, x), pool)

#####
##### Store
#####

# Special behavior for strings and arrays
store(pool, x::String) = Persistent(Lib.tx_strdup(x, String))
store(pool, x::Symbol) = Persistent(Lib.tx_strdup(String(x), Symbol))

# arrays
store(pool, x::Array{T,N}) where {T,N} = _store(pool, x, Val{isbitstype(T)}())

# Fallback - check if isbits
store(pool, x::T) where {T} = store(pool, x::T, class(T))
function store(pool, x::T, ::IsBits) where {T}
    oid = Lib.tx_alloc(sizeof(x), T)
    ptr = Lib.direct(oid)
    unsafe_store!(ptr, x)

    return Persistent(oid)
end

function store(pool, x::T, ::Fallback) where {T}
    # Create OIDs for every field of `x`
    oid = Lib.tx_alloc(nfields(x) * sizeof(Persistent{T}), T)
    ptr = Lib.direct(oid)

    # Store all members of `x`
    for (index, field) in enumerate(fieldnames(T))
        object = store(pool, getfield(x, field))
        thisptr = convert(Ptr{typeof(object)}, ptr) + (index - 1) * sizeof(Persistent{T})
        unsafe_store!(thisptr, object)
    end
    return Persistent{T}(oid)
end

#####
##### retrieve
#####

retrieve(x::Persistent) = retrieve(Lib.direct(getoid(x)))

# Specializtions
retrieve(ptr::Ptr{String}) = unsafe_string(convert(Ptr{UInt8}, ptr))
retrieve(ptr::Ptr{Symbol}) = Symbol(unsafe_string(convert(Ptr{UInt8}, ptr)))

# Fallback
retrieve(ptr::Ptr{T}) where {T} = retrieve(ptr, class(T))
retrieve(ptr::Ptr{T}, ::IsBits) where {T} = unsafe_load(ptr)

function retrieve(ptr::Ptr{T}, ::Fallback) where {T}
    fields = []
    for (index, field) in enumerate(fieldnames(T))
        # Need to make an OID from the 16 bytes here to get the actual object.
        ptr_offset = ptr + (index - 1) * sizeof(Persistent{T})
        handle = unsafe_load(convert(Ptr{Persistent{fieldtype(T, field)}}, ptr_offset))

        push!(fields, retrieve(handle))
    end
    return T(fields...)
end

#####
##### destroy
#####

destroy(x::Persistent) = destroy(getoid(x))

# Specializations
destroy(oid::PersistentOID{String}) = Lib.free(oid)
destroy(oid::PersistentOID{Symbol}) = Lib.free(oid)

# Fallback
destroy(oid::PersistentOID{T}) where {T} = destroy(oid, class(T))
destroy(oid::PersistentOID{T}, ::IsBits) where {T} = Lib.free(oid)

end
