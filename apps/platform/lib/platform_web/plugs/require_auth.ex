defmodule PlatformWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller

  alias Platform.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :current_user_id) do
      user_id when is_binary(user_id) ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> configure_session(drop: true)
            |> redirect(to: "/auth/login")
            |> halt()

          user ->
            assign(conn, :current_user, user)
        end

      _ ->
        conn
        |> redirect(to: "/auth/login")
        |> halt()
    end
  end
end
