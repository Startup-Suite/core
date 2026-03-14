defmodule PlatformWeb.AuthController do
  use PlatformWeb, :controller

  alias Platform.Accounts
  alias Platform.OIDC

  def login(conn, _params) do
    state = random_token()
    nonce = random_token()

    case OIDC.authorize_url(state, nonce) do
      {:ok, %{url: url}} ->
        conn
        |> put_session(:oidc_state, state)
        |> put_session(:oidc_nonce, nonce)
        |> redirect(external: url)

      {:ok, url} when is_binary(url) ->
        conn
        |> put_session(:oidc_state, state)
        |> put_session(:oidc_nonce, nonce)
        |> redirect(external: url)

      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> text("OIDC login failed: #{inspect(error)}")
    end
  end

  def callback(conn, %{"state" => state, "code" => _code} = params) do
    with ^state <- get_session(conn, :oidc_state),
         {:ok, auth} <- OIDC.callback(params),
         {:ok, oidc_user} <- extract_oidc_user(auth),
         {:ok, user} <- Accounts.find_or_create_from_oidc(oidc_user) do
      conn
      |> delete_session(:oidc_state)
      |> delete_session(:oidc_nonce)
      |> put_session(:current_user_id, user.id)
      |> maybe_put_id_token(auth)
      |> redirect(to: ~p"/")
    else
      nil ->
        invalid_state(conn)

      other_state when is_binary(other_state) ->
        invalid_state(conn)

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> text("OIDC callback failed: #{inspect(reason)}")
    end
  end

  def callback(conn, _params), do: invalid_state(conn)

  def logout(conn, _params) do
    id_token_hint = get_session(conn, :oidc_id_token)

    conn
    |> configure_session(drop: true)
    |> redirect(external: OIDC.logout_url(id_token_hint))
  end

  defp invalid_state(conn) do
    conn
    |> configure_session(drop: true)
    |> put_status(:unauthorized)
    |> text("Invalid OIDC state")
  end

  defp maybe_put_id_token(conn, auth) do
    case extract_id_token(auth) do
      nil -> delete_session(conn, :oidc_id_token)
      id_token -> put_session(conn, :oidc_id_token, id_token)
    end
  end

  defp extract_oidc_user(%{user: user}), do: normalize_oidc_user(user)
  defp extract_oidc_user(%{"user" => user}), do: normalize_oidc_user(user)

  defp extract_oidc_user(%{userinfo: user}), do: normalize_oidc_user(user)
  defp extract_oidc_user(%{"userinfo" => user}), do: normalize_oidc_user(user)

  defp extract_oidc_user(%{id_token: claims}) when is_map(claims), do: normalize_oidc_user(claims)

  defp extract_oidc_user(%{"id_token" => claims}) when is_map(claims),
    do: normalize_oidc_user(claims)

  defp extract_oidc_user(_auth), do: {:error, :missing_oidc_user}

  defp normalize_oidc_user(user) do
    user = for {key, value} <- user, into: %{}, do: {to_string(key), value}

    case {user["sub"], user["email"], user["name"]} do
      {sub, email, name} when is_binary(sub) and is_binary(email) and is_binary(name) ->
        {:ok, %{sub: sub, email: email, name: name}}

      _ ->
        {:error, :invalid_oidc_user}
    end
  end

  defp extract_id_token(%{token: token}), do: extract_id_token(token)
  defp extract_id_token(%{"token" => token}), do: extract_id_token(token)
  defp extract_id_token(%{id_token: id_token}) when is_binary(id_token), do: id_token
  defp extract_id_token(%{"id_token" => id_token}) when is_binary(id_token), do: id_token
  defp extract_id_token(_auth), do: nil

  defp random_token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
