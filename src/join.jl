export naturaljoin, innerjoin, leftjoin, asofjoin, leftjoin!

## Joins

# Natural Join (Both NDSParse arrays must have the same number of columns, in the same order)

function naturaljoin(left::NDSparse, right::NDSparse, op)
    lD, rD = left.data, right.data
    _naturaljoin(left, right, op, similar(lD, typeof(op(lD[1],rD[1])), 0))
end

const innerjoin = naturaljoin

combine_op(a, b) = tuple
combine_op(a::Columns, b::Columns) = (l, r)->(l..., r...)
combine_op(a, b::Columns) = (l, r)->(l, r...)
combine_op(a::Columns, b) = (l, r)->(l..., r)
similarz(a) = similar(a,0)

function naturaljoin(left::NDSparse, right::NDSparse)
    lD, rD = left.data, right.data
    op = combine_op(lD, rD)
    cols(v) = (v,)
    cols(v::Columns) = v.columns
    _naturaljoin(left, right, op, Columns((map(similarz,cols(lD))...,map(similarz,cols(rD))...)))
end

function _naturaljoin(left::NDSparse, right::NDSparse, op, data)
    flush!(left); flush!(right)
    lI, rI = left.index, right.index
    lD, rD = left.data, right.data
    ll, rr = length(lI), length(rI)

    # Guess the length of the result
    guess = min(ll, rr)

    # Initialize output array components
    I = _sizehint!(similar(lI,0), guess)
    _sizehint!(data, guess)

    # Match and insert rows
    i = j = 1

    while i <= ll && j <= rr
        c = rowcmp(lI, i, rI, j)
        if c == 0
            push!(I, lI[i])
            push!(data, op(lD[i], rD[j]))
            i += 1
            j += 1
        elseif c < 0
            i += 1
        else
            j += 1
        end
    end

    # Generate final datastructure
    NDSparse(I, data, presorted=true)
end

map{T,S,D}(f, x::NDSparse{T,D}, y::NDSparse{S,D}) = naturaljoin(x, y, f)

# left join

function leftjoin(left::NDSparse, right::NDSparse, op = IndexedTables.right)
    flush!(left); flush!(right)
    lI, rI = left.index, right.index
    lD, rD = left.data, right.data
    ll, rr = length(lI), length(rI)

    data = similar(lD)

    i = j = 1

    while i <= ll && j <= rr
        c = rowcmp(lI, i, rI, j)
        if c < 0
            @inbounds data[i] = lD[i]
            i += 1
        elseif c == 0
            @inbounds data[i] = op(lD[i], rD[j])
            i += 1
            j += 1
        else
            j += 1
        end
    end
    data[i:ll] = lD[i:ll]

    NDSparse(copy(lI), data, presorted=true)
end

function leftjoin!(left::NDSparse, right::NDSparse, op = IndexedTables.right)
    flush!(left); flush!(right)
    lI, rI = left.index, right.index
    lD, rD = left.data, right.data
    ll, rr = length(lI), length(rI)

    i = j = 1

    while i <= ll && j <= rr
        c = rowcmp(lI, i, rI, j)
        if c < 0
            i += 1
        elseif c == 0
            @inbounds lD[i] = op(lD[i], rD[j])
            i += 1
            j += 1
        else
            j += 1
        end
    end
    left
end

# asof join

function asofjoin(left::NDSparse, right::NDSparse)
    flush!(left); flush!(right)
    lI, rI = left.index, right.index
    lD, rD = left.data, right.data
    ll, rr = length(lI), length(rI)

    data = similar(lD)

    i = j = 1

    while i <= ll && j <= rr
        c = rowcmp(lI, i, rI, j)
        if c < 0
            @inbounds data[i] = lD[i]
            i += 1
        elseif row_asof(lI, i, rI, j)  # all equal except last col left>=right
            j += 1
            while j <= rr && row_asof(lI, i, rI, j)
                j += 1
            end
            j -= 1
            @inbounds data[i] = rD[j]
            i += 1
        else
            j += 1
        end
    end
    data[i:ll] = lD[i:ll]

    NDSparse(copy(lI), data, presorted=true)
end

# merge - union join

function count_overlap{D}(I::Columns{D}, J::Columns{D})
    lI, lJ = length(I), length(J)
    i = j = 1
    overlap = 0
    while i <= lI && j <= lJ
        c = rowcmp(I, i, J, j)
        if c == 0
            overlap += 1
            i += 1
            j += 1
        elseif c < 0
            i += 1
        else
            j += 1
        end
    end
    return overlap
end

# assign y into x out-of-place
merge{T,S,D<:Tuple}(x::NDSparse{T,D}, y::NDSparse{S,D}) = (flush!(x);flush!(y); _merge(x, y))
# merge without flush!
function _merge{T,S,D}(x::NDSparse{T,D}, y::NDSparse{S,D})
    I, J = x.index, y.index
    lI, lJ = length(I), length(J)
    #if isless(I[end], J[1])
    #    return NDSparse(vcat(x.index, y.index), vcat(x.data, y.data), presorted=true)
    #elseif isless(J[end], I[1])
    #    return NDSparse(vcat(y.index, x.index), vcat(y.data, x.data), presorted=true)
    #end
    n = lI + lJ - count_overlap(I, J)
    K = similar(I, n)::typeof(I)
    data = similar(x.data, n)
    i = j = 1
    @inbounds for k = 1:n
        if i <= lI && j <= lJ
            c = rowcmp(I, i, J, j)
            if c >= 0
                K[k] = J[j]
                data[k] = y.data[j]
                if c==0; i += 1; end
                j += 1
            else
                K[k] = I[i]
                data[k] = x.data[i]
                i += 1
            end
        elseif i <= lI
            # TODO: copy remaining data columnwise
            K[k] = I[i]
            data[k] = x.data[i]
            i += 1
        elseif j <= lJ
            K[k] = J[j]
            data[k] = y.data[j]
            j += 1
        else
            break
        end
    end
    NDSparse(K, data, presorted=true)
end

function merge(x::NDSparse, xs::NDSparse...)
    as = [x, xs...]
    filter!(a->length(a)>0, as)
    length(as) == 0 && return x
    length(as) == 1 && return a[1]
    for a in as; flush!(a); end
    sort!(as, by=y->first(y.index))
    if all(i->isless(as[i-1].index[end], as[i].index[1]), 2:length(as))
        # non-overlapping
        return NDSparse(vcat(map(a->a.index, as)...),
                        vcat(map(a->a.data,  as)...),
                        presorted=true)
    end
    error("this case of `merge` is not yet implemented")
end

# merge in place
merge!{T,S,D<:Tuple}(x::NDSparse{T,D}, y::NDSparse{S,D}) = (flush!(x);flush!(y); _merge!(x, y))
# merge! without flush!
function _merge!(dst::NDSparse, src::NDSparse)
    if isless(dst.index[end], src.index[1])
        append!(dst.index, src.index)
        append!(dst.data, src.data)
    else
        # merge to a new copy
        new = _merge(dst, src)
        ln = length(new)
        # resize and copy data into dst
        resize!(dst.index, ln)
        copy!(dst.index, new.index)
        resize!(dst.data, ln)
        copy!(dst.data, new.data)
    end
    return dst
end

# broadcast join - repeat data along a dimension missing from one array

function find_corresponding(Ap, Bp)
    matches = zeros(Int, length(Ap))
    J = IntSet(1:length(Bp))
    for i = 1:length(Ap)
        for j in J
            if Ap[i] == Bp[j]
                matches[i] = j
                delete!(J, j)
                break
            end
        end
    end
    isempty(J) || error("unmatched source indices: $(collect(J))")
    tuple(matches...)
end

function match_indices(A::NDSparse, B::NDSparse)
    if isa(A.index.columns, NamedTuple) && isa(B.index.columns, NamedTuple)
        Ap = fieldnames(A.index.columns)
        Bp = fieldnames(B.index.columns)
    else
        Ap = typeof(A).parameters[2].parameters
        Bp = typeof(B).parameters[2].parameters
    end
    find_corresponding(Ap, Bp)
end

# broadcast over trailing dimensions, i.e. C's dimensions are a prefix
# of B's. this is an easy case since it's just an inner join plus
# sometimes repeating values from the right argument.
function _broadcast_trailing!(f, A::NDSparse, B::NDSparse, C::NDSparse)
    I = A.index
    data = A.data
    lI, rI = B.index, C.index
    lD, rD = B.data, C.data
    ll, rr = length(lI), length(rI)

    i = j = 1

    while i <= ll && j <= rr
        c = rowcmp(lI, i, rI, j)
        if c == 0
            while true
                push!(I, lI[i])
                push!(data, f(lD[i], rD[j]))
                i += 1
                (i <= ll && rowcmp(lI, i, rI, j)==0) || break
            end
            j += 1
        elseif c < 0
            i += 1
        else
            j += 1
        end
    end

    return A
end

function _bcast_loop!(f::Function, A::NDSparse, B::NDSparse, C::NDSparse, B_common, B_perm)
    m, n = length(B_perm), length(C)
    jlo = klo = 1
    iperm = zeros(Int, m)
    cnt = 0
    @inbounds while jlo <= m && klo <= n
        pjlo = B_perm[jlo]
        x = rowcmp(B_common, pjlo, C.index, klo)
        x < 0 && (jlo += 1; continue)
        x > 0 && (klo += 1; continue)
        jhi = jlo + 1
        while jhi <= m && roweq(B_common, B_perm[jhi], pjlo)
            jhi += 1
        end
        Ck = C.data[klo]
        for ji = jlo:jhi-1
            j = B_perm[ji]
            # the output has the same indices as B, except with some missing.
            # invperm(B_perm) would put the indices we're using back into their
            # original sort order, so we build up that inverse permutation in
            # `iperm`, leaving some 0 gaps to be filtered out later.
            cnt += 1
            iperm[j] = cnt
            push!(A.index, B.index[j])
            push!(A.data, f(B.data[j], Ck))
        end
        jlo, klo = jhi, klo+1
    end
    filter!(i->i!=0, iperm)
end

# broadcast C over B, into A. assumes A and B have same dimensions and ndims(B) >= ndims(C)
function _broadcast!(f::Function, A::NDSparse, B::NDSparse, C::NDSparse; dimmap=nothing)
    flush!(A); flush!(B); flush!(C)
    empty!(A)
    if dimmap === nothing
        C_inds = match_indices(A, C)
    else
        C_inds = dimmap
    end
    C_dims = ntuple(identity, ndims(C))
    if C_inds[1:ndims(C)] == C_dims
        return _broadcast_trailing!(f, A, B, C)
    end
    common = filter(i->C_inds[i] > 0, 1:ndims(A))
    C_common = C_inds[common]
    B_common_cols = Columns(B.index.columns[common])
    B_perm = sortperm(B_common_cols)
    if C_common == C_dims
        iperm = _bcast_loop!(f, A, B, C, B_common_cols, B_perm)
        if !issorted(A.index)
            permute!(A.index, iperm)
            copy!(A.data, A.data[iperm])
        end
    else
        # TODO
        #C_perm = sortperm(Columns(C.index.columns[[C_common...]]))
        error("dimensions of one argument to `broadcast` must be a subset of the dimensions of the other")
    end
    return A
end

"""
`broadcast(f::Function, A::NDSparse, B::NDSparse; dimmap::Tuple{Vararg{Int}})`

Compute an inner join of `A` and `B` using function `f`, where the dimensions
of `B` are a subset of the dimensions of `A`. Values from `B` are repeated over
the extra dimensions.

`dimmap` optionally specifies how dimensions of `A` correspond to dimensions
of `B`. It is a tuple where `dimmap[i]==j` means the `i`th dimension of `A`
matches the `j`th dimension of `B`. Extra dimensions that do not match any
dimensions of `j` should have `dimmap[i]==0`.

If `dimmap` is not specified, it is determined automatically using index column
names and types.
"""
function broadcast(f::Function, A::NDSparse, B::NDSparse; dimmap=nothing)
    if ndims(B) > ndims(A)
        _broadcast!((x,y)->f(y,x), similar(B), B, A, dimmap=dimmap)
    else
        _broadcast!(f, similar(A), A, B, dimmap=dimmap)
    end
end

broadcast(f::Function, x::NDSparse, y) = NDSparse(x.index, broadcast(f, x.data, y), presorted=true)
broadcast(f::Function, y, x::NDSparse) = NDSparse(x.index, broadcast(f, y, x.data), presorted=true)
