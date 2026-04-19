defmodule SymphonyElixir.Verification.Recipe.Step do
  @moduledoc """
  A single recipe step. Phase-1 supports a shell command and an expected exit code.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          shell: String.t(),
          expect_exit: integer()
        }

  defstruct [:name, :shell, expect_exit: 0]

  @spec parse(map(), pos_integer()) :: {:ok, t()} | {:error, term()}
  def parse(%{"shell" => shell} = step, index)
      when is_binary(shell) and shell != "" do
    {:ok,
     %__MODULE__{
       name: name(step, index),
       shell: shell,
       expect_exit: expect_exit(step)
     }}
  end

  def parse(%{}, _index), do: {:error, :missing_shell}
  def parse(_, _index), do: {:error, :not_an_object}

  defp name(step, index) do
    case Map.get(step, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> "step_#{index}"
    end
  end

  defp expect_exit(step) do
    case Map.get(step, "expect_exit", 0) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end
end
