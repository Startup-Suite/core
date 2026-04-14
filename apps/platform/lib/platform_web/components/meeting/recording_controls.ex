defmodule PlatformWeb.Meeting.RecordingControls do
  @moduledoc """
  Recording controls for the meeting panel — start/stop button,
  pulsing recording indicator, permission gating.

  Renders inline in the space header meeting controls area.
  """

  use Phoenix.Component

  @doc """
  Renders a compact recording control button for the meeting controls area.

  When recording is inactive, shows a Record button (red circle icon).
  When recording is active, shows a pulsing indicator and Stop button.

  ## Assigns

    * `:recording_active` — boolean, whether a recording is in progress
    * `:can_record` — boolean, whether the current user can start/stop recording
    * `:in_meeting` — boolean, whether the current user is in a meeting
  """
  attr :recording_active, :boolean, default: false
  attr :can_record, :boolean, default: true
  attr :in_meeting, :boolean, default: false

  def recording_button(assigns) do
    ~H"""
    <%= if @in_meeting && @can_record do %>
      <%= if @recording_active do %>
        <button
          phx-click="stop-recording-click"
          class="flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium bg-error/10 text-error hover:bg-error/20 transition-colors"
          title="Stop recording"
        >
          <span class="relative flex items-center">
            <span class="absolute inline-flex size-2 rounded-full bg-error animate-ping opacity-75">
            </span>
            <span class="relative inline-flex size-2 rounded-full bg-error"></span>
          </span>
          <span>REC</span>
          <span class="hero-stop-circle size-3.5"></span>
        </button>
      <% else %>
        <button
          phx-click="start-recording-click"
          class="flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium bg-base-content/5 text-base-content/60 hover:bg-error/10 hover:text-error transition-colors"
          title="Start recording"
        >
          <span class="size-2 rounded-full bg-error/60"></span>
          <span>Record</span>
        </button>
      <% end %>
    <% end %>
    """
  end

  @doc """
  Renders a recording indicator banner shown at the top of the chat area
  when a recording is in progress. Visible to all participants.

  ## Assigns

    * `:recording_active` — boolean, whether a recording is in progress
  """
  attr :recording_active, :boolean, default: false

  def recording_banner(assigns) do
    ~H"""
    <div
      :if={@recording_active}
      class="flex items-center gap-2 bg-error/8 border-b border-error/20 px-4 py-1.5 text-xs"
    >
      <span class="relative flex items-center">
        <span class="absolute inline-flex size-2 rounded-full bg-error animate-ping opacity-75">
        </span>
        <span class="relative inline-flex size-2 rounded-full bg-error"></span>
      </span>
      <span class="font-semibold text-error">Recording in progress</span>
    </div>
    """
  end
end
