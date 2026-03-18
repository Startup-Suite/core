defmodule Platform.Artifacts.Supervisor do
  @moduledoc """
  Supervisor for in-process artifact domain state.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([Platform.Artifacts.Store], strategy: :one_for_one)
  end
end
