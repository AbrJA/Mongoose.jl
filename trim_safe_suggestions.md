# JuliaC `trim=safe` Compatibility Report

Mongoose.jl has been architected with strong types and a decoupled structure, which gives it a massive advantage for static compilation (`juliac`).
Currently, Mongoose avoids the most critical blockers like `eval()` and `invokelatest()`. However, dead code elimination (DCE/trimming) requires the compiler to statically infer the entire call graph.

To achieve full `trim=safe` compatibility and avoid missing methods in AOT binaries, we must resolve a few areas of dynamic dispatch:

## 1. Eliminate Abstract Types in Struct Fields
Currently, `ServerCore` holds its router as an abstract type:
```julia
mutable struct ServerCore
    ...
    router::Route # Abstract! Causes dynamic dispatch.
    middlewares::Vector{Middleware} # Abstract!
end
```
**Fix:** Parameterize the server structs so the compiler knows the exact type at compile time:
```julia
mutable struct ServerCore{R <: Route}
    router::R
end

mutable struct AsyncServer{R <: Route} <: Server
    core::ServerCore{R}
    ...
end
```
For middlewares, consider using a `Tuple` instead of `Vector{Middleware}` to allow the compiler to unroll and type-infer the entire middleware pipeline sequentially without allocating or dynamically dispatching.

## 2. Eliminate `Any` in Async Worker Channels
In [src/servers/async.jl](file:///home/ajaimes/Documents/GitHub/Julia/Packages/Mongoose.jl/src/servers/async.jl), the core channels currently accept `Any` to handle both HTTP and WebSocket messages. `Any` completely blocks type inference and method resolution for the trim analyzer.
```julia
# Current:
requests::Channel{Any}
responses::Channel{Any}

# Trim-Safe Fix:
const IncomingMessage = Union{IdRequest, IdWsMessage}
const OutgoingMessage = Union{IdResponse, IdWsMessage}

requests::Channel{IncomingMessage}
responses::Channel{OutgoingMessage}
```

## 3. Handlers and Return Types
Ensure that the `Router` handlers are typed if possible. Currently, the trie router holds functions as `Function`. Since `Function` is an abstract type in Julia, calling a stored function involves dynamic dispatch. 
For a fully trim-safe AOT binary, Mongoose could generate a single monolithic dispatch function via a macro mapping endpoints statically, or users must be aware that functions stored in dictionaries might require explicit precompilation directives (`precompile(my_handler, (HttpRequest, Dict{String,String}))`) to prevent the trimmer from dropping them.

## 4. `libmongoose` Shared Library Loading
When compiling an AOT binary, `Mongoose_jll` might try to dynamically load the shared library path at runtime. Ensure `Mongoose_jll` uses `RTLD_LAZY | RTLD_DEEPBIND` or that the generated binary correctly bundles `libmongoose.so` using `juliac --bundle`.

### Summary
By updating `Channel{Any}` to `Channel{Union{...}}`, parameterizing `router::R`, and explicitly precompiling user handlers, Mongoose.jl will be **100% trim-safe** and AOT-compilable for generating ultra-compact, high-performance standalone microservices.
