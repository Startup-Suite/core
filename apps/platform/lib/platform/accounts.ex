defmodule Platform.Accounts do
  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Repo

  def get_user(id), do: Repo.get(User, id)

  @doc """
  List all users, optionally filtered by a search query (name or email).
  """
  @spec list_users(keyword()) :: [User.t()]
  def list_users(opts \\ []) do
    query = Keyword.get(opts, :query)

    base = from(u in User, order_by: [asc: u.name])

    base =
      if query && String.trim(query) != "" do
        pattern = "%#{String.trim(query)}%"
        where(base, [u], ilike(u.name, ^pattern) or ilike(u.email, ^pattern))
      else
        base
      end

    Repo.all(base)
  end

  def find_or_create_from_oidc(%{sub: sub, email: email, name: name} = oidc_attrs)
      when is_binary(sub) and is_binary(email) and is_binary(name) do
    avatar_url = normalize_avatar_url(Map.get(oidc_attrs, :avatar_url))
    attrs = %{oidc_sub: sub, email: email, name: name, avatar_url: avatar_url}

    upsert_fields = [
      email: email,
      name: name,
      avatar_url: avatar_url,
      updated_at: DateTime.utc_now(:second)
    ]

    case Repo.get_by(User, oidc_sub: sub) do
      %User{} = user ->
        user
        |> User.changeset(attrs)
        |> Repo.update()

      nil ->
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert(
          on_conflict: [set: upsert_fields],
          conflict_target: [:oidc_sub],
          returning: true
        )
    end
  end

  def find_or_create_from_oidc(_attrs), do: {:error, :invalid_oidc_user}

  defp normalize_avatar_url(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      value
    end
  end

  defp normalize_avatar_url(_value), do: nil
end
