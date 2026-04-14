defmodule PlatformWeb.Components.Meeting.TranscriptView do
  @moduledoc """
  Post-meeting transcript + summary view.

  Displays the LLM-generated summary prominently, then the full transcript
  with speaker-attributed segments grouped by speaker.
  """

  use Phoenix.Component

  @speaker_colors [
    "text-cyan-400",
    "text-violet-400",
    "text-amber-400",
    "text-emerald-400",
    "text-rose-400",
    "text-sky-400",
    "text-orange-400",
    "text-teal-400",
    "text-pink-400",
    "text-lime-400"
  ]

  @doc """
  Renders the transcript view panel.

  ## Assigns
    * `transcript` — Transcript struct with segments and summary
    * `show_transcript` — whether the panel is visible
  """
  attr :transcript, :map, required: true
  attr :show_transcript, :boolean, default: true

  def transcript_view(assigns) do
    assigns =
      assign(assigns, :grouped_segments, group_segments(assigns.transcript.segments || []))

    ~H"""
    <div :if={@show_transcript && @transcript} class="space-y-4">
      <%!-- Header --%>
      <div class="flex items-center justify-between">
        <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Meeting Transcript
        </p>
        <div class="flex items-center gap-2">
          <a
            :if={@transcript.status == "complete"}
            href={"/api/transcripts/#{@transcript.id}/download"}
            class="rounded px-2 py-0.5 text-[10px] font-medium bg-base-300 text-base-content/60 hover:text-base-content transition-colors"
          >
            Download
          </a>
          <button
            phx-click="close_transcript"
            class="rounded px-2 py-0.5 text-[10px] font-medium bg-base-300 text-base-content/60 hover:text-base-content transition-colors"
          >
            Close
          </button>
        </div>
      </div>

      <%!-- Status: processing --%>
      <div
        :if={@transcript.status == "processing"}
        class="flex items-center gap-2 rounded-xl border border-warning/20 bg-warning/5 px-4 py-3"
      >
        <span class="loading loading-spinner loading-sm text-warning"></span>
        <span class="text-sm text-warning">Generating summary…</span>
      </div>

      <%!-- Status: failed --%>
      <div
        :if={@transcript.status == "failed"}
        class="flex items-center gap-2 rounded-xl border border-error/20 bg-error/5 px-4 py-3"
      >
        <span class="hero-exclamation-triangle size-4 text-error"></span>
        <span class="text-sm text-error">Summary generation failed</span>
      </div>

      <%!-- Summary card --%>
      <div
        :if={@transcript.summary}
        class="rounded-xl border border-primary/20 bg-primary/5 px-4 py-3"
      >
        <p class="text-[10px] font-semibold uppercase tracking-widest text-primary/60 mb-2">
          Summary
        </p>
        <div class="text-sm text-base-content/80 leading-relaxed whitespace-pre-wrap">
          {@transcript.summary}
        </div>
      </div>

      <%!-- Full transcript --%>
      <div :if={@grouped_segments != []} class="space-y-1">
        <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/40 mb-2">
          Full Transcript
        </p>
        <div class="max-h-96 overflow-y-auto space-y-2 pr-1">
          <div :for={group <- @grouped_segments} class="space-y-0.5">
            <div class="flex items-baseline gap-2">
              <span class={"text-xs font-semibold #{speaker_color(group.speaker)}"}>
                {group.speaker}
              </span>
              <span class="text-[10px] text-base-content/30">
                {format_timestamp(group.start_time)}
              </span>
            </div>
            <div
              :for={seg <- group.segments}
              class="pl-0 text-sm text-base-content/70 leading-relaxed"
            >
              {seg["text"]}
            </div>
          </div>
        </div>
      </div>

      <div
        :if={(@transcript.segments || []) == [] && @transcript.status == "complete"}
        class="rounded-xl border border-dashed border-base-300 bg-base-100 px-3 py-4 text-sm text-base-content/50"
      >
        No transcript segments recorded.
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp group_segments(segments) when is_list(segments) do
    segments
    |> Enum.chunk_while(
      nil,
      fn seg, acc ->
        speaker = seg["speaker_name"] || seg["participant_identity"] || "Unknown"

        case acc do
          nil ->
            {:cont, %{speaker: speaker, start_time: seg["start_time"], segments: [seg]}}

          %{speaker: ^speaker} = group ->
            {:cont, %{group | segments: group.segments ++ [seg]}}

          group ->
            {:cont, group, %{speaker: speaker, start_time: seg["start_time"], segments: [seg]}}
        end
      end,
      fn
        nil -> {:cont, []}
        group -> {:cont, group, nil}
      end
    )
  end

  defp group_segments(_), do: []

  defp speaker_color(speaker) when is_binary(speaker) do
    index = :erlang.phash2(speaker, length(@speaker_colors))
    Enum.at(@speaker_colors, index)
  end

  defp speaker_color(_), do: hd(@speaker_colors)

  defp format_timestamp(nil), do: ""

  defp format_timestamp(ms) when is_number(ms) do
    total_seconds = div(trunc(ms), 1000)
    hours = div(total_seconds, 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    if hours > 0 do
      :io_lib.format("~2..0B:~2..0B:~2..0B", [hours, minutes, seconds])
      |> IO.iodata_to_binary()
    else
      :io_lib.format("~B:~2..0B", [minutes, seconds])
      |> IO.iodata_to_binary()
    end
  end

  defp format_timestamp(_), do: ""
end
