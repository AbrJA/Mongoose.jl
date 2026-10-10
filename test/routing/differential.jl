# Differential dispatch: the generic `Router`, the freeze!-compiled table, and
# the compile-time `StaticRouter` implement the same matching semantics, so for
# any route table + request the observable outcome (status, body, Allow) must
# be identical. Random tables make this an invariant test, not an example test.
#
# Deterministic LCG: reproducible matrix without adding a `Random` test dep
# (test/Project.toml stays untouched).

mutable struct _DiffRNG
    s::UInt64
end
_diffu(r::_DiffRNG) = (r.s = r.s * 0x5851F42D4C957F2D + 0x14057B7EF767814F; r.s)
_diffint(r::_DiffRNG, n::Int) = Int((_diffu(r) >>> 33) % UInt64(n)) + 1
_diffpick(r::_DiffRNG, xs) = xs[_diffint(r, length(xs))]

# One functor type for every generated handler (keeps compile small).
struct _DiffHandler <: Function
    id::Int
end
(h::_DiffHandler)(req, params...) = text("id=$(h.id)")

const _DIFF_METHODS = (:get, :post, :put, :patch, :delete, :options, :head)

const _DIFF_PATHS = [
    "/", "/a", "/a/b", "/users", "/users/:id::Int", "/users/:id::Int/posts",
    "/users/:id::Int/profile", "/posts/:slug", "/files/*rest", "*",
    "/x/:n::Float64/y", "/a/b/c", "/posts",
]

const _DIFF_PROBES = [
    "/", "/a", "/a/b", "/a/b/c", "/a//b", "/users", "/users/42", "/users/abraham",
    "/users/42/posts", "/users/42/profile", "/users/42/", "/users/", "/posts/hello",
    "/posts/hello/world", "/files/a/b/c", "/files/", "/x/1.5/y", "/x/z/y",
    "/unknown", "/users/42?x=1", "/a?b=c", "/%75sers/42", "/users/-1", "/users/2147483648",
]

# Runtime StaticRoute construction mirrors @routes' path parsing (tests are JIT,
# so eval is acceptable; the AOT profile uses the macro).
function _diff_static_route(method::Symbol, path::String, id::Int, cache)
    pt = get!(cache, path) do
        Core.eval(Mongoose.Kernel, Mongoose.Kernel._path_type_expr(path))
    end
    h = _DiffHandler(id)
    return Mongoose.Kernel.StaticRoute{method,pt,_DiffHandler,Tuple{}}(path, h, ())
end

function _diff_outcome(router, method::Symbol, path::String)
    res = process(RequestContext(router),
                  Request(method, path, Dict{String,String}(), Pair{String,String}[], ""))
    return (res.status, res.body, get(res.headers, "allow", nothing))
end

@testset "Differential: generic == frozen == static" begin
    rng = _DiffRNG(0x5EED)
    path_cache = Dict{String,Any}()

    for trial in 1:16
        nroutes = 6 + _diffint(rng, 3)
        specs = Tuple{Symbol,String,Int}[]
        seen = Set{Tuple{Symbol,String}}()
        while length(specs) < nroutes
            method = _diffpick(rng, _DIFF_METHODS)
            path = _diffpick(rng, _DIFF_PATHS)
            (method, path) in seen && continue
            push!(seen, (method, path))
            push!(specs, (method, path, length(specs) + 1))
        end

        generic = Router()
        frozen = Router()
        static_routes = Mongoose.Kernel.StaticRoute[]
        for (method, path, id) in specs
            route!(generic, method, path, _DiffHandler(id))
            route!(frozen, method, path, _DiffHandler(id))
            push!(static_routes, _diff_static_route(method, path, id, path_cache))
        end
        freeze!(frozen)
        static = StaticRouter(static_routes...)

        methods = _DIFF_METHODS
        probe_paths = unique(vcat([p for (_, p, _) in specs], _DIFF_PROBES))
        for path in probe_paths, method in methods
            a = _diff_outcome(generic, method, path)
            b = _diff_outcome(frozen, method, path)
            c = _diff_outcome(static, method, path)
            if !(a == b && b == c)
                @error "differential mismatch" trial specs method path generic=a frozen=b static=c
            end
            @test a == b
            @test b == c
        end

        for path in probe_paths
            @test Mongoose.Kernel.hasroute(generic, path) ==
                  Mongoose.Kernel.hasroute(static, path)
        end
    end
end
