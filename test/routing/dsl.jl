@testset "Method helpers on App" begin
    app = App()
    get!(app, "/g") do req; text("get") end
    post!(app, "/p") do req; text("post") end
    put!(app, "/u") do req; text("put") end
    patch!(app, "/pa") do req; text("patch") end
    delete!(app, "/d") do req; text("delete") end

    with_server(app) do port
        @test HTTP.get("http://127.0.0.1:$port/g"; status_exception=false).status == 200
        @test HTTP.post("http://127.0.0.1:$port/p", []; status_exception=false).status == 200
        @test HTTP.request("PUT", "http://127.0.0.1:$port/u"; status_exception=false).status == 200
        @test HTTP.request("PATCH", "http://127.0.0.1:$port/pa"; status_exception=false).status == 200
        @test HTTP.request("DELETE", "http://127.0.0.1:$port/d"; status_exception=false).status == 200
    end
end

