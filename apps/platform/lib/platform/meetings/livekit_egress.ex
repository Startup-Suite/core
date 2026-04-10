defmodule Platform.Meetings.LivekitEgress do
  @moduledoc """
  HTTP client for the LiveKit Egress API.

  Uses the LiveKit server-side REST API to start and stop room composite
  egress recordings. Authenticates via HS256 JWT signed with the API secret.

  Requires:
  - `LIVEKIT_URL` — LiveKit server URL (e.g. `wss://lk.example.com`)
  - `LIVEKIT_API_KEY` — API key for JWT signing
  - `LIVEKIT_API_SECRET` — API secret for JWT signing

  Storage is configured via `RECORDING_STORAGE_PATH` env var, defaulting
  to a local file path. The Egress service must have write access to this path.
  """

  require Logger

  @default_storage_path "/recordings"

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Start a room composite egress recording.

  Calls `POST /twirp/livekit.Egress/StartRoomCompositeEgress` with a file
  output configuration. Returns `{:ok, egress_info}` or `{:error, reason}`.
  """
  @spec start_room_composite(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_room_composite(room_name, opts \\ []) do
    format = Keyword.get(opts, :format, "mp4")
    storage_path = storage_path()

    body = %{
      "room_name" => room_name,
      "file" => %{
        "file_type" => file_type_for(format),
        "filepath" => "#{storage_path}/#{room_name}-#{timestamp_suffix()}.#{format}"
      },
      "audio_only" => Keyword.get(opts, :audio_only, false)
    }

    post("/twirp/livekit.Egress/StartRoomCompositeEgress", body)
  end

  @doc """
  Stop an active egress by its ID.

  Calls `POST /twirp/livekit.Egress/StopEgress`.
  Returns `{:ok, egress_info}` or `{:error, reason}`.
  """
  @spec stop_egress(String.t()) :: {:ok, map()} | {:error, term()}
  def stop_egress(egress_id) do
    post("/twirp/livekit.Egress/StopEgress", %{"egress_id" => egress_id})
  end

  @doc """
  List active egresses for a room.

  Calls `POST /twirp/livekit.Egress/ListEgress`.
  Returns `{:ok, %{\"items\" => [...]}}` or `{:error, reason}`.
  """
  @spec list_egress(String.t()) :: {:ok, map()} | {:error, term()}
  def list_egress(room_name) do
    post("/twirp/livekit.Egress/ListEgress", %{"room_name" => room_name})
  end

  # ── HTTP helpers ─────────────────────────────────────────────────────────

  defp post(path, body) do
    url = http_url() <> path

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{generate_api_token()}"}
    ]

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers_to_charlist(headers), ~c"application/json",
            Jason.encode!(body)},
           [{:ssl, ssl_opts()}],
           []
         ) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status in 200..299 ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:ok, %{"raw" => to_string(resp_body)}}
        end

      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        Logger.warning("[LivekitEgress] API error #{status}: #{to_string(resp_body)}")

        {:error, {:api_error, status, to_string(resp_body)}}

      {:error, reason} ->
        Logger.error("[LivekitEgress] HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  # ── Configuration ────────────────────────────────────────────────────────

  defp http_url do
    livekit_url = System.get_env("LIVEKIT_URL") || ""

    # Convert wss:// to https:// and ws:// to http://
    livekit_url
    |> String.replace(~r{^wss://}, "https://")
    |> String.replace(~r{^ws://}, "http://")
  end

  defp storage_path do
    System.get_env("RECORDING_STORAGE_PATH") || @default_storage_path
  end

  defp ssl_opts do
    [verify: :verify_none]
  end

  defp headers_to_charlist(headers) do
    Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end

  # ── JWT token generation ─────────────────────────────────────────────────

  defp generate_api_token do
    api_key = System.get_env("LIVEKIT_API_KEY")
    api_secret = System.get_env("LIVEKIT_API_SECRET")

    now = System.system_time(:second)

    claims = %{
      "iss" => api_key,
      "sub" => api_key,
      "nbf" => now,
      "exp" => now + 60,
      "jti" => Ecto.UUID.generate(),
      "video" => %{
        "roomRecord" => true
      }
    }

    encode_jwt(claims, api_secret)
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

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp file_type_for("mp4"), do: "MP4"
  defp file_type_for("ogg"), do: "OGG"
  defp file_type_for(_), do: "MP4"

  defp timestamp_suffix do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end
end
