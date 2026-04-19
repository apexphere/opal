for app <- [:bandit, :phoenix, :phoenix_html, :phoenix_live_view] do
  Application.ensure_all_started(app)
end

{:ok, _} =
  Supervisor.start_link(
    [{Phoenix.PubSub, name: SymphonyElixir.PubSub}],
    strategy: :one_for_one
  )

Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint,
  server: true,
  http: [ip: {127, 0, 0, 1}, port: 41_777],
  url: [host: "localhost"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "opal-verify"]
)

{:ok, _} = SymphonyElixirWeb.Endpoint.start_link()

Process.sleep(:infinity)
