"""
    Unified event loop for App. Branches on the executor for sync/async mode.
"""

function event_loop(app::App)
    if !(app.executor isa AsyncExecutor)
        _event_loop_sync(app)
    else
        _event_loop_async(app)
    end
end

function _event_loop_sync(app::App)
    mgr = app.runtime.manager.ptr
    timeout = app.config.poll_timeout_ms
    last_sweep = time()
    while app.runtime.running[]
        mg_mgr_poll(mgr, timeout)
        isempty(app.runtime.ws_clients) || mg_mgr_poll(mgr, 0)
        drain_streams!(app)
        if app.config.ws_idle_timeout_ms > 0 && !isempty(app.runtime.ws_clients)
            now = time()
            if (now - last_sweep) >= 1.0
                ws_idle_sweep!(app)
                last_sweep = now
            end
        end
        yield()
    end
end

function _event_loop_async(app::App)
    exec = app.executor::AsyncExecutor
    last_sweep = time()
    last_health = time()
    while app.runtime.running[]
        mg_mgr_poll(app.runtime.manager.ptr, app.config.poll_timeout_ms)

        did_ws = dispatch_replies!(app)
        did_ws && mg_mgr_poll(app.runtime.manager.ptr, 1)
        drain_streams!(app)

        now = time()

        if (now - last_health) >= 2.0
            supervise_workers!(exec)
            last_health = now
        end

        if app.config.ws_idle_timeout_ms > 0 && !isempty(app.runtime.ws_clients)
            if (now - last_sweep) >= 1.0
                ws_idle_sweep!(app)
                last_sweep = now
            end
        end
        yield()
    end
end
