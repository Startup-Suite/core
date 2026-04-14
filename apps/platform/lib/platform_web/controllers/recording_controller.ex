defmodule PlatformWeb.RecordingController do
  @moduledoc """
  Controller for streaming/redirecting to meeting recording files.

  Recording files are stored externally by LiveKit Egress. This controller
  looks up the recording, verifies it's ready, and redirects to the file URL.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings

  @doc """
  Stream or redirect to a recording file.

  Returns 404 if the recording doesn't exist, 422 if it's not ready yet.
  """
  def show(conn, %{"id" => id}) do
    case Meetings.get_recording(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Recording not found"})

      %{status: status} when status in ["recording", "processing"] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Recording is still #{status}"})

      %{status: "failed"} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Recording failed"})

      %{file_url: nil} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Recording file not available"})

      %{file_url: file_url} ->
        conn
        |> redirect(external: file_url)
    end
  end
end
