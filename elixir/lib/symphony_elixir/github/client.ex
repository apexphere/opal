defmodule SymphonyElixir.Github.Client do
  @moduledoc """
  GitHub REST API client for polling issues and managing state.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issues_per_page 100
  @max_error_body_log_bytes 1_000
  @rate_limit_warning_threshold 100

  @state_label_map %{
    "todo" => "Todo",
    "in-progress" => "In Progress",
    "in progress" => "In Progress",
    "human-review" => "Human Review",
    "human review" => "Human Review"
  }

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_github_api_token}

      is_nil(tracker.repo) ->
        {:error, :missing_github_repo}

      true ->
        fetch_issues_by_state_labels(tracker, tracker.active_states)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_github_api_token}

        is_nil(tracker.repo) ->
          {:error, :missing_github_repo}

        true ->
          fetch_issues_by_state_labels(tracker, normalized_states)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        tracker = Config.settings!().tracker

        cond do
          is_nil(tracker.api_key) ->
            {:error, :missing_github_api_token}

          is_nil(tracker.repo) ->
            {:error, :missing_github_repo}

          true ->
            fetch_issues_by_numbers(tracker, ids)
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_number, body) when is_binary(issue_number) and is_binary(body) do
    tracker = Config.settings!().tracker

    case api_request(:post, "/repos/#{tracker.repo}/issues/#{issue_number}/comments", %{body: body}) do
      {:ok, %{status: 201}} -> :ok
      {:ok, response} -> {:error, {:github_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec add_labels(String.t(), [String.t()]) :: :ok | {:error, term()}
  def add_labels(issue_number, labels) when is_binary(issue_number) and is_list(labels) do
    tracker = Config.settings!().tracker

    case api_request(:post, "/repos/#{tracker.repo}/issues/#{issue_number}/labels", %{labels: labels}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, response} -> {:error, {:github_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_number, label) when is_binary(issue_number) and is_binary(label) do
    tracker = Config.settings!().tracker
    encoded_label = URI.encode(label, &URI.char_unreserved?/1)

    case api_request(:delete, "/repos/#{tracker.repo}/issues/#{issue_number}/labels/#{encoded_label}") do
      {:ok, %{status: status}} when status in [200, 204] -> :ok
      {:ok, %{status: 404}} -> :ok
      {:ok, response} -> {:error, {:github_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue(String.t(), map()) :: :ok | {:error, term()}
  def update_issue(issue_number, attrs) when is_binary(issue_number) and is_map(attrs) do
    tracker = Config.settings!().tracker

    case api_request(:patch, "/repos/#{tracker.repo}/issues/#{issue_number}", attrs) do
      {:ok, %{status: 200}} -> :ok
      {:ok, response} -> {:error, {:github_api_status, response.status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec normalize_issue(map(), String.t()) :: Issue.t()
  def normalize_issue(gh_issue, labels_prefix) when is_map(gh_issue) and is_binary(labels_prefix) do
    number = gh_issue["number"]
    labels = extract_labels(gh_issue)
    state = derive_state(gh_issue, labels, labels_prefix)

    %Issue{
      id: to_string(number),
      identifier: "##{number}",
      title: gh_issue["title"],
      description: gh_issue["body"],
      priority: nil,
      state: state,
      branch_name: "issue-#{number}",
      url: gh_issue["html_url"],
      assignee_id: get_in(gh_issue, ["assignee", "login"]),
      blocked_by: [],
      labels: labels,
      assigned_to_worker: true,
      created_at: parse_datetime(gh_issue["created_at"]),
      updated_at: parse_datetime(gh_issue["updated_at"])
    }
  end

  defp fetch_issues_by_state_labels(tracker, state_names) do
    labels = state_names_to_labels(state_names, tracker.labels_prefix || "")

    case labels do
      [] ->
        fetch_all_pages(tracker, [], tracker.assignee)

      labels ->
        # GitHub's labels param uses AND logic, so we must query each label
        # separately and merge results to get OR behavior
        fetch_issues_by_label_union(tracker, labels)
    end
  end

  defp fetch_issues_by_label_union(tracker, labels) do
    results =
      Enum.reduce_while(labels, {:ok, %{}}, fn label, {:ok, acc} ->
        case fetch_all_pages(tracker, [label], tracker.assignee) do
          {:ok, issues} -> {:cont, {:ok, merge_issues(issues, acc)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, issues_map} -> {:ok, Map.values(issues_map)}
      error -> error
    end
  end

  defp merge_issues(issues, acc) do
    Enum.reduce(issues, acc, fn issue, map -> Map.put_new(map, issue.id, issue) end)
  end

  defp fetch_issues_by_numbers(tracker, issue_numbers) do
    labels_prefix = tracker.labels_prefix || ""

    results =
      Enum.reduce_while(issue_numbers, {:ok, []}, fn number, {:ok, acc} ->
        case api_request(:get, "/repos/#{tracker.repo}/issues/#{number}") do
          {:ok, %{status: 200, body: body}} ->
            issue = normalize_issue(body, labels_prefix)
            {:cont, {:ok, [issue | acc]}}

          {:ok, %{status: 404}} ->
            {:cont, {:ok, acc}}

          {:ok, response} ->
            {:halt, {:error, {:github_api_status, response.status}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp fetch_all_pages(tracker, labels, assignee) do
    fetch_page(tracker, labels, assignee, 1, [])
  end

  defp fetch_page(tracker, labels, assignee, page, acc) do
    labels_prefix = tracker.labels_prefix || ""

    query_params =
      [
        state: "open",
        per_page: @issues_per_page,
        page: page,
        sort: "created",
        direction: "asc"
      ]
      |> maybe_add_labels(labels)
      |> maybe_add_assignee(assignee)

    path = "/repos/#{tracker.repo}/issues?" <> URI.encode_query(query_params)

    case api_request(:get, path) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        issues_only = Enum.reject(body, &Map.has_key?(&1, "pull_request"))

        page_issues =
          issues_only
          |> Enum.map(&normalize_issue(&1, labels_prefix))
          |> maybe_filter_assignee(assignee)

        updated_acc = acc ++ page_issues

        if length(body) < @issues_per_page do
          {:ok, updated_acc}
        else
          fetch_page(tracker, labels, assignee, page + 1, updated_acc)
        end

      {:ok, %{status: status} = response} ->
        Logger.error("GitHub API request failed status=#{status}#{github_error_context(response)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp maybe_add_labels(params, []), do: params

  defp maybe_add_labels(params, labels) do
    Keyword.put(params, :labels, Enum.join(labels, ","))
  end

  defp maybe_add_assignee(params, nil), do: params
  defp maybe_add_assignee(params, ""), do: params
  defp maybe_add_assignee(params, assignee), do: Keyword.put(params, :assignee, assignee)

  defp maybe_filter_assignee(issues, nil), do: issues
  defp maybe_filter_assignee(issues, ""), do: issues

  defp maybe_filter_assignee(issues, assignee) do
    Enum.filter(issues, fn %Issue{assignee_id: aid} ->
      is_nil(aid) or aid == assignee
    end)
  end

  defp state_names_to_labels(state_names, labels_prefix) do
    Enum.flat_map(state_names, fn name ->
      label = state_name_to_label(name, labels_prefix)
      if label, do: [label], else: []
    end)
  end

  @state_name_to_label_map %{
    "todo" => "todo",
    "in progress" => "in-progress",
    "human review" => "human-review"
  }

  @terminal_states MapSet.new(["done", "closed", "cancelled", "canceled"])

  @doc false
  @spec state_name_to_label(String.t(), String.t()) :: String.t() | nil
  def state_name_to_label(state_name, labels_prefix) do
    normalized = String.downcase(String.trim(state_name))

    if MapSet.member?(@terminal_states, normalized) do
      nil
    else
      base = Map.get(@state_name_to_label_map, normalized, normalized)
      labels_prefix <> base
    end
  end

  defp derive_state(gh_issue, labels, labels_prefix) do
    if gh_issue["state"] == "closed" do
      "Done"
    else
      find_state_from_labels(labels, labels_prefix) || "Todo"
    end
  end

  defp find_state_from_labels(labels, labels_prefix) do
    Enum.find_value(labels, fn label ->
      stripped =
        if labels_prefix != "" and String.starts_with?(label, labels_prefix) do
          String.replace_prefix(label, labels_prefix, "")
        else
          label
        end

      Map.get(@state_label_map, String.downcase(stripped))
    end)
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    Enum.map(labels, fn
      %{"name" => name} when is_binary(name) -> String.downcase(name)
      label when is_binary(label) -> String.downcase(label)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp api_request(method, path, body \\ nil) do
    request_fun = request_fun()
    request_fun.(method, path, body)
  end

  defp request_fun do
    Application.get_env(:symphony_elixir, :github_request_fun, &default_request/3)
  end

  defp default_request(method, path, body) do
    tracker = Config.settings!().tracker
    url = "https://api.github.com#{path}"

    headers = [
      {"Authorization", "Bearer #{tracker.api_key}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]

    opts = [
      headers: headers,
      connect_options: [timeout: 30_000]
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
        :patch -> Req.request(Keyword.merge(opts, url: url, method: :patch))
        :delete -> Req.request(Keyword.merge(opts, url: url, method: :delete))
      end

    case result do
      {:ok, response} ->
        check_rate_limit(response)
        {:ok, response}

      {:error, reason} ->
        {:error, {:github_api_request, reason}}
    end
  end

  defp check_rate_limit(%{headers: headers}) do
    remaining =
      headers
      |> Enum.find_value(fn
        {"x-ratelimit-remaining", value} -> value
        _ -> nil
      end)

    case remaining do
      nil ->
        :ok

      value ->
        case Integer.parse(to_string(value)) do
          {n, _} when n <= @rate_limit_warning_threshold ->
            Logger.warning("GitHub API rate limit low: #{n} requests remaining")

          _ ->
            :ok
        end
    end
  end

  defp check_rate_limit(_), do: :ok

  defp github_error_context(%{body: body}) do
    " body=" <> summarize_error_body(body)
  end

  defp github_error_context(_), do: ""

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
