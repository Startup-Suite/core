defmodule PlatformWeb.Components.Meeting.RecordingsList do
  @moduledoc """
  Recordings list — per-space list of past recordings.

  Each row shows date, duration, file size, status badge, and action buttons.
  Includes an inline audio player that expands below the selected row.
  """

  use Phoenix.Component

  @doc """
  Renders the recordings list panel.

  ## Assigns
    * `recordings` — list of Recording structs for the space
    * `playing_recording_id` — ID of recording currently being played (or nil)
  """
  attr :recordings, :list, default: []
  attr :playing_recording_id, :string, default: nil

  def recordings_list(assigns) do
    ~H"""
    <div class="space-y-1">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
        Recordings
      </p>

      <div
        :if={@recordings == []}
        class="rounded-xl border border-dashed border-base-300 bg-base-100 px-3 py-4 text-sm text-base-content/50"
      >
        No recordings yet. Start a recording during a meeting to capture audio.
      </div>

      <div :for={recording <- @recordings} class="space-y-0">
        <div class="flex items-center justify-between rounded-lg bg-base-100 px-3 py-2 text-sm hover:bg-base-100/80 transition-colors">
          <div class="flex items-center gap-3 min-w-0">
            <span class={[
              "inline-block size-2 rounded-full flex-shrink-0",
              status_color(recording.status)
            ]}>
            </span>
            <div class="min-w-0">
              <p class="text-xs text-base-content/70">
                {format_date(recording.inserted_at)}
              </p>
              <p class="text-[11px] text-base-content/40 flex items-center gap-2">
                <span :if={recording.duration}>{format_duration(recording.duration)}</span>
                <span :if={recording.file_size}>{format_file_size(recording.file_size)}</span>
                <span class={[
                  "uppercase tracking-wider font-medium",
                  status_text_color(recording.status)
                ]}>
                  {recording.status}
                </span>
              </p>
            </div>
          </div>

          <div :if={recording.status == "ready"} class="flex items-center gap-1">
            <button
              phx-click="play_recording"
              phx-value-recording-id={recording.id}
              class={[
                "rounded px-2 py-0.5 text-[10px] font-medium transition-colors",
                if(@playing_recording_id == recording.id,
                  do: "bg-primary/10 text-primary",
                  else: "bg-base-300 text-base-content/60 hover:text-base-content"
                )
              ]}
            >
              {if @playing_recording_id == recording.id, do: "Close", else: "Play"}
            </button>
            <a
              href={"/api/recordings/#{recording.id}/stream"}
              target="_blank"
              class="rounded px-2 py-0.5 text-[10px] font-medium bg-base-300 text-base-content/60 hover:text-base-content transition-colors"
            >
              Download
            </a>
          </div>
        </div>

        <%!-- Inline player --%>
        <div
          :if={@playing_recording_id == recording.id && recording.status == "ready"}
          id={"recording-player-#{recording.id}"}
          phx-hook="RecordingPlayer"
          data-src={"/api/recordings/#{recording.id}/stream"}
          class="mx-3 mb-2 rounded-lg border border-base-300 bg-base-200/50 p-3"
        >
          <div class="flex items-center gap-3">
            <button
              data-role="play-pause"
              class="flex-shrink-0 rounded-full size-8 flex items-center justify-center bg-primary text-primary-content hover:bg-primary/80 transition-colors"
            >
              <span data-icon="play" class="hero-play-solid size-4"></span>
              <span data-icon="pause" class="hero-pause-solid size-4 hidden"></span>
            </button>

            <div class="flex-1 min-w-0">
              <input
                data-role="seek"
                type="range"
                min="0"
                max="100"
                value="0"
                step="0.1"
                class="range range-xs range-primary w-full"
              />
              <div class="flex justify-between text-[10px] text-base-content/40 mt-0.5">
                <span data-role="current-time">0:00</span>
                <span data-role="total-time">0:00</span>
              </div>
            </div>

            <select
              data-role="speed"
              class="select select-xs bg-base-300 text-[10px] w-16"
            >
              <option value="0.5">0.5x</option>
              <option value="1" selected>1x</option>
              <option value="1.5">1.5x</option>
              <option value="2">2x</option>
            </select>
          </div>

          <div data-role="loading" class="text-center py-2 text-xs text-base-content/40">
            Loading…
          </div>
          <div data-role="error" class="text-center py-2 text-xs text-error hidden">
            Failed to load recording
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %I:%M %p")
  end

  defp format_date(_), do: "Unknown date"

  defp format_duration(nil), do: nil

  defp format_duration(seconds) when is_integer(seconds) do
    minutes = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{minutes}:#{String.pad_leading(Integer.to_string(secs), 2, "0")}"
  end

  defp format_file_size(nil), do: nil

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp status_color("recording"), do: "bg-error animate-pulse"
  defp status_color("processing"), do: "bg-warning"
  defp status_color("ready"), do: "bg-success"
  defp status_color("failed"), do: "bg-error/50"
  defp status_color(_), do: "bg-base-content/20"

  defp status_text_color("recording"), do: "text-error"
  defp status_text_color("processing"), do: "text-warning"
  defp status_text_color("ready"), do: "text-success"
  defp status_text_color("failed"), do: "text-error/70"
  defp status_text_color(_), do: "text-base-content/40"
end
