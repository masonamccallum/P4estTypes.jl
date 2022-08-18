
const Locidx = P4est.p4est_locidx_t
const Gloidx = P4est.p4est_gloidx_t

struct Quadrant{X,T,P}
    pointer::P
end

level(quadrant::Quadrant) = quadrant.pointer.level
storeuserdata!(quadrant::Quadrant{X,T}, data::T) where {X,T} =
    unsafe_store!(Ptr{T}(quadrant.pointer.p.user_data), data)
loaduserdata(quadrant::Quadrant{X,T}) where {X,T} =
    unsafe_load(Ptr{T}(quadrant.pointer.p.user_data))

struct Tree{X,P}
    pointer::P
end

offset(tree::Tree) = tree.pointer.quadrants_offset

mutable struct Pxest{X,T,P,C} <: AbstractArray{Quadrant,1}
    pointer::P
    connectivity::C
    comm::MPI.Comm
    function Pxest{4}(
        pointer::Ptr{P4est.LibP4est.p4est},
        connectivity::Connectivity{4},
        comm::MPI.Comm,
        ::Type{T},
    ) where {T}
        forest = new{4,T,typeof(pointer),typeof(connectivity)}(pointer, connectivity, comm)
        finalizer(forest) do p
            p4est_destroy(p.pointer)
            p.pointer = C_NULL
            return
        end
    end
    function Pxest{8}(
        pointer::Ptr{P4est.LibP4est.p8est},
        connectivity::Connectivity{8},
        comm::MPI.Comm,
        ::Type{T},
    ) where {T}
        forest = new{8,T,typeof(pointer),typeof(connectivity)}(pointer, connectivity, comm)
        finalizer(forest) do p
            p8est_destroy(p.pointer)
            p.pointer = C_NULL
            return
        end
    end
end

function pxest(
    connectivity::Connectivity{4};
    comm = MPI.COMM_WORLD,
    min_quadrants = 0,
    min_level = 0,
    fill_uniform = true,
    data_type = Nothing,
    init_function = C_NULL,
    user_pointer = C_NULL,
)
    MPI.Initialized() || MPI.Init()

    pointer = p4est_new_ext(
        comm,
        connectivity,
        min_quadrants,
        min_level,
        fill_uniform,
        sizeof(data_type),
        init_function,
        user_pointer,
    )
    return Pxest{4}(pointer, connectivity, comm, data_type)
end

function pxest(
    connectivity::Connectivity{8};
    comm = MPI.COMM_WORLD,
    min_quadrants = 0,
    min_level = 0,
    fill_uniform = true,
    data_type = Nothing,
    init_function = C_NULL,
    user_pointer = C_NULL,
)
    MPI.Initialized() || MPI.Init()

    pointer = p8est_new_ext(
        comm,
        connectivity,
        min_quadrants,
        min_level,
        fill_uniform,
        sizeof(data_type),
        init_function,
        user_pointer,
    )
    return Pxest{8}(pointer, connectivity, comm, data_type)
end

typeofquadrantuserdata(::Pxest{X,T}) where {X,T} = T

function Base.unsafe_convert(::Type{Ptr{p4est}}, p::Pxest{4,T,Ptr{p4est}}) where {T}
    return p.pointer
end
function Base.unsafe_convert(::Type{Ptr{p8est}}, p::Pxest{8,T,Ptr{p8est}}) where {T}
    return p.pointer
end

global_size(p::Pxest{X}) where {X} = (p.pointer.global_num_quadrants,)
local_size(p::Pxest{X}) where {X} = (p.pointer.local_num_quadrants,)
Base.size(p::Pxest{X}) where {X} = local_size(p)
function global_axes(p::Pxest{X}) where {X}
    rank = MPI.Comm_rank(p.comm)

    GC.@preserve p begin
        global_first_position = unsafe_load(p.pointer.global_first_quadrant, rank + 1) + 1
        global_last_position = unsafe_load(p.pointer.global_first_quadrant, rank + 2)
    end

    return global_first_position:global_last_position
end

function Base.getindex(p::Pxest{X,T}, i::Int) where {X,T}
    GC.@preserve p begin
        for t = (p.pointer.first_local_tree+1):(p.pointer.last_local_tree+1)
            @assert t ≤ p.pointer.trees.elem_count
            tree = unsafe_load(Ptr{p4est_tree}(p.pointer.trees.array), t)
            numquadrants = tree.quadrants.elem_count
            if i <= numquadrants
                Q = X == 4 ? p4est_quadrant : p8est_quadrant
                q = unsafe_load(Ptr{Q}(tree.quadrants.array), i)
                return (t - 1, Quadrant{X,T,Q}(q))
            else
                i -= numquadrants
            end
        end
    end
end

Base.IndexStyle(::Pxest{X}) where {X} = IndexLinear()

mutable struct IterateData{P,G,U}
    forest::P
    ghost_layer::G
    user_data::U
end

function _p4est_volume_callback_generate(volume_callback)
    Ccallback, _ =
        Cfunction{Cvoid,Tuple{Ptr{p4est_iter_volume_info_t},Ptr{Cvoid}}}() do info,
        user_data
            data = unsafe_pointer_to_objref(user_data)
            T = typeofquadrantuserdata(data[].forest)
            quadrant = Quadrant{4,T,Ptr{p4est_quadrant}}(info.quad)
            tree_ptr = Ptr{p4est_tree}(data[].forest.pointer.trees.array) + info.treeid
            tree = Tree{4,Ptr{p4est_tree}}(tree_ptr)
            volume_callback(
                data[].forest,
                data[].ghost_layer,
                data[].user_data,
                quadrant,
                tree,
                info.quadid,
                info.treeid,
            )
            return
        end

    return Ccallback
end

function iterateforest(
    forest::Pxest{4};
    user_data = nothing,
    ghost_layer = nothing,
    volume_callback = nothing,
    face_callback = nothing,
    corner_callback = nothing,
)

    data = Ref(IterateData(forest, ghost_layer, user_data))
    _volume_callback =
        isnothing(volume_callback) ? C_NULL :
        _p4est_volume_callback_generate(volume_callback)
    @assert face_callback === nothing
    @assert corner_callback === nothing

    GC.@preserve data begin
        p4est_iterate(
            forest,
            C_NULL,
            pointer_from_objref(data),
            _volume_callback,
            C_NULL,
            C_NULL,
        )
    end

    return nothing
end
