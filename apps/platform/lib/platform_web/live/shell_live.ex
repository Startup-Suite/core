defmodule PlatformWeb.ShellLive do
  @moduledoc "Mount hook that injects shell assigns for all authenticated surfaces."

  import Ecto.Query
  import Phoenix.Component
  import Phoenix.LiveView

  alias Platform.Accounts
  alias Platform.Agents.{Agent, AgentServer, WorkspaceBootstrap}
  alias Platform.Chat
  alias Platform.Chat.Presence, as: ChatPresence
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.SpaceAgentPresence
  alias Platform.Meetings
  alias Platform.Repo

  def on_mount(:default, _params, session, socket) do
    current_user =
      case session["current_user_id"] do
        user_id when is_binary(user_id) ->
          case Accounts.get_user(user_id) do
            %{name: name} when is_binary(name) and name != "" -> name
            %{email: email} when is_binary(email) -> email
            _ -> user_id
          end

        _ ->
          session["user_email"] || session["user_id"] || "user"
      end

    active_module = derive_active_module(socket.view)

    # Load the default space roster eagerly so the status dot renders on mount
    {roster_space_id, roster_socket} = load_default_roster(socket)

    # Subscribe to live roster updates when connected
    if connected?(socket) && roster_space_id do
      Phoenix.PubSub.subscribe(Platform.PubSub, "space_agents:#{roster_space_id}")
      ChatPubSub.subscribe(roster_space_id)
    end

    presence_list = if roster_space_id, do: build_presence_list(roster_space_id), else: []

    socket =
      roster_socket
      |> assign(:current_user, current_user)
      |> assign(:current_path, "/")
      |> assign(:agent_status, default_agent_status())
      |> assign(:drawer_open, false)
      |> assign(:sidebar_collapsed, false)
      |> assign(:active_module, active_module)
      |> assign(:roster_open, false)
      |> assign(:roster_space_id, roster_space_id)
      |> assign(:show_presence_panel, false)
      |> assign(:presence_list, presence_list)
      # Meeting bar state
      |> assign(:in_meeting, false)
      |> assign(:meeting_room_name, nil)
      |> assign(:meeting_space_slug, nil)
      |> assign(:meeting_space_name, nil)
      |> assign(:meeting_mic_enabled, true)
      |> assign(:meeting_camera_enabled, false)
      |> attach_hook(:track_path, :handle_params, fn _params, url, socket ->
        uri = URI.parse(url)
        {:cont, assign(socket, :current_path, uri.path)}
      end)
      |> attach_hook(:roster_updates, :handle_info, fn
        {:roster_changed, space_id}, socket ->
          {:halt, refresh_roster(socket, space_id)}

        %Phoenix.Socket.Broadcast{event: "presence_diff"}, socket ->
          list =
            try do
              if sid = socket.assigns[:roster_space_id] do
                build_presence_list(sid)
              else
                []
              end
            rescue
              _ -> socket.assigns[:presence_list] || []
            end

          {:halt, assign(socket, :presence_list, list)}

        _msg, socket ->
          {:cont, socket}
      end)
      |> attach_hook(:drawer_events, :handle_event, fn
        "toggle_drawer", _params, socket ->
          {:halt, assign(socket, :drawer_open, !socket.assigns.drawer_open)}

        "close_drawer", _params, socket ->
          {:halt, assign(socket, :drawer_open, false)}

        "toggle_sidebar", _params, socket ->
          {:halt, assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)}

        "toggle_presence_panel", _params, socket ->
          {:halt, assign(socket, :show_presence_panel, !socket.assigns.show_presence_panel)}

        "toggle_roster", _params, socket ->
          {:halt, assign(socket, :roster_open, !socket.assigns.roster_open)}

        "close_roster", _params, socket ->
          {:halt, assign(socket, :roster_open, false)}

        "dismiss_agent", %{"agent-id" => agent_id, "space-id" => space_id}, socket ->
          # ADR 0027: dismissed role removed — just remove the agent from roster
          Platform.Chat.remove_space_agent(space_id, agent_id)
          {:halt, refresh_roster(socket, space_id)}

        # ── Meeting bar events (from MeetingRoom JS hook) ──────────────

        "meeting-joined", %{"room_name" => room_name, "space_slug" => space_slug}, socket ->
          space_name = resolve_space_name(space_slug)

          socket =
            socket
            |> assign(:in_meeting, true)
            |> assign(:meeting_room_name, room_name)
            |> assign(:meeting_space_slug, space_slug)
            |> assign(:meeting_space_name, space_name)
            |> assign(:meeting_mic_enabled, true)
            |> assign(:meeting_camera_enabled, false)

          {:halt, socket}

        "meeting-left", _params, socket ->
          {:halt, clear_meeting_state(socket)}

        "meeting-disconnected", _params, socket ->
          {:halt, clear_meeting_state(socket)}

        "meeting-mic-toggled", %{"enabled" => enabled}, socket ->
          {:halt, assign(socket, :meeting_mic_enabled, enabled)}

        "meeting-camera-toggled", %{"enabled" => enabled}, socket ->
          {:halt, assign(socket, :meeting_camera_enabled, enabled)}

        "meeting-error", %{"message" => message}, socket ->
          require Logger
          Logger.warning("[MeetingBar] Meeting error: #{message}")
          {:halt, clear_meeting_state(socket)}

        "leave-meeting-click", _params, socket ->
          {:halt, push_event(socket, "leave-meeting", %{})}

        "toggle-meeting-mic", _params, socket ->
          {:halt, push_event(socket, "toggle-mic", %{})}

        "toggle-meeting-camera", _params, socket ->
          {:halt, push_event(socket, "toggle-camera", %{})}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  def default_agent_status do
    # Use non-blocking status() to avoid blocking mount
    status = WorkspaceBootstrap.status()

    result =
      case status do
        %{reachable?: true} -> :online
        %{configured?: true} -> :offline
        _ -> fallback_default_agent_status()
      end

    # Boot the runtime asynchronously if not already running
    unless status.reachable? do
      Task.start(fn -> WorkspaceBootstrap.boot() end)
    end

    result
  end

  defp fallback_default_agent_status do
    case default_persisted_agent() do
      %Agent{} = agent ->
        case AgentServer.start_agent(agent) do
          {:ok, pid} when is_pid(pid) ->
            :online

          {:error, _reason} ->
            if agent.status == "paused", do: :paused, else: :offline
        end

      nil ->
        :unknown
    end
  end

  defp default_persisted_agent do
    from(a in Agent,
      where: a.slug == "main" and a.status != "archived",
      limit: 1
    )
    |> Repo.one()
  rescue
    _ -> nil
  end

  @doc false
  def refresh_roster(socket, space_id) when is_binary(space_id) do
    roster_items = SpaceAgentPresence.roster_with_status(space_id)

    principal =
      Enum.find(roster_items, fn {sa, _status} -> sa.role == "principal" end)

    principal_name =
      case principal do
        {sa, _} -> sa.agent.name
        nil -> nil
      end

    active_statuses =
      roster_items
      |> Enum.reject(fn {sa, _} -> sa.role == "dismissed" end)
      |> Enum.map(fn {_sa, status} -> status end)

    composite = SpaceAgentPresence.composite_status(active_statuses)

    socket
    |> assign(:roster_items, roster_items)
    |> assign(:principal_name, principal_name)
    |> assign(:composite_status, composite)
  end

  def refresh_roster(socket, _), do: socket

  defp load_default_roster(socket) do
    case first_space() do
      %{id: space_id} ->
        socket =
          socket
          |> assign(:roster_items, [])
          |> assign(:composite_status, :none)
          |> assign(:principal_name, nil)
          |> refresh_roster(space_id)

        {space_id, socket}

      nil ->
        socket =
          socket
          |> assign(:roster_items, [])
          |> assign(:composite_status, :none)
          |> assign(:principal_name, nil)

        {nil, socket}
    end
  end

  defp build_presence_list(space_id) do
    online_ids =
      space_id
      |> ChatPresence.list_space()
      |> Map.keys()
      |> MapSet.new()

    space_id
    |> Chat.list_participants()
    |> Enum.filter(&(&1.participant_type == "user"))
    |> Enum.map(fn p ->
      %{name: p.display_name || "User", online: MapSet.member?(online_ids, p.participant_id)}
    end)
    |> Enum.sort_by(& &1.name)
  rescue
    _ -> []
  end

  defp first_space do
    from(s in Platform.Chat.Space,
      where: is_nil(s.archived_at),
      order_by: [asc: s.inserted_at],
      limit: 1
    )
    |> Repo.one()
  rescue
    _ -> nil
  end

  # Derive a human-readable module name from the LiveView module atom.
  defp derive_active_module(view) do
    case view do
      PlatformWeb.ChatLive ->
        "Chat"

      PlatformWeb.ControlCenterLive ->
        "Agent Resources"

      PlatformWeb.TasksLive ->
        "Tasks"

      PlatformWeb.SkillsLive ->
        "Skills"

      PlatformWeb.ChangelogLive ->
        "Changelog"

      PlatformWeb.UsageLive ->
        "Usage"

      PlatformWeb.AdminPromptsLive ->
        "Admin"

      PlatformWeb.AdminFederationLive ->
        "Admin"

      _ ->
        view
        |> Module.split()
        |> List.last()
        |> String.replace("Live", "")
        |> String.replace("_", " ")
    end
  end

  # ── Meeting helpers ──────────────────────────────────────────────────────────────

  defp clear_meeting_state(socket) do
    socket
    |> assign(:in_meeting, false)
    |> assign(:meeting_room_name, nil)
    |> assign(:meeting_space_slug, nil)
    |> assign(:meeting_space_name, nil)
    |> assign(:meeting_mic_enabled, true)
    |> assign(:meeting_camera_enabled, false)
  end

  defp resolve_space_name(slug) when is_binary(slug) do
    case Repo.get_by(Platform.Chat.Space, slug: slug) do
      %{name: name} when is_binary(name) -> name
      _ -> slug
    end
  rescue
    _ -> slug
  end

  defp resolve_space_name(_), do: "Meeting"
end
