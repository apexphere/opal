defmodule SymphonyElixir.HealthzApiTest do
  use SymphonyElixir.TestSupport

  defmodule AliveOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}
  end

  test "GET /healthz returns 200 with orchestrator running when orchestrator is alive" do
    orchestrator_name = Module.concat(__MODULE__, :RunningOrchestrator)
    start_supervised!({AliveOrchestrator, name: orchestrator_name})

    server_opts = [host: "127.0.0.1", port: 0, orchestrator: orchestrator_name]
    start_supervised!({HttpServer, server_opts})
    port = wait_for_bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/healthz")

    assert response.status == 200
    assert response.body["status"] == "ok"
    assert response.body["orchestrator"] == "running"
    assert List.first(Req.Response.get_header(response, "content-type")) =~ "application/json"
  end

  test "GET /healthz returns 503 with orchestrator stopped when orchestrator is not alive" do
    orchestrator_name = Module.concat(__MODULE__, :StoppedOrchestrator)

    server_opts = [host: "127.0.0.1", port: 0, orchestrator: orchestrator_name]
    start_supervised!({HttpServer, server_opts})
    port = wait_for_bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/healthz")

    assert response.status == 503
    assert response.body["status"] == "degraded"
    assert response.body["orchestrator"] == "stopped"
    assert List.first(Req.Response.get_header(response, "content-type")) =~ "application/json"
  end

  test "GET /healthz transitions from 200 to 503 when orchestrator crashes" do
    orchestrator_name = Module.concat(__MODULE__, :CrashingOrchestrator)
    start_supervised!({AliveOrchestrator, name: orchestrator_name}, id: :crashing_orch)

    server_opts = [host: "127.0.0.1", port: 0, orchestrator: orchestrator_name]
    start_supervised!({HttpServer, server_opts})
    port = wait_for_bound_port()

    running_response = Req.get!("http://127.0.0.1:#{port}/healthz")
    assert running_response.status == 200
    assert running_response.body["orchestrator"] == "running"

    stop_supervised!(:crashing_orch)

    stopped_response = Req.get!("http://127.0.0.1:#{port}/healthz")
    assert stopped_response.status == 503
    assert stopped_response.body["orchestrator"] == "stopped"
  end

  defp wait_for_bound_port do
    assert_eventually(fn -> is_integer(HttpServer.bound_port()) end)
    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
