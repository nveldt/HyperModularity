function CliqueExpansion(H::hypergraph,weighted::Bool=true,binary::Bool=false)
    """
    Weighted clique expansion where a hyperedge e is expanded to a
    weighted clique.

    # Arguments

    If weighted = true:
        Each hyperedge is expanded to a clique where edges
        all have weight 1/(|e|-1). Otherwise weight is 1
    If binary = true:
        All edge weights are erased and the graph is
        unweighted. There's an edge (i,j) if i and j ever share a hyperedge
    """
    n = length(H.D)
    I = Int64[]
    J = Int64[]
    V = Float64[]
    ks = setdiff(keys(H.E),1)
    for k in ks
        for edge in keys(H.E[k])
            weight = H.E[k][edge]
            for i = 1:k-1
                ei = edge[i]
                for j = i+1:k
                    ej = edge[j]
                    push!(I,ei)
                    push!(J,ej)
                    if weighted
                        push!(V, weight / (k - 1))
                    else
                        push!(V, weight)
                    end
                end
            end
        end
    end
    A = SparseArrays.sparse(I,J,V,n,n)
    for i = 1:n
        A[i, i] = 0.0
    end
    SparseArrays.dropzeros!(A)
    A = SparseArrays.sparse(A+A')
    if binary
        I, J, V = SparseArrays.findnz(A)
        A = SparseArrays.sparse(I, J, 1, n, n)
    end
    return A
end

function CliqueExpansionModularity(H::hypergraph,gamma::Float64=1.0;weighted::Bool=true,randflag::Bool=false,binary::Bool=false,clusterpenalty::Float64=0.0,maxits::Int64=10000)
    """
    Perform a clique expansion on the hypergraph H and then run standard
    Louvain algorithm on the resulting graph.

    # Arguments

    gamma:
            the resolution parameter. Setting 1.0 means greedily optimize
            modularity. Setting gamma higher produces more clusters.
    randflag:
            if true, randomize order that Louvain visits nodes
    clusterpenalty:
            nonnegative penalty for the number of clusters. If 0.0,
            there is no penalty for having many clusters. Higher number penalizes
            number of clusters
    maxits:
            maximum number of times Louvain iterates through ever node to
            perform greedy moves

    If weighted = true:
        Each hyperedge is expanded to a clique where edges
        all have weight 1/(|e|-1). Otherwise weight is 1

    If binary = true:
        All edge weights are erased and the graph is
        unweighted. There's an edge (i,j) if i and j ever share a hyperedge
    """
    A = CliqueExpansion(H,weighted,binary)
    return VanillaModularity(A,gamma,randflag,clusterpenalty,maxits)
end

function StarExpansionModularity(H::hypergraph,gamma::Float64=1.0;weighted::Bool=true,randflag::Bool=false,binary::Bool=false,maxits::Int64=100)
    """
    Perform a clique expansion on the hypergraph H and then run vanilla
    modularity on the resulting graph.

    For description of arguments, see CliqueExpansionModularity
    """
    He2n, w = hypergraph2incidence(H)
    m,n = size(He2n)
    A = [SparseArrays.spzeros(n,n) He2n'; He2n SparseArrays.spzeros(m,m) ]
    Za = VanillaModularity(A,gamma,randflag,0.0,maxits)
    return Za[1:n]
end


function VanillaModularity(A::SparseArrays.SparseMatrixCSC{Float64,Int64},gamma::Float64=1.0,randflag::Bool=false,clusterpenalty::Float64=0.0,maxits::Int64=10000)
    """
    Vanilla modularity algorithm, obtained by calling the LambdaLouvain algorithm
    implementation from:

    Parameterized Correlation Clustering in Hypergraphs and Bipartite Graphs
    https://arxiv.org/abs/2002.09460

    Code: https://github.com/nveldt/ParamCC/blob/master/src/Graph_Louvain.jl
    """


    d = vec(sum(A,dims = 2))
    n = length(d)
    vol = sum(d)
    lam = gamma/vol
    Cs = LambdaLouvain(A,d,lam,randflag,maxits,clusterpenalty)

    c = Cs[:,end]
    @assert(length(c) == n)

    return c
end

function computeDyadicResolutionParameter(H, Z; mode = "γ", weighted=true, binary=false, pseudocount = 0.0)
    """
    compute the dyadic resolution parameter associated to a partition using the formula from Newman (2016): https://arxiv.org/abs/1606.02319
    """

    G = CliqueExpansion(H, weighted, binary)
    I, J = SparseArrays.findnz(G)

    n = length(H.D)  # number of nodes
    m = sum(G)/2     # number of edges

    # form degree sequence and edge counts
    D = vec(sum(G, dims=1))

    m_in = pseudocount
    m_out = pseudocount

    for k in 1:length(I)
        if Z[I[k]] == Z[J[k]]
            m_in  += G[I[k], J[k]]/2
        else
            m_out += G[I[k], J[k]]/2
        end
    end

    # compute resolution parameter
    V = [sum(D[findall(Z .== c)]) for c in unique(Z)]
    ωᵢ = 4*m*m_in / (sum(V.^2))
    ωₒ = (2m_out)/(2m - (sum(V.^2)/(2m)))

    if mode == "γ"
        γ = (ωᵢ - ωₒ)/(log(ωᵢ) - log(ωₒ))
        return γ
    else
        return(ωᵢ, ωₒ)
    end
end


function dyadicModularity(H, Z, γ; weighted=false, binary=false)
    """
    Compute the normalized dyadic modularity a given partition in the graph obtained from projecting a hypergraph.
    The resolution parameter and basic properties of the dyadic graph projection can be specified.

    # Arguments

    - H::hypergraph, a hypergraph
    - Z::Vector{Int4}, a label vector
    - γ::Float64, the resolution parameter. Must be strictly positive.
    - weighted::bool, whether to weight the clique obtained by projecting a hypergraph according to a factor of 1/(k-1), where k is the clique size. Choosing to do so preserves the degrees of nodes in the dyadic projection. If false and if binary is false, then each edge within the clique has weight 1.
    - binary::bool, whether to convert the graph to a binary graph in which present edges have weight 1 and absent edges have weight 0. If false and if weighted is false, then the weight of an edge between two nodes in the return value is equal to the number of hyperedges containing both of those nodes.

    # Returns

    - Q::Float64, a normalized modularity score between -1 and 1.

    """
    G = CliqueExpansion(H, weighted, binary)
    d = vec(sum(G, dims=1))

    # non-degree (cut) term
    edge_obj = 0.0
    for (i, j, v) in zip(SparseArrays.findnz(G)...)
        if Z[i] == Z[j]
            edge_obj += v
        end
    end

    # volume terms
    vols = Dict{Int64, Float64}()
    for c in unique(Z)
        vols[c] = 0.0
    end
    for i = 1:length(d)
        vols[Z[i]] += d[i]
    end

    Q = edge_obj
    volG = sum(d)
    vol_term = 0.0
    for c in unique(Z)
        Q -= γ * vols[c]^2 / volG
    end

    return Q / volG
end

function dyadicLogLikelihood(H, Z, ωᵢ, ωₒ; weighted=false, binary=false, constants = false)
    G = CliqueExpansion(H, weighted, binary)
    d = vec(sum(G, dims=1))

    # Eq. (14) from https://arxiv.org/pdf/1606.02319.pdf
    γ = (ωᵢ - ωₒ) / (log(ωᵢ) - log(ωₒ))
    Q = dyadicModularity(H, Z, γ; weighted=weighted)
    m = sum(d) / 2
    B = m * log(ωᵢ / ωₒ)
    C = m * (ωₒ + log(ωₒ))

    if constants
        K = sum(SpecialFunctions.loggamma.(SparseArrays.nonzeros(G).+1)) / 2
        return B * Q + C - K
    end
    return B * Q + C
end

function dyadicLogLikelihoodDirect(H, Z, ωᵢ, ωₒ)
    """
    A naive version of the dyadic log-likelihood calculation, used only for testing the fast one.
    """
    G = CliqueExpansion(H, false, false)
    d = vec(sum(G, dims=1))
    m = sum(d)/2
    L = 0.0
    for (i, j, v) in zip(SparseArrays.findnz(G)...)
        if i < j
            a = G[i,j]
            ω = Z[i] == Z[j] ? ωᵢ : ωₒ
            L += log(poisson_pdf(Int(a), ω*d[i]*d[j]/(2m)))
        end
    end
    return L
end




# Below are functions for just graph louvain, nothing about hypergraphs

function ConstructAdj(C::SparseArrays.SparseMatrixCSC,n::Int64)
    """
    ConstructAdj: Construct Adjacency List
    This takes in a sparse adjacency matrix for a graph, and returns an adjacency
    list. While it seems inefficient to store the matrix in multiple ways, as long
    as there are no terrible memory issues, it is VERY handy to be able to quickly
    get a list of neighbors for each node.

    The function also returns the degree vector d. This is NOT the weighted degree,
        d[i] = total number of neighbors of node i
    """
    rp = C.rowval
    ci = C.colptr
    Neighbs = Vector{Vector{Int64}}()
    d = zeros(Int64,n)
    for i = 1:n
        # chop up the rp vector and put it in Neighbs
        push!(Neighbs,rp[ci[i]:ci[i+1]-1])
        d[i] = ci[i+1]-ci[i]
    end

    # d is the number of neighbors. This is the unweighted degree,
    # but note importantly that if the original graph is weighted this is
    # not the same as the degree vector d we will sometimes use
    return Neighbs, d
end

"""
Evaluates the LambdaCC objective, which is equivalent to modularity in graphs.

https://dl.acm.org/doi/pdf/10.1145/3178876.3186110

A = adjacency matrix for a graph
c = clustering vector
w = weights vector (often taken to be degrees of nodes)
lam = resolution paramter
"""
function LamCCobj(A::SparseArrays.SparseMatrixCSC,c,w,lam)

    w_volA = sum(w) # weighted volume
    obj = (lam*(w_volA)^2-lam*sum(w.^2))/2 # constant with respect to the clustering

    for i = 1:maximum(c)
        S = findall(x->x==i,c)
        AS = A[:,S]
        vol = sum(AS.nzval);
        SAS = AS[S,:]
        edges = sum(SAS.nzval);
        cut = vol-edges
        w_volS = sum(w[S])
        obj += 1/2*(cut - lam*w_volS*(w_volA-w_volS))
    end
    return obj
end



function Many_Louvain(A::SparseArrays.SparseMatrixCSC{Float64,Int64},w::Vector{Float64},lam::Float64,numtimes::Int64,maxits::Int64=10000)
    """
    Run the Louvain algorithm many times, taking the result with the best objective.
    """
    n = size(A,1)
    BestObj = Inf
    cBest = collect(1:n)

    for k = 1:numtimes

        ######
        Cs = LambdaLouvain(A,w,lam,true,maxits)
        ######

        c = Cs[:,end]

        ######
        obj = LamCCobj(A,c,w,lam)
        ######


        if obj < BestObj
            BestObj = obj
            cBest = c
        end
    end

    return cBest, BestObj
end


function LambdaLouvain(A::SparseArrays.SparseMatrixCSC{Float64,Int64},w::Vector{Float64},lam::Float64,randflag::Bool=false,maxits::Int64=10000,clusterpenalty::Float64=0.0)
    """
    The full Louvain algorithm. Lambda is the resolution parameter; think of it as
    lambda = gamma/(vol(G)), where gamma is the more traditional resolution parameter
    associated with the modularity objective.

    w = weights function, w[i] = weight for node i. This is often the degree of node
        i, but doesn't have to be.
    """
    @assert(LinearAlgebra.issymmetric(A))
    n = size(A,1)

    # Step 1: greedy moves until no more improvement
    c, improved = LambdaLouvain_Step(A,w,lam,randflag,maxits,clusterpenalty)

    # Keeps track of the clustering that is found after each call to Step 1.
    if improved
        Cs = c
        c_old = copy(c)
    else
        Cs = c
    end

    # As long as something is still improving each time you call step 1, keep going
    while improved

        # Step 2: Collapse the clustering into supernodes

        Anew, wnew = collapse_clustering(A,w,c_old)

        # Step 1: Go back to greedy local moves, this time on the reduced graph
        cSuper, improved = LambdaLouvain_Step(Anew,wnew,lam,randflag,maxits,clusterpenalty)
        N = length(wnew)    # N = number of supernodes = number clusters from last round

        # Undo the procedure that merged nodes into super nodes, so that you get a clustering vector of length n
        # Do this only if the last call to Step 1 led to at least one greedy move.

        if improved

            # Extract what that new clustering is
            c_new = zeros(Int64,n)

            Clusters = clusters_from_cvec(c_old)

            # For each supernode, place all original node IDs that make it up
            # into a cluster of the supernodes label
            for i = 1:N

                # Get the cluster that supernode i is in
                SuperI_Cluster = cSuper[i]

                # Get individual node ID that are in supernode i.

                SuperI_nodes = Clusters[i]
                c_new[SuperI_nodes] .= SuperI_Cluster
            end
            Cs = [Cs c_new]
            c_old = copy(c_new)
        end
    end

    return Cs
end


function clusters_from_cvec(c::Vector{Int64})
    """
    From a cluster indicator vector, extract a vector of vectors storing clusters
    """
    Clusters = Vector{Vector{Int64}}()
    for v = 1:maximum(c)
        push!(Clusters, Vector{Int64}())
    end
    for i = 1:length(c)
        push!(Clusters[c[i]],i)
    end
    return Clusters
end



function LambdaLouvain_Step(A::SparseArrays.SparseMatrixCSC{Float64,Int64},w::Vector{Float64},lam::Float64,randflag::Bool=false,maxits::Int64=Inf,clusterpenalty::Float64=0.0)
    n = size(A,1)
    """
    Run Step 1 of the Louvain algorithm: iterate through nodes and greedily move
    nodes to adjacent clusters.
    """
    # This permutes the node labels, to add randomization in the Louvain
    # algorithm so that you don't always traverse the nodes in the same order
    if randflag
        p = Random.randperm(n)
        A = A[p,p]
        undop = sortperm(p)
        w = w[p]
    end

    # All nodes start in singleton clusters
    c = collect(1:n)
    @assert(size(w,1) == n)
    improving = true
    its = 0

    # number of clusters
    K = n

    # Neighs[i] lists nodes that share an edge with node i
    # degvec[i] = number of neighbors of node i
    Neighbs, degvec = ConstructAdj(A,n)

    # Store a vector of n clusters
    Clusters = Vector{Vector{Int64}}()
    for v = 1:n
        push!(Clusters, Vector{Int64}())
        push!(Clusters[v],v)    # singleton clusters--one for each node
    end

    # As long as we can keep improving, continue
    while improving && its < maxits
        its += 1
        # println("Iteration $its")
        improving = false
        nextclus = 1

        # visit each node in turn
        for i = 1:n

            # Cluster index for node i
            Ci_ind = c[i]

            # Get the indices of nodes in i's cluster
            Ci = Clusters[Ci_ind]

            clus_size = length(Ci)

            Ni = Neighbs[i]

            ## First few lines here essentially compute the current contribution
            # this node i has on the objective, based on its current cluster placement

            # Weight of negative mistakes currently at i
            neg_inner = w[i]*(sum(w[Ci]) - w[i])

            # Weight of positive mistakes if we remove i from Ci
            pos_inner = sum(A[i,Ci])

            # Increase in mistakes if we remove i from Ci
            total_inner = pos_inner - lam*neg_inner

            BestImprove = 0
            BestC = Ci_ind

            Ai = A[:,i]

            # Get the neighboring clusters of i:
            # there are the only places we would even consider moving node i to
            NC = unique(c[Ni])

            # Now let's see if it's better to move to a nearby cluster, Cj
            for j = 1:length(NC)
                Cj_ind = NC[j]

                # Check how much it would improve to move i to to cluster j
                if Cj_ind == Ci_ind
                    change = 0
                else

                    Cj = Clusters[Cj_ind]

                    # Moving i from Ci to Cj adds negative mistakes
                    neg_outer = w[i]*(sum(w[Cj]))

                    # Moving i from Ci to Cj decreases positive mistakes

                    pos_outer = mysum(Ai,Cj)

                    total_outer = lam*neg_outer - pos_outer

                    # Change in cluster part of objective
                    if clus_size == 1
                        Δclus = clusterpenalty*(log(K-1)-log(K))
                    else
                        Δclus = 0
                    end

                    # This is the overall change in objective if we move i to Cj
                    change = total_outer + total_inner + Δclus

                end

                # Check if this is currently the best possible greedy move to make
                if change < BestImprove
                    BestImprove = change
                    BestC = Cj_ind
                    improving = true
                end
            end
            # Done checking whether there's a better place to greedily move the cluster to.

            # Move i to the best cluster to move it to, do this
            # only if it strictly improves the objective
            if BestImprove < 0
                ci_old = c[i]
                c[i] = BestC

                # Remove i from its old cluster...
                Clusters[ci_old] = setdiff(Clusters[ci_old],i)

                # ...and add it to its new cluster
                push!(Clusters[BestC],i)
                sort!(Clusters[BestC])

                improving = true # we have a reason to keep iterating!
                if clus_size == 1
                    # we moved a singleton to another cluster
                    K -= 1
                end
            end

        end
    end
    if its == 1
        improved = false
    else
        improved = true
        c, Clusters = renumber(c,Clusters)
    end

    if randflag
        c = c[undop]    # if you previously mixed up node order, re-order them now
    end

    return c, improved

end

function mysum(v::SparseArrays.SparseVector{Float64,Int64},inds::Vector{Int64})
    """
    Less numerically stable, but for the purposes of a greedy clustering
    algorithm works as well as it needs to, and is faster.
    """
    s = 0
    for i in inds
        s += v[i]
    end
    return s
end


"""
Step 2 of the Louvain algorithm:
Collapse a clustering into a new network of supernodes and weighted edges, so
that you can then run the same greedy node-moving on supernodes.
"""
function collapse_clustering(A::SparseArrays.SparseMatrixCSC{Float64,Int64},w::Vector{Float64},c::Vector{Int64})

    n = size(A,1)
    Clusters = Vector{Vector{Int64}}()
    ClusterNeighbs = Vector{Set{Int64}}()
    Neighbs, degvec = ConstructAdj(A,n)

    for v = 1:maximum(c)
        push!(Clusters, Vector{Int64}())
        push!(ClusterNeighbs, Set{Int64}())
    end

    for i = 1:n
        push!(Clusters[c[i]],i)
        # Also keep track of which clusters are adjacent clusters
        for j in Neighbs[i]
            if c[j] != c[i]
                push!(ClusterNeighbs[c[i]],c[j])
            end
        end
    end

    # Number of supernodes to form = number of clusters
    N = round(Int64,maximum(c))

    I = Vector{Int64}()
    J = Vector{Int64}()
    V = Vector{Float64}()
    wnew = zeros(N)
    # Construct a new sparse matrix with new node weights
    for i = 1:N
        Ci = sort(Clusters[i])
        wnew[i] = sum(w[Ci])
        ACi = A[:,Ci]
        for j in ClusterNeighbs[i]
            Cj = Clusters[j]
            Eij = sum(ACi[Cj,:])
            push!(I,i)
            push!(J,j)
            push!(V,Eij)
        end
    end

    Anew = SparseArrays.sparse(I,J,V,N,N)

    return Anew, wnew
end


# Sort sizes: Return a set of cluster sizes, arranged in order
function ClusterSizes(c)
    c = renumber(c)

    sizes = Vector{Int64}()
    for i = 1:maximum(c)
        inds = findall(x->x==i,c)
        push!(sizes,length(inds))
    end

    return sort(sizes,rev=true)
end
