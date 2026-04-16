defmodule SymphonyElixir.Github.Adapter do
  @moduledoc """
  GitHub Issues-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Github.Client}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    client_module().create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker
    labels_prefix = tracker.labels_prefix || ""

    current_state_labels = state_labels_for_issue(issue_id)

    case String.downcase(String.trim(state_name)) do
      terminal when terminal in ["done", "closed"] ->
        with :ok <- remove_state_labels(issue_id, current_state_labels) do
          client_module().update_issue(issue_id, %{state: "closed"})
        end

      _ ->
        new_label = Client.state_name_to_label(state_name, labels_prefix)

        with :ok <- remove_state_labels(issue_id, current_state_labels),
             :ok <- ensure_open(issue_id) do
          add_state_label(issue_id, new_label)
        end
    end
  end

  defp state_labels_for_issue(issue_id) do
    tracker = Config.settings!().tracker
    labels_prefix = tracker.labels_prefix || ""
    all_known_labels = known_state_labels(labels_prefix)

    case client_module().fetch_issue_states_by_ids([issue_id]) do
      {:ok, [issue | _]} ->
        Enum.filter(issue.labels, fn label ->
          MapSet.member?(all_known_labels, label)
        end)

      _ ->
        []
    end
  end

  defp known_state_labels(labels_prefix) do
    ["todo", "in-progress", "human-review"]
    |> Enum.map(fn base -> String.downcase(labels_prefix <> base) end)
    |> MapSet.new()
  end

  defp remove_state_labels(_issue_id, []), do: :ok

  defp remove_state_labels(issue_id, labels) do
    Enum.reduce_while(labels, :ok, fn label, :ok ->
      case client_module().remove_label(issue_id, label) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_open(issue_id) do
    client_module().update_issue(issue_id, %{state: "open"})
  end

  defp add_state_label(_issue_id, nil), do: :ok

  defp add_state_label(issue_id, label) do
    client_module().add_labels(issue_id, [label])
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
