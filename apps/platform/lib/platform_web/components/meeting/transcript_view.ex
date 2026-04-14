defmodule PlatformWeb.Components.Meeting.TranscriptView do
  @moduledoc """
  Component for viewing meeting transcripts and LLM-generated summaries.

  Renders:
  - Summary section at the top (styled card)
  - Full transcript with speaker-attributed, timestamped segments
  - Download link
  - Status indicators (processing, failed)
  """

  use Phoenix.Component

  @doc """
  Render a full transcript view with summary and segments.

  ## Assigns
  - `transcript` — `%Platform.Meetings.Transcript{}` struct
  - `on_close` — event name to close the panel (optional)
  """
  attr :transcript, :map, required: true
  attr :on_close, :string, default: nil

  def transcript_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-hidden">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-300">
        <div class="flex items-center gap-2">
          <span class="hero-document-text-solid size-5 text-primary"></span>
          <h3 class="text-sm font-semibold">Meeting Transcript</h3>
          <span class={[
            "badge badge-xs",
            status_badge_class(@transcript.status)
          ]}>
            {@transcript.status}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <a
            href={"/api/transcripts/#{@transcript.id}/download"}
            class="btn btn-ghost btn-xs gap-1"
            download
          >
            <span class="hero-arrow-down-tray size-3.5"></span> Download
          </a>
          <button
            :if={@on_close}
            phx-click={@on_close}
            class="text-base-content/40 hover:text-base-content transition-colors"
          >
            <span class="hero-x-mark size-4"></span>
          </button>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%!-- Processing state --%>
        <div :if={@transcript.status == "processing"} class="px-4 py-8 text-center">
          <span class="loading loading-spinner loading-md text-primary"></span>
          <p class="mt-2 text-sm text-base-content/50">Generating summary...</p>
        </div>

        <%!-- Failed state --%>
        <div :if={@transcript.status == "failed"} class="px-4 py-8 text-center">
          <span class="hero-exclamation-triangle size-8 text-error/60"></span>
          <p class="mt-2 text-sm text-error/80">Transcript processing failed</p>
        </div>

        <%!-- Summary --%>
        <div
          :if={@transcript.summary && @transcript.summary != ""}
          class="p-4 border-b border-base-300"
        >
          <div class="rounded-lg bg-primary/5 border border-primary/10 p-4">
            <div class="flex items-center gap-2 mb-2">
              <span class="hero-sparkles-solid size-4 text-primary"></span>
              <span class="text-xs font-semibold uppercase tracking-wider text-primary">
                Summary
              </span>
            </div>
            <div class="text-sm text-base-content/80 leading-relaxed whitespace-pre-wrap">
              {@transcript.summary}
            </div>
          </div>
        </div>

        <%!-- Segments --%>
        <div :if={@transcript.segments && @transcript.segments != []} class="p-4 space-y-1">
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/40 mb-3">
            Full Transcript
          </p>
          <%= for {segment, _idx} <- Enum.with_index(@transcript.segments) do %>
            <.transcript_segment segment={segment} />
          <% end %>
        </div>

        <%!-- Empty state --%>
        <div
          :if={
            (@transcript.segments == nil || @transcript.segments == []) &&
              @transcript.status == "complete"
          }
          class="px-4 py-8 text-center"
        >
          <p class="text-sm text-base-content/40">No transcript segments recorded</p>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Render a single transcript segment with speaker label and timestamp.
  """
  attr :segment, :map, required: true

  def transcript_segment(assigns) do
    ~H"""
    <div class="flex gap-3 py-1.5 group">
      <div class="shrink-0 w-16 text-right">
        <span class="text-[0.65rem] text-base-content/30 tabular-nums group-hover:text-base-content/50 transition-colors">
          {format_segment_time(@segment["start_time"])}
        </span>
      </div>
      <div class="min-w-0 flex-1">
        <span class={[
          "text-xs font-semibold mr-1.5",
          speaker_color(@segment["speaker_name"] || @segment["participant_identity"])
        ]}>
          {display_speaker(@segment)}
        </span>
        <span class="text-sm text-base-content/80">
          {@segment["text"]}
        </span>
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp format_segment_time(nil), do: "0:00"

  defp format_segment_time(ms) when is_number(ms) do
    total_seconds = div(trunc(ms), 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    if hours > 0 do
      "#{hours}:#{pad(minutes)}:#{pad(seconds)}"
    else
      "#{minutes}:#{pad(seconds)}"
    end
  end

  defp format_segment_time(_), do: "0:00"

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  defp display_speaker(segment) do
    segment["speaker_name"] || segment["participant_identity"] || "Unknown"
  end

  defp speaker_color(nil), do: "text-base-content/60"

  defp speaker_color(name) when is_binary(name) do
    colors = [
      "text-primary",
      "text-secondary",
      "text-accent",
      "text-info",
      "text-success",
      "text-warning"
    ]

    index = :erlang.phash2(name, length(colors))
    Enum.at(colors, index)
  end

  defp status_badge_class("complete"), do: "badge-success"
  defp status_badge_class("processing"), do: "badge-warning"
  defp status_badge_class("recording"), do: "badge-info"
  defp status_badge_class("failed"), do: "badge-error"
  defp status_badge_class(_), do: "badge-ghost"
end
