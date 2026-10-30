const treeformat = "JuliaForever.SessionTree/1"

struct TreeNode
    parent::Int
    batch::Vector{Any}
end

mutable struct Tree{S <: Store} <: Store
    store::S
    lock::ReentrantLock
    nodes::Vector{TreeNode}
    leaf::Int
    physical::Int
end

Tree(store::Store) = tree(store, snapshot(store))
tree(store, rejected::Rejected) = rejected

tree(store, snapshot::Snapshot) = tree(store, snapshot, foldl(addnode!, snapshot.batches; init=TreeNode[]))
tree(store, snapshot::Snapshot, rejected::Rejected) = rejected
tree(store, snapshot::Snapshot, nodes::Vector{TreeNode}) = Tree(store, ReentrantLock(), nodes, length(nodes), snapshot.revision)

function treenode(batch::Vector, parent)
    isempty(batch) && return Rejected(:invalid_record)
    length(batch) == 1 || return TreeNode(parent, batch)
    treenode(only(batch), batch, parent)
end
treenode(record, batch, parent) = TreeNode(parent, batch)

function treenode(record::Dict, batch, parent)
    get(record, "format", "") == treeformat || return TreeNode(parent, batch)
    treenode(get(record, "parent", nothing), get(record, "batch", nothing))
end

treenode(parent, batch) = Rejected(:invalid_record)
treenode(parent::Int, batch::Vector) = TreeNode(parent, Any[batch...])
addnode!(rejected::Rejected, batch) = rejected
addnode!(nodes::Vector{TreeNode}, batch::Vector) = addnode!(nodes, treenode(batch, length(nodes)))
addnode!(nodes::Vector{TreeNode}, rejected::Rejected) = rejected

function addnode!(nodes::Vector{TreeNode}, item::TreeNode)
    count = length(nodes)
    (count == 0 ? item.parent == 0 : 1 <= item.parent <= count) || return Rejected(:invalid_record)
    isempty(item.batch) && return Rejected(:invalid_record)
    push!(nodes, deepcopy(item))
    nodes
end

function path(tree::Tree, leaf::Integer)
    batches = Vector{Any}[]
    while leaf > 0
        item = tree.nodes[leaf]
        push!(batches, deepcopy(item.batch))
        leaf = item.parent
    end
    reverse!(batches)
end

function snapshot(tree::Tree)
    lock(tree.lock) do
        snapshot(tree, snapshot(tree.store))
    end
end

snapshot(tree::Tree, rejected::Rejected) = rejected

function snapshot(tree::Tree, physical::Snapshot)
    physical.revision == tree.physical || return Rejected(:revision)
    batches = path(tree, tree.leaf)
    Snapshot(tree.leaf, batches)
end

consistent(tree::Tree, snapshot::Snapshot) = lock(() -> snapshot.revision == tree.leaf, tree.lock)

function entries(tree::Tree)
    lock(tree.lock) do
        entries(tree, snapshot(tree.store))
    end
end

entries(tree::Tree, rejected::Rejected) = rejected

function entries(tree::Tree, physical::Snapshot)
    physical.revision == tree.physical || return Rejected(:revision)
    [(; id, parent=item.parent, batch=deepcopy(item.batch)) for (id, item) in enumerate(tree.nodes)]
end

function append!(tree::Tree, revision::Integer, batch::Vector)
    lock(tree.lock) do
        revision == tree.leaf || return Rejected(:revision)
        isempty(batch) && return Rejected(:empty_batch)
        entry = Dict{String, Any}("format" => treeformat, "parent" => tree.leaf, "batch" => batch)
        append!(tree, revision, batch, append!(tree.store, tree.physical, Any[entry]))
    end
end

append!(tree::Tree, revision, batch, rejected::Rejected) = rejected

function append!(tree::Tree, revision, batch, physical::Integer)
    push!(tree.nodes, TreeNode(tree.leaf, deepcopy(batch)))
    tree.leaf = physical
    tree.physical = physical
    physical
end

treestate(rejected::Rejected, batch) = rejected
treeevent(batch::Vector) = length(batch) == 1 ? decode_event(only(batch)) : Rejected(:invalid_record)
firststate(batch::Vector) = length(batch) == 1 ? decode_initial(only(batch)) : Rejected(:invalid_record)
treestate(state::C.State, batch::Vector) = treestate(state, treeevent(batch))
treestate(state::C.State, rejected::Rejected) = rejected
treestate(state::C.State, event::K.Event) = treestate(K.step(state, event))
treestate(result) = Rejected(:invalid_record)
treestate(result::K.Applied) = result.state

function states(tree::Tree)
    isempty(tree.nodes) && return Union{C.State, Rejected}[]
    values = Union{C.State, Rejected}[firststate(first(tree.nodes).batch)]
    for item in tree.nodes[2:end]
        push!(values, treestate(values[item.parent], item.batch))
    end
    values
end

function branches(tree::Tree)
    lock(tree.lock) do
        branches(tree, snapshot(tree.store))
    end
end

branches(tree::Tree, rejected::Rejected) = rejected

function branches(tree::Tree, physical::Snapshot)
    physical.revision == tree.physical || return Rejected(:revision)
    values = states(tree)
    [(; id, parent=item.parent, batch=deepcopy(item.batch), state=values[id]) for (id, item) in enumerate(tree.nodes)]
end

ready(rejected::Rejected) = rejected

function ready(state::C.State)
    isempty(state.kernel.pending) || return Rejected(:uncertain_effect)
    ready(K.step(state, C.Input(state.revision, "")))
end

ready(result) = Rejected(:incomplete_turn)
ready(::K.Applied) = nothing

function branch!(tree::Tree, leaf::Integer)
    lock(tree.lock) do
        branch!(tree, leaf, snapshot(tree))
    end
end

branch!(tree::Tree, leaf, rejected::Rejected) = rejected

function branch!(tree::Tree, leaf, current::Snapshot)
    1 <= leaf <= length(tree.nodes) || return Rejected(:missing_branch)
    values = states(tree)
    branch!(tree, leaf, ready(values[tree.leaf]), ready(values[leaf]))
end

branch!(tree::Tree, leaf, rejected::Rejected, target) = rejected
branch!(tree::Tree, leaf, ::Nothing, rejected::Rejected) = rejected

function branch!(tree::Tree, leaf, ::Nothing, ::Nothing)
    tree.leaf = leaf
end

closetree(::Memory) = nothing
closetree(::Journal) = nothing
closetree(store::Store) = close(store)

function Base.close(tree::Tree)
    lock(tree.lock) do
        closetree(tree.store)
    end
end
