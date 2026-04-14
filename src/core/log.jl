# Logging for Mongoose.jl — trim=safe, colors auto-detected at runtime.
#
# Default: pretty colored output via concrete print() calls. No config needed.
# Colors auto-detected in __init__ (works in JIT + AOT binaries).
#
# Optional: set LOG_NATIVE=true to expand @log_* to Julia's
# standard @info/@warn/@error, integrating with ConsoleLogger/TeeLogger.
# Selection is at macro-expansion (compile) time — juliac never sees the
# @info branch in AOT builds.
#
#   Normal JIT:      julia --project server.jl
#   Julia logging:   LOG_NATIVE=true julia --project server.jl
#   juliac AOT:      juliac --trim=safe --project . --output-exe binary server.jl

# ── TTY detection ─────────────────────────────────────────────────────────────
# Must run at module init time (binary startup), NOT at precompile time —
# there is no terminal attached during package precompilation.

const _TTY_REF = Ref{Bool}(false)

function _init_tty()
    _TTY_REF[] = @static if Sys.iswindows()
        (@ccall _isatty(1::Cint)::Cint) == 1
    else
        (@ccall isatty(1::Cint)::Cint) == 1
    end
end

# Returns the escape code if TTY, "" otherwise — always a concrete String.
@inline _c(s::String) = _TTY_REF[] ? s : ""

const _RST   = "\e[0m"
const _BOLD  = "\e[1m"
const _DIM   = "\e[2m"
const _GREEN = "\e[92m"
const _YORNG = "\e[93m"
const _RED   = "\e[91m"
const _BLUE  = "\e[94m"
const _UNDER = "\e[4m"

# ── Implementations ──────────────────────────────────────────────────────────

@noinline function _log_info_impl(file::String, line::Int, msg::String)
    print(Core.stdout,
        _c(_BOLD) * _c(_BLUE) * "[Info]" * _c(_RST) *
        _c(_DIM)  * " [Mongoose] " * file * ":" * string(line) * " — " * _c(_RST) * msg * "\n")
end

@noinline function _log_warn_impl(file::String, line::Int, msg::String)
    print(Core.stderr,
        _c(_BOLD) * _c(_YORNG) * "[Warn]" * _c(_RST) *
        _c(_DIM)  * " [Mongoose] " * file * ":" * string(line) * " — " * _c(_RST) * msg * "\n")
end

@noinline function _log_error_impl(file::String, line::Int, msg::String)::Nothing
    print(Core.stderr,
        _c(_BOLD) * _c(_RED) * "[Error]" * _c(_RST) *
        _c(_DIM)  * " [Mongoose] " * file * ":" * string(line) * " — " * _c(_RST) * msg * "\n")
    return nothing
end

@noinline function _log_error_impl(file::String, line::Int, msg::String, @nospecialize(e))::Nothing
    print(Core.stderr,
        _c(_BOLD) * _c(_RED) * "[Error]" * _c(_RST) *
        _c(_DIM)  * " [Mongoose] " * file * ":" * string(line) * " — " * _c(_RST) * msg * "\n")
    detail = try getfield(e, :msg)::String catch; "error" end
    print(Core.stderr, "        " * _c(_RED) * detail * _c(_RST) * "\n")
    return nothing
end

# ── Macros — backend chosen at macro-expansion (compile) time ────────────────

macro log_info(msg)
    file, line = basename(string(__source__.file)), __source__.line
    get(ENV, "LOG_NATIVE", "true") == "true" ?
        :(Base.@info $(esc(msg))) :
        :(_log_info_impl($file, $line, $(esc(msg))))
end

macro log_warn(msg)
    file, line = basename(string(__source__.file)), __source__.line
    get(ENV, "LOG_NATIVE", "true") == "true" ?
        :(Base.@warn $(esc(msg))) :
        :(_log_warn_impl($file, $line, $(esc(msg))))
end

macro log_error(msg)
    file, line = basename(string(__source__.file)), __source__.line
    get(ENV, "LOG_NATIVE", "true") == "true" ?
        :(Base.@error $(esc(msg))) :
        :(_log_error_impl($file, $line, $(esc(msg))))
end

macro log_error(msg, e)
    file, line = basename(string(__source__.file)), __source__.line
    get(ENV, "LOG_NATIVE", "true") == "true" ?
        :(Base.@error $(esc(msg)) exception=$(esc(e))) :
        :(_log_error_impl($file, $line, $(esc(msg)), $(esc(e))))
end

macro log_error(msg, e, bt)
    file, line = basename(string(__source__.file)), __source__.line
    get(ENV, "LOG_NATIVE", "true") == "true" ?
        :(Base.@error $(esc(msg)) exception=($(esc(e)), $(esc(bt)))) :
        :(_log_error_impl($file, $line, $(esc(msg)), $(esc(e))))
end

# ── Lifecycle ────────────────────────────────────────────────────────────────

function _logstart(server::AbstractServer, url::String)
    s_routes  = string(_routecount(server.core.router))
    s_mw      = string(length(server.core.middlewares))
    s_mounts  = string(length(server.core.mounts))
    s_workers = string(server isa Async ? server.nworkers : 0)
    s_threads = string(Threads.nthreads())
    io = Core.stdout
    print(io, "\n")
    print(io, _c(_BOLD) * _c(_BLUE) * "🚀 Mongoose" * _c(_RST) * " started\n")
    print(io, _c(_DIM) * "  URL:     " * _c(_RST) * _c(_UNDER) * _c(_BLUE) * url * _c(_RST) * "\n")
    print(io, _c(_DIM) * "  API:     " * _c(_RST) * _c(_GREEN) * s_routes * " routes • " * s_mw * " middleware • " * s_mounts * " mounts" * _c(_RST) * "\n")
    print(io, _c(_DIM) * "  Type:    " * _c(_RST) * _c(_BLUE) * String(nameof(typeof(server))) * _c(_RST) * "\n")
    print(io, _c(_DIM) * "  System:  " * _c(_RST) * _c(_GREEN) * s_workers * " workers • " * s_threads * " threads" * _c(_RST) * "\n")
    print(io, "\n")
end

function _logstop(server::AbstractServer)
    print(Core.stdout, _c(_BOLD) * _c(_RED)   * "🛑 Mongoose" * _c(_RST) * " shutting down...\n")
end

function _logstopped(server::AbstractServer)
    print(Core.stdout, _c(_BOLD) * _c(_GREEN) * "✅ Mongoose" * _c(_RST) * " stopped.\n")
end
