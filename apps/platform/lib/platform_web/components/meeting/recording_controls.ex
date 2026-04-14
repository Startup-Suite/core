defmodule PlatformWeb.Components.Meeting.RecordingControls do
  @moduledoc """
  Recording controls — start/stop buttons and active recording indicator.

  Renders a record button for starting recordings, a pulsing red indicator
  when recording is active, and a stop button for the user who started it.
  """

  use Phoenix.Component

  @doc """
  Renders recording controls.

  ## Assigns
    * `recording_active` — whether a recording is currently in progress
    * `can_record` — whether the current user has permission to record
    * `current_user_started` — whether the current user started the active recording
  """
  attr :recording_active, :boolean, default: false
  attr :can_record, :boolean, default: false
  attr :current_user_started, :boolean, default: false

  def recording_controls(assigns) do
    ~H"""
    <div class="flex items-center gap-1">
      <%!-- Record button (when not recording) --%>
      <button
        :if={@can_record && !@recording_active}
        phx-click="start_recording"
        class="flex items-center gap-1 rounded px-2 py-0.5 text-xs text-base-content/50 hover:text-error transition-colors hover:bg-base-300"
        title="Start recording"
      >
        <span class="inline-block size-3 rounded-full border-2 border-current"></span>
        <span class="hidden md:inline">Record</span>
      </button>

      <%!-- Active recording indicator (visible to all) --%>
      <div
        :if={@recording_active}
        class="flex items-center gap-1.5 rounded px-2 py-0.5 text-xs text-error"
      >
        <span class="relative flex size-2.5">
          <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-error opacity-75">
          </span>
          <span class="relative inline-flex size-2.5 rounded-full bg-error"></span>
        </span>
        <span class="font-medium">Recording</span>

        <%!-- Stop button (only for the user who started) --%>
        <button
          :if={@current_user_started}
          phx-click="stop_recording"
          class="ml-1 rounded px-1.5 py-0.5 text-[10px] font-medium bg-error/10 text-error hover:bg-error/20 transition-colors"
          title="Stop recording"
        >
          Stop
        </button>
      </div>
    </div>
    """
  end
end
