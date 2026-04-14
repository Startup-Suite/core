defmodule Platform.Meetings.Participant do
  @moduledoc """
  Schema for a meeting participant tracked via LiveKit webhooks.

  A participant may be linked to a `user_id` or `agent_id` for display
  name and avatar resolution. The `identity` field is the LiveKit
  participant identity string used for join/leave matching.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_participants" do
    field(:identity, :string)
    field(:display_name, :string)
    field(:joined_at, :utc_datetime_usec)
    field(:left_at, :utc_datetime_usec)
    field(:metadata, :map, default: %{})

    belongs_to(:room, Platform.Meetings.Room)
    belongs_to(:user, Platform.Accounts.User)
    belongs_to(:agent, Platform.Agents.Agent)

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(room_id identity joined_at)a
  @optional ~w(user_id agent_id display_name left_at metadata)a

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
  end
end
