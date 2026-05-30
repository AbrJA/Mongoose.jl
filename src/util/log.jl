"""
    Logging subsystem — dual-mode: Julia's @info/@warn/@error (JIT) or
    direct print (AOT trim-safe binaries).

    Colors auto-detected per output stream at module init time.
    Set `LOG_TRIMMABLE=true` environment variable for AOT-safe print mode.
"""

# ── TTY detection ─────────────────────────────────────────────────────────────

const _TTY_OUT = Ref{Bool}(false)
const _TTY_ERR = Ref{Bool}(false)
const _TRIMMABLE = Ref{Bool}(false)

@inline is_trimmable() = _TRIMMABLE[]

function init_tty!()
    @static if Sys.iswindows()
        _TTY_OUT[] = (@ccall _isatty(1::Cint)::Cint) == 1
        _TTY_ERR[] = (@ccall _isatty(2::Cint)::Cint) == 1
    else
        _TTY_OUT[] = (@ccall isatty(1::Cint)::Cint) == 1
        _TTY_ERR[] = (@ccall isatty(2::Cint)::Cint) == 1
    end
end

function init_log_backend!()
    val = get(ENV, "LOG_TRIMMABLE", "false")
    s = lowercase(strip(val))
    _TRIMMABLE[] = s == "1" || s == "true" || s == "yes" || s == "on"
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

# ── Print implementations (used by trim-safe mode) ───────────────────────────

@noinline function _print_info(file::String, line::Int, msg::String)
    print(Core.stdout,
        _color(_BOLD), _color(_BLUE), "[Info]", _color(_RST),
        _color(_DIM), " [Mongoose] ", file, ":", string(line), " — ", _color(_RST), msg, "\n")
end

@noinline function _print_warn(file::String, line::Int, msg::String)
    print(Core.stderr,
        _color(_BOLD, true), _color(_YELLOW, true), "[Warn]", _color(_RST, true),
        _color(_DIM, true), " [Mongoose] ", file, ":", string(line), " — ", _color(_RST, true), msg, "\n")
end

@noinline function _print_error(file::String, line::Int, msg::String)::Nothing
    print(Core.stderr,
        _color(_BOLD, true), _color(_RED, true), "[Error]", _color(_RST, true),
        _color(_DIM, true), " [Mongoose] ", file, ":", string(line), " — ", _color(_RST, true), msg, "\n")
    return nothing
end

@noinline function _print_error(file::String, line::Int, msg::String, @nospecialize(e))::Nothing
    _print_error(file, line, msg)
    detail = try getfield(e, :msg)::String catch; string(e) end
    print(Core.stderr, "        ", _color(_RED, true), detail, _color(_RST, true), "\n")
    return nothing
end

# ── Macros — backend chosen at runtime ───────────────────────────────────────

macro log_info(msg)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !is_trimmable()
            Base.@info $(esc(msg))
        else
            _print_info($file, $line, $(esc(msg)))
        end
    end
end

macro log_warn(msg)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !is_trimmable()
            Base.@warn $(esc(msg))
        else
            _print_warn($file, $line, $(esc(msg)))
        end
    end
end

macro log_error(msg)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !is_trimmable()
            Base.@error $(esc(msg))
        else
            _print_error($file, $line, $(esc(msg)))
        end
    end
end

macro log_error(msg, e)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !is_trimmable()
            Base.@error $(esc(msg)) exception=$(esc(e))
        else
            _print_error($file, $line, $(esc(msg)), $(esc(e)))
        end
    end
end

macro log_error(msg, e, bt)
    file, line = basename(string(__source__.file)), __source__.line
    quote
        if !is_trimmable()
            Base.@error $(esc(msg)) exception=($(esc(e)), $(esc(bt)))
        else
            _print_error($file, $line, $(esc(msg)), $(esc(e)))
        end
    end
end

# ── Lifecycle banners ────────────────────────────────────────────────────────

function log_server_start(server, url::String)
    s_routes  = string(route_count(server.core.router))
    s_mw      = string(length(server.core.middlewares))
    s_mounts  = string(length(server.core.mounts))
    s_workers = server isa Async ? string(server.nworkers) : "0"
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
