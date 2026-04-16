defmodule SymphonyElixir.ClaudeCode.Runner do
  @moduledoc """
  Runs a single Claude Code (`claude -p`) turn as a subprocess.

  Unlike Codex, Claude Code's `-p` mode is stateless: each turn spawns a fresh
  subprocess. The workspace's `CLAUDE.md`, `.claude/skills/`, and `.claude/agents/`
  are auto-discovered by Claude Code based on cwd.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, PathSafety}

  @port_line_bytes 1_048_576

  @type session :: %{
          port: port(),
          session_id: String.t() | nil,
          metadata: map()
        }

  @doc """
  Runs a single Claude Code turn in `workspace`, piping `prompt` to stdin.

  Options:
    * `:on_message` — `(message :: map -> :ok)` callback for streaming events.
      Emits `:session_started`, `:turn_completed`, `:turn_failed`,
      `:turn_ended_with_error`.

  Returns `{:ok, %{result: :turn_completed, session_id, num_turns, usage}}` on
  success or `{:error, reason}` on failure (timeout, non-zero exit, malformed
  output).
  """
  @spec run_turn(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(workspace, prompt, issue, opts \\ [])
      when is_binary(workspace) and is_binary(prompt) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(expanded_workspace, prompt) do
      metadata = port_metadata(port)

      case await_completion(port, on_message, metadata, issue) do
        {:ok, result} ->
          stop_port(port)
          {:ok, result}

        {:error, reason} ->
          stop_port(port)
          emit(on_message, :turn_ended_with_error, %{reason: reason}, metadata)
          {:error, reason}
      end
    end
  end

  defp validate_workspace_cwd(workspace) do
    expanded = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_root, canonical_workspace}}
      end
    end
  end

  defp start_port(workspace, prompt) do
    cmd_settings = Config.settings!().claude_code
    executable = System.find_executable(cmd_settings.command)

    if is_nil(executable) do
      {:error, {:claude_command_not_found, cmd_settings.command}}
    else
      args = build_args(cmd_settings, workspace, prompt)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp build_args(cmd_settings, workspace, prompt) do
    base = [
      "-p",
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      cmd_settings.permission_mode,
      "--model",
      cmd_settings.model,
      "--add-dir",
      workspace
    ]

    base
    |> maybe_add_allowed_tools(cmd_settings.allowed_tools)
    |> Kernel.++(cmd_settings.extra_flags)
    # `--` ends option parsing so the prompt is never consumed by a preceding
    # variadic flag like `--allowedTools <tools...>`.
    |> Kernel.++(["--", prompt])
  end

  defp maybe_add_allowed_tools(args, nil), do: args
  defp maybe_add_allowed_tools(args, ""), do: args

  defp maybe_add_allowed_tools(args, tools) when is_binary(tools) do
    args ++ ["--allowedTools", tools]
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{claude_code_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp await_completion(port, on_message, metadata, issue) do
    timeout_ms = Config.settings!().claude_code.turn_timeout_ms
    deadline = monotonic_ms() + timeout_ms
    state = %{session_id: nil, last_assistant_usage: nil, line_buffer: ""}
    do_await(port, on_message, metadata, issue, deadline, state)
  end

  defp do_await(port, on_message, metadata, issue, deadline, state) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {:error, :turn_timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          full_line = state.line_buffer <> line
          new_state = %{state | line_buffer: ""}
          handle_line(port, on_message, metadata, issue, deadline, new_state, full_line)

        {^port, {:data, {:noeol, partial}}} ->
          new_state = %{state | line_buffer: state.line_buffer <> partial}
          do_await(port, on_message, metadata, issue, deadline, new_state)

        {^port, {:exit_status, 0}} ->
          {:ok, build_result(state, :turn_completed)}

        {^port, {:exit_status, status}} ->
          {:error, {:claude_exit_status, status}}
      after
        remaining ->
          {:error, :turn_timeout}
      end
    end
  end

  defp handle_line(port, on_message, metadata, issue, deadline, state, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init"} = payload} ->
        session_id = Map.get(payload, "session_id")
        Logger.info("Claude Code session started for #{issue_context(issue)} session_id=#{inspect(session_id)}")

        emit(on_message, :session_started, %{session_id: session_id, payload: payload}, metadata)

        do_await(port, on_message, metadata, issue, deadline, %{state | session_id: session_id})

      {:ok, %{"type" => "assistant", "message" => %{"usage" => usage}} = payload} when is_map(usage) ->
        emit(on_message, :assistant_message, %{payload: payload}, Map.put(metadata, :usage, usage))
        do_await(port, on_message, metadata, issue, deadline, %{state | last_assistant_usage: usage})

      {:ok, %{"type" => "result", "is_error" => true} = payload} ->
        Logger.warning("Claude Code turn failed for #{issue_context(issue)}: #{inspect(payload)}")
        emit(on_message, :turn_failed, %{payload: payload}, metadata_with_usage(metadata, payload))
        {:error, {:turn_failed, payload}}

      {:ok, %{"type" => "result"} = payload} ->
        Logger.info("Claude Code turn completed for #{issue_context(issue)} session_id=#{inspect(state.session_id)}")
        emit(on_message, :turn_completed, %{payload: payload}, metadata_with_usage(metadata, payload))

        do_await(port, on_message, metadata, issue, deadline, %{
          state
          | session_id: Map.get(payload, "session_id", state.session_id),
            last_assistant_usage: Map.get(payload, "usage", state.last_assistant_usage)
        })

      {:ok, payload} ->
        emit(on_message, :other_message, %{payload: payload}, metadata)
        do_await(port, on_message, metadata, issue, deadline, state)

      {:error, _decode_error} ->
        # Non-JSON output (warnings, errors from claude itself); just log and continue
        emit(on_message, :malformed, %{raw: line}, metadata)
        do_await(port, on_message, metadata, issue, deadline, state)
    end
  end

  defp build_result(state, result_atom) do
    %{
      result: result_atom,
      session_id: state.session_id,
      usage: state.last_assistant_usage
    }
  end

  defp metadata_with_usage(metadata, payload) when is_map(payload) do
    case Map.get(payload, "usage") do
      usage when is_map(usage) -> Map.put(metadata, :usage, usage)
      _ -> metadata
    end
  end

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_), do: "issue_id=unknown"
end
