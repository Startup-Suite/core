defmodule Platform.Meetings.Egress do
  @moduledoc """
  HTTP client for the LiveKit Egress API (Twirp/JSON mode).

  Provides functions to start, stop, and list egress recordings via LiveKit's
  Twirp API endpoints. Uses `Req` for HTTP and the same HS256 JWT auth pattern
  as `Platform.Meetings.generate_token/2`.

  ## Configuration

  Requires the following environment variables:
  - `LIVEKIT_URL` — LiveKit server URL (e.g. `https://livekit.example.com`)
  - `LIVEKIT_API_KEY` — API key for JWT signing
  - `LIVEKIT_API_SECRET` — API secret for JWT signing
  - `RECORDING_STORAGE_PATH` — local file storage path (default: `priv/static/recordings/`)
  """

  require Logger

  @twirp_start "/twirp/livekit.Egress/StartRoomCompositeEgress"
  @twirp_stop "/twirp/livekit.Egress/StopEgress"
  @twirp_list "/twirp/livekit.Egress/ListEgress"

  @doc """
  Start a room composite egress recording.

  Calls LiveKit's `StartRoomCompositeEgress` endpoint to begin recording
  the specified room. Output is configured for local file storage in WebM
  format (VP8 video + Opus audio).

  ## Options
  - `:audio_only` — if `true`, records audio only (default: `false`)

  Returns `{:ok, egress_response}` or `{:error, reason}`.
  """
  @spec start_room_composite_egress(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_room_composite_egress(room_name, opts \\ []) do
    audio_only = Keyword.get(opts, :audio_only, false)
    storage_path = recording_storage_path()

    # Ensure storage directory exists
    File.mkdir_p!(storage_path)

    # Build file output config
    file_output = %{
      "fileType" => "DEFAULT_FILETYPE",
      "filepath" => Path.join(storage_path, "#{room_name}-{time}.webm")
    }

    body =
      %{
        "room_name" => room_name,
        "audio_only" => audio_only,
        "file_outputs" => [file_output]
      }

    twirp_request(@twirp_start, body)
  end

  @doc """
  Stop an active egress by its ID.

  Returns `{:ok, egress_response}` or `{:error, reason}`.
  """
  @spec stop_egress(String.t()) :: {:ok, map()} | {:error, term()}
  def stop_egress(egress_id) do
    twirp_request(@twirp_stop, %{"egress_id" => egress_id})
  end

  @doc """
  List egress recordings, optionally filtered by room name.

  Returns `{:ok, %{\"items\" => [...]}}` or `{:error, reason}`.
  """
  @spec list_egress(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def list_egress(room_name \\ nil) do
    body =
      if room_name,
        do: %{"room_name" => room_name},
        else: %{}

    twirp_request(@twirp_list, body)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp twirp_request(path, body) do
    with {:ok, url} <- livekit_url(),
         {:ok, token} <- generate_egress_token() do
      full_url = String.trim_trailing(url, "/") <> path

      case Req.post(full_url,
             json: body,
             headers: [
               {"authorization", "Bearer #{token}"},
               {"content-type", "application/json"}
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: 200, body: resp_body}} ->
          {:ok, resp_body}

        {:ok, %Req.Response{status: status, body: resp_body}} ->
          Logger.error(
            "[Egress] Twirp request to #{path} failed: status=#{status} body=#{inspect(resp_body)}"
          )

          {:error, {:twirp_error, status, resp_body}}

        {:error, reason} ->
          Logger.error("[Egress] HTTP request to #{path} failed: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end
  end

  @doc false
  def generate_egress_token do
    api_key = System.get_env("LIVEKIT_API_KEY")
    api_secret = System.get_env("LIVEKIT_API_SECRET")

    if is_nil(api_key) or is_nil(api_secret) do
      {:error, :livekit_not_configured}
    else
      now = System.system_time(:second)

      claims = %{
        "iss" => api_key,
        "nbf" => now,
        "exp" => now + 600,
        "jti" => Ecto.UUID.generate(),
        "video" => %{
          "roomRecord" => true
        }
      }

      {:ok, encode_jwt(claims, api_secret)}
    end
  end

  defp encode_jwt(claims, secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    header_b64 = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    payload_b64 = claims |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = "#{header_b64}.#{payload_b64}"
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    sig_b64 = Base.url_encode64(signature, padding: false)

    "#{signing_input}.#{sig_b64}"
  end

  defp livekit_url do
    case System.get_env("LIVEKIT_URL") do
      nil -> {:error, :livekit_not_configured}
      url -> {:ok, url}
    end
  end

  defp recording_storage_path do
    System.get_env("RECORDING_STORAGE_PATH") ||
      Path.join(:code.priv_dir(:platform), "static/recordings")
  end
end
