"""
    Logging subsystem — uses Julia's standard @info/@warn/@error macros.

    Colors auto-detected per output stream at module init time for lifecycle banners.
"""

# ── TTY detection ─────────────────────────────────────────────────────────────

const _TTY_OUT = Ref{Bool}(false)
const _TTY_ERR = Ref{Bool}(false)

function init_tty!()
    @static if Sys.iswindows()
        _TTY_OUT[] = (@ccall _isatty(1::Cint)::Cint) == 1
        _TTY_ERR[] = (@ccall _isatty(2::Cint)::Cint) == 1
    else
        _TTY_OUT[] = (@ccall isatty(1::Cint)::Cint) == 1
        _TTY_ERR[] = (@ccall isatty(2::Cint)::Cint) == 1
    end
end

# ANSI escape codes — only emitted when output is a TTY
@inline _color(s::String, stderr_mode::Bool=false) =
    (stderr_mode ? _TTY_ERR[] : _TTY_OUT[]) ? s : ""

const _RST   = "\e[0m"
const _BOLD  = "\e[1m"
const _DIM   = "\e[2m"
const _GREEN = "\e[92m"
const _YELLOW = "\e[93m"
const _RED   = "\e[91m"
const _BLUE  = "\e[94m"
const _UNDER = "\e[4m"

# ── Macros — thin wrappers around Julia's standard logging ───────────────────

macro log_info(msg)
    :(Base.@info $(esc(msg)))
end

macro log_warn(msg)
    :(Base.@warn $(esc(msg)))
end

macro log_error(msg)
    :(Base.@error $(esc(msg)))
end

macro log_error(msg, e)
    :(Base.@error $(esc(msg)) exception=$(esc(e)))
end

macro log_error(msg, e, bt)
    :(Base.@error $(esc(msg)) exception=($(esc(e)), $(esc(bt))))
end

# ── Lifecycle banners ────────────────────────────────────────────────────────

function log_server_start(server, url::String)
    s_routes  = string(route_count(server.router))
    s_mw      = string(length(server.middlewares))
    s_mounts  = string(length(server.mounts))
    s_workers = server.workers > 0 ? string(server.workers) : "0"
    s_threads = string(Threads.nthreads())
    io = Core.stdout
    print(io, "\n")
    print(io, _color(_BOLD), _color(_BLUE), "🚀 Mongoose", _color(_RST), " started\n")
    print(io, _color(_DIM), "  URL:     ", _color(_RST), _color(_UNDER), _color(_BLUE), url, _color(_RST), "\n")
    print(io, _color(_DIM), "  API:     ", _color(_RST), _color(_GREEN), s_routes, " routes • ", s_mw, " middleware • ", s_mounts, " mounts", _color(_RST), "\n")
    print(io, _color(_DIM), "  Type:    ", _color(_RST), _color(_BLUE), String(nameof(typeof(server))), _color(_RST), "\n")
    print(io, _color(_DIM), "  System:  ", _color(_RST), _color(_GREEN), s_workers, " workers • ", s_threads, " threads", _color(_RST), "\n")
    print(io, "\n")
end

function log_server_stop(server)
    print(Core.stdout, _color(_BOLD), _color(_RED), "🛑 Mongoose", _color(_RST), " shutting down...\n")
end

function log_server_stopped(server)
    print(Core.stdout, _color(_BOLD), _color(_GREEN), "✅ Mongoose", _color(_RST), " stopped.\n")
end
