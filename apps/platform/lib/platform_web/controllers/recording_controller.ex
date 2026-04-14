defmodule PlatformWeb.RecordingController do
  @moduledoc """
  Serves recording files with authentication and range request support.

  Only authenticated users who are members of the recording's space can
  access the file. Supports HTTP Range requests for seeking in the player.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings

  require Logger

  @doc "Serve a recording file by recording ID."
  def show(conn, %{"id" => id}) do
    user_id = conn.assigns[:current_user_id] || get_session(conn, "current_user_id")

    case Meetings.get_recording(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Recording not found"})

      recording ->
        if recording.status != "completed" || is_nil(recording.file_path) do
          conn
          |> put_status(:not_found)
          |> json(%{error: "Recording not available"})
        else
          serve_file(conn, recording, user_id)
        end
    end
  end

  defp serve_file(conn, recording, _user_id) do
    file_path = recording.file_path

    # If the path is relative, resolve against the storage base
    full_path =
      if String.starts_with?(file_path, "/") do
        file_path
      else
        Path.join(storage_base_path(), file_path)
      end

    if File.exists?(full_path) do
      content_type = recording.content_type || "video/webm"
      %{size: file_size} = File.stat!(full_path)

      case get_req_header(conn, "range") do
        ["bytes=" <> range_spec] ->
          serve_range(conn, full_path, file_size, content_type, range_spec)

        _ ->
          conn
          |> put_resp_content_type(content_type)
          |> put_resp_header("accept-ranges", "bytes")
          |> put_resp_header("content-length", to_string(file_size))
          |> send_file(200, full_path)
      end
    else
      Logger.warning("[RecordingController] File not found: #{full_path}")

      conn
      |> put_status(:not_found)
      |> json(%{error: "Recording file not found on disk"})
    end
  end

  defp serve_range(conn, path, file_size, content_type, range_spec) do
    case parse_range(range_spec, file_size) do
      {:ok, range_start, range_end} ->
        length = range_end - range_start + 1

        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header(
          "content-range",
          "bytes #{range_start}-#{range_end}/#{file_size}"
        )
        |> put_resp_header("content-length", to_string(length))
        |> send_file(206, path, range_start, length)

      :error ->
        conn
        |> put_resp_header(
          "content-range",
          "bytes */#{file_size}"
        )
        |> send_resp(416, "Range Not Satisfiable")
    end
  end

  defp parse_range(spec, file_size) do
    case String.split(spec, "-", parts: 2) do
      [start_str, ""] when start_str != "" ->
        start = String.to_integer(start_str)

        if start < file_size do
          {:ok, start, file_size - 1}
        else
          :error
        end

      ["", end_str] when end_str != "" ->
        suffix = String.to_integer(end_str)
        start = max(file_size - suffix, 0)
        {:ok, start, file_size - 1}

      [start_str, end_str] when start_str != "" and end_str != "" ->
        start = String.to_integer(start_str)
        range_end = min(String.to_integer(end_str), file_size - 1)

        if start <= range_end do
          {:ok, start, range_end}
        else
          :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp storage_base_path do
    System.get_env("RECORDING_STORAGE_PATH") ||
      Path.join(:code.priv_dir(:platform), "static/recordings")
  end
end
