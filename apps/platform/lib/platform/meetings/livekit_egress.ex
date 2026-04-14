defmodule Platform.Meetings.LivekitEgress do
  @moduledoc """
  Client for LiveKit's Egress API.

  Wraps HTTP calls to start/stop room composite egress recordings.
  Authentication uses JWT tokens signed with the LiveKit API key/secret.
  """

  require Logger

  @token_ttl 600

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Start a room composite egress recording.

  Records the entire room as a single composite output (audio + video mixed).
  Returns `{:ok, egress_id}` on success.
  """
  @spec start_room_composite_egress(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_room_composite_egress(room_name, opts \\ []) do
    body = %{
      room_name: room_name,
      file: %{
        file_type: Keyword.get(opts, :file_type, "mp4"),
        filepath: Keyword.get(opts, :filepath, "recordings/{room_name}-{time}")
      },
      audio_only: Keyword.get(opts, :audio_only, false)
    }

    case post("/twirp/livekit.Egress/StartRoomCompositeEgress", body) do
      {:ok, %{"egress_id" => egress_id}} ->
        Logger.info("[LivekitEgress] Started egress #{egress_id} for room #{room_name}")
        {:ok, egress_id}

      {:ok, response} ->
        Logger.warning("[LivekitEgress] Unexpected response: #{inspect(response)}")
        {:error, {:unexpected_response, response}}

      {:error, reason} ->
        Logger.warning(
          "[LivekitEgress] Failed to start egress for #{room_name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Stop an active egress by ID.
  """
  @spec stop_egress(String.t()) :: :ok | {:error, term()}
  def stop_egress(egress_id) do
    case post("/twirp/livekit.Egress/StopEgress", %{egress_id: egress_id}) do
      {:ok, _} ->
        Logger.info("[LivekitEgress] Stopped egress #{egress_id}")
        :ok

      {:error, reason} ->
        Logger.warning("[LivekitEgress] Failed to stop egress #{egress_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp post(path, body) do
    config = config()
    url = "#{config[:api_url]}#{path}"

    token = generate_access_token(config[:api_key], config[:api_secret])

    case Req.post(url,
           json: body,
           headers: [
             {"authorization", "Bearer #{token}"},
             {"content-type", "application/json"}
           ],
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, exception} ->
        {:error, {:request_failed, exception}}
    end
  end

  @doc false
  def generate_access_token(api_key, api_secret) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "HS256", "typ" => "JWT"}), padding: false)

    now = System.system_time(:second)

    payload =
      Base.url_encode64(
        Jason.encode!(%{
          "iss" => api_key,
          "exp" => now + @token_ttl,
          "nbf" => now,
          "sub" => api_key,
          "video" => %{
            "room_record" => true
          }
        }),
        padding: false
      )

    signing_input = "#{header}.#{payload}"
    signature = :crypto.mac(:hmac, :sha256, api_secret, signing_input)
    sig_encoded = Base.url_encode64(signature, padding: false)

    "#{signing_input}.#{sig_encoded}"
  end

  defp config do
    Application.get_env(:platform, :livekit, [])
  end
end
