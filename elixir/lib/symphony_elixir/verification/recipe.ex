defmodule SymphonyElixir.Verification.Recipe do
  @moduledoc """
  Verification recipe — read from `<workspace>/.opal/verify.json`.

  Schema (v1):

      {
        "version": "1",
        "description": "Curl the new endpoint",
        "steps": [
          {"name": "ping", "shell": "curl -fsS http://localhost:4000", "expect_exit": 0}
        ]
      }

  The agent that built the change emits the recipe as a byproduct of building —
  Opal does not author it. Opal only loads, executes, and judges.
  """

  alias SymphonyElixir.Verification.Recipe.Step

  @recipe_rel_path ".opal/verify.json"

  @type t :: %__MODULE__{
          description: String.t() | nil,
          steps: [Step.t()]
        }

  defstruct [:description, steps: []]

  @spec rel_path() :: String.t()
  def rel_path, do: @recipe_rel_path

  @spec read(Path.t()) ::
          {:ok, t()} | {:error, :no_recipe} | {:error, {:invalid_recipe, term()}}
  def read(workspace) when is_binary(workspace) do
    path = Path.join(workspace, @recipe_rel_path)

    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, :enoent} -> {:error, :no_recipe}
      {:error, reason} -> {:error, {:invalid_recipe, {:read_failed, reason}}}
    end
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_recipe, term()}}
  def parse(content) when is_binary(content) do
    with {:ok, data} <- decode_json(content),
         :ok <- ensure_map(data),
         {:ok, steps} <- parse_steps(Map.get(data, "steps")) do
      {:ok, %__MODULE__{description: Map.get(data, "description"), steps: steps}}
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_recipe, {:malformed_json, reason}}}
    end
  end

  defp ensure_map(value) when is_map(value), do: :ok
  defp ensure_map(_), do: {:error, {:invalid_recipe, :not_an_object}}

  defp parse_steps(steps) when is_list(steps) and steps != [] do
    steps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {step, index}, {:ok, acc} ->
      case Step.parse(step, index) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_recipe, {:step, index, reason}}}}
      end
    end)
    |> case do
      {:ok, parsed_reversed} -> {:ok, Enum.reverse(parsed_reversed)}
      {:error, _} = error -> error
    end
  end

  defp parse_steps(nil), do: {:error, {:invalid_recipe, :missing_steps}}
  defp parse_steps([]), do: {:error, {:invalid_recipe, :empty_steps}}
  defp parse_steps(_), do: {:error, {:invalid_recipe, :steps_not_a_list}}
end
