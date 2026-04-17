# Logging for Mongoose.jl — native Julia logging by default, with trim-safe mode.
#
# Default: route @log_* to Julia's @info/@warn/@error.
# Colors auto-detected in __init__ (works in JIT + AOT binaries).
#
# For trim-safe/static binaries, set LOG_TRIMMABLE=true
# to force concrete print()-based logging instead of Base logging macros.
#
#   juliac AOT:      LOG_TRIMMABLE=true juliac --trim=safe --project . --output-exe binary server.jl

# ── TTY detection ─────────────────────────────────────────────────────────────
# Must run at module init time (binary startup), NOT at precompile time —
# there is no terminal attached during package precompilation.

const _TTY_REF = Ref{Bool}(false)
const _LOG_TRIMMABLE_REF = Ref{Bool}(false)

@inline _log_trimmable_enabled() = _LOG_TRIMMABLE_REF[]

function _init_tty()
    _TTY_REF[] = @static if Sys.iswindows()
        (@ccall _isatty(1::Cint)::Cint) == 1
    else
        (@ccall isatty(1::Cint)::Cint) == 1
    end
end

@inline function _parse_env_bool(v::AbstractString)::Bool
    s = lowercase(strip(v))
    return s == "1" || s == "true" || s == "yes" || s == "on"
end

function _init_log_backend!()
    wants_trim_safe = _parse_env_bool(get(ENV, "LOG_TRIMMABLE", "false"))
    _LOG_TRIMMABLE_REF[] = wants_trim_safe
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

# ── Macros — backend chosen at runtime ───────────────────────────────────────

macro log_info(msg)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !_log_trimmable_enabled()
            Base.@info $(esc(msg))
        else
            _log_info_impl($file, $line, $(esc(msg)))
        end
    end
end

macro log_warn(msg)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !_log_trimmable_enabled()
            Base.@warn $(esc(msg))
        else
            _log_warn_impl($file, $line, $(esc(msg)))
        end
    end
end

macro log_error(msg)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !_log_trimmable_enabled()
            Base.@error $(esc(msg))
        else
            _log_error_impl($file, $line, $(esc(msg)))
        end
    end
end

macro log_error(msg, e)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !_log_trimmable_enabled()
            Base.@error $(esc(msg)) exception=$(esc(e))
        else
            _log_error_impl($file, $line, $(esc(msg)), $(esc(e)))
        end
    end
end

macro log_error(msg, e, bt)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !_log_trimmable_enabled()
            Base.@error $(esc(msg)) exception=($(esc(e)), $(esc(bt)))
        else
            _log_error_impl($file, $line, $(esc(msg)), $(esc(e)))
        end
    end
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
