defmodule PlatformWeb.RecordingComponents do
  @moduledoc """
  Function components for rendering meeting recordings in the space UI.

  Provides a recordings list and inline playback player.
  """

  use Phoenix.Component

  @doc """
  Renders a list of recordings for a space.

  ## Assigns

    * `:recordings` — list of `%Meetings.Recording{}` structs (preloaded with `:started_by_user`)
    * `:playing_recording_id` — ID of the currently playing recording (nil if none)
  """
  attr :recordings, :list, required: true
  attr :playing_recording_id, :string, default: nil

  def recording_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <div
        :for={recording <- @recordings}
        class="flex items-center gap-3 rounded-lg bg-base-200/50 px-3 py-2 text-sm"
      >
        <div class="flex-shrink-0">
          <span class={[
            "inline-flex items-center justify-center size-8 rounded-full",
            status_bg(recording.status)
          ]}>
            <span class={["size-4", status_icon(recording.status)]}></span>
          </span>
        </div>

        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="font-medium text-base-content truncate">
              {format_recording_date(recording.started_at)}
            </span>
            <span class={[
              "inline-flex items-center rounded-full px-1.5 py-0.5 text-[0.65rem] font-medium",
              status_badge(recording.status)
            ]}>
              {recording.status}
            </span>
          </div>
          <div class="flex items-center gap-2 text-xs text-base-content/60">
            <span :if={recording.duration_seconds}>
              {format_duration(recording.duration_seconds)}
            </span>
            <span :if={recording.file_size}>
              · {format_file_size(recording.file_size)}
            </span>
            <span :if={recording.started_by_user}>
              · {recording.started_by_user.name || recording.started_by_user.email}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-1 flex-shrink-0">
          <%= if recording.status == "completed" && recording.file_path do %>
            <%= if @playing_recording_id == recording.id do %>
              <button
                phx-click="stop-playback"
                phx-value-recording-id={recording.id}
                class="rounded-full p-1.5 bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
                title="Stop playback"
              >
                <span class="size-4 hero-stop-solid"></span>
              </button>
            <% else %>
              <button
                phx-click="play-recording"
                phx-value-recording-id={recording.id}
                class="rounded-full p-1.5 bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
                title="Play recording"
              >
                <span class="size-4 hero-play-solid"></span>
              </button>
            <% end %>

            <a
              href={"/recordings/#{recording.id}"}
              download
              class="rounded-full p-1.5 bg-base-300 text-base-content/60 hover:bg-base-content/20 transition-colors"
              title="Download recording"
            >
              <span class="size-4 hero-arrow-down-tray"></span>
            </a>
          <% end %>
        </div>
      </div>

      <div
        :if={@recordings == []}
        class="text-center py-6 text-sm text-base-content/40"
      >
        No recordings yet
      </div>
    </div>
    """
  end

  @doc """
  Renders an inline video/audio player for a recording.

  ## Assigns

    * `:recording` — the `%Meetings.Recording{}` to play
  """
  attr :recording, :map, required: true

  def recording_player(assigns) do
    ~H"""
    <div
      id={"recording-player-#{@recording.id}"}
      phx-hook="RecordingPlayer"
      class="rounded-lg overflow-hidden bg-base-300/50 border border-base-300"
    >
      <video
        data-media
        autoplay
        class="w-full max-h-64"
        src={"/recordings/#{@recording.id}"}
        type={@recording.content_type || "video/webm"}
      >
        Your browser does not support video playback.
      </video>

      <div class="hidden text-center py-4 text-sm text-error/80" data-error>
        Failed to load recording
      </div>

      <div class="px-3 py-2 flex items-center gap-3 text-xs text-base-content/60">
        <button
          data-play-btn
          class="rounded-full p-1.5 bg-primary/10 text-primary hover:bg-primary/20 transition-colors"
          title="Play/Pause"
        >
          <span class="size-4 hero-play-solid"></span>
        </button>

        <span data-current-time>0:00</span>

        <input
          data-seek
          type="range"
          min="0"
          max="100"
          value="0"
          class="flex-1 h-1 accent-primary cursor-pointer"
        />

        <span data-duration>
          {if @recording.duration_seconds,
            do: format_duration(@recording.duration_seconds),
            else: "--:--"}
        </span>

        <button
          data-speed-btn
          class="rounded px-1.5 py-0.5 text-[0.65rem] font-semibold bg-base-300 hover:bg-base-content/10 transition-colors"
          title="Playback speed"
        >
          1x
        </button>
      </div>

      <div class="px-3 pb-1.5 text-xs text-base-content/40">
        {format_recording_date(@recording.started_at)}
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp format_duration(nil), do: ""

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    if hours > 0 do
      "#{hours}:#{String.pad_leading(to_string(minutes), 2, "0")}:#{String.pad_leading(to_string(secs), 2, "0")}"
    else
      "#{minutes}:#{String.pad_leading(to_string(secs), 2, "0")}"
    end
  end

  defp format_file_size(nil), do: ""

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_recording_date(nil), do: ""

  defp format_recording_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y %I:%M %p")
  end

  defp status_icon("completed"), do: "hero-check-circle-solid"
  defp status_icon("failed"), do: "hero-x-circle-solid"
  defp status_icon("active"), do: "hero-stop-circle-solid"
  defp status_icon("processing"), do: "hero-arrow-path"
  defp status_icon(_), do: "hero-ellipsis-horizontal"

  defp status_bg("completed"), do: "bg-success/10 text-success"
  defp status_bg("failed"), do: "bg-error/10 text-error"
  defp status_bg("active"), do: "bg-error/10 text-error"
  defp status_bg("processing"), do: "bg-warning/10 text-warning"
  defp status_bg(_), do: "bg-base-300 text-base-content/50"

  defp status_badge("completed"), do: "bg-success/10 text-success"
  defp status_badge("failed"), do: "bg-error/10 text-error"
  defp status_badge("active"), do: "bg-error/10 text-error"
  defp status_badge("processing"), do: "bg-warning/10 text-warning"
  defp status_badge(_), do: "bg-base-300 text-base-content/50"
end
