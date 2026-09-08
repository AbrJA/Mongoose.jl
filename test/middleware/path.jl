@testset "Path-scoped middleware" begin
    s = App()
    get!(s, "/public") do req; text("public") end
    get!(s, "/admin/panel") do req; text("admin") end
    use!(s, bearer(t -> t == "secret"); paths=["/admin"])

    with_server(s) do port
        resp = HTTP.get("http://127.0.0.1:$port/public"; status_exception=false)
        @test resp.status == 200

        resp2 = HTTP.get("http://127.0.0.1:$port/admin/panel"; status_exception=false)
        @test resp2.status == 401

        resp3 = HTTP.get("http://127.0.0.1:$port/admin/panel";
            status_exception=false,
            headers=["Authorization" => "Bearer secret"])
        @test resp3.status == 200
    end
end
