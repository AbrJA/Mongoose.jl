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
    mgr = app.manager.ptr
    timeout = app.poll_timeout
    last_sweep = time()
    while app.running[]
        mg_mgr_poll(mgr, timeout)
        isempty(app.ws_clients) || mg_mgr_poll(mgr, 0)
        if app.ws_idle_timeout > 0 && !isempty(app.ws_clients)
            now = time()
            if (now - last_sweep) >= 5.0
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
    while app.running[]
        mg_mgr_poll(app.manager.ptr, app.poll_timeout)

        did_ws = dispatch_replies!(app)
        did_ws && mg_mgr_poll(app.manager.ptr, 1)

        now = time()

        if (now - last_health) >= 2.0
            supervise_workers!(exec)
            last_health = now
        end

        if app.ws_idle_timeout > 0 && !isempty(app.ws_clients)
            if (now - last_sweep) >= 5.0
                ws_idle_sweep!(app)
                last_sweep = now
            end
        end
        yield()
    end
end
