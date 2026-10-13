@testset "Pluggable router (AbstractRouter protocol)" begin
    r = DictRouter()
    @test r isa AbstractRouter

    app = App(router=r)
    @test app isa App{DictRouter}
    route!(app, :get, "/custom") do req; text("custom router") end

    with_server(app) do port
        resp = HTTP.get("http://127.0.0.1:$port/custom"; status_exception=false)
        @test resp.status == 200
        @test String(resp.body) == "custom router"

        resp404 = HTTP.get("http://127.0.0.1:$port/unknown"; status_exception=false)
        @test resp404.status == 404
    end

    # The default Router still dispatches through the same seam.
    app_default = App()
    route!(app_default, :get, "/default") do req; text("default router") end
    with_server(app_default) do port
        resp = HTTP.get("http://127.0.0.1:$port/default"; status_exception=false)
        @test resp.status == 200
    end
end
