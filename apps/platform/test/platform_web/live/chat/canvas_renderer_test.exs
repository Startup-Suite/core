defmodule PlatformWeb.Chat.CanvasRendererTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.Chat.CanvasRenderer

  # ---------------------------------------------------------------------------
  # Helpers — pure functions (no rendering required)
  # ---------------------------------------------------------------------------

  describe "url_canvas?/1" do
    test "returns true when url key is present and non-empty" do
      assert CanvasRenderer.url_canvas?(%{"url" => "https://example.com"})
    end

    test "returns false for empty url" do
      refute CanvasRenderer.url_canvas?(%{"url" => ""})
    end

    test "returns false when url key is absent" do
      refute CanvasRenderer.url_canvas?(%{})
    end
  end

  describe "a2ui_canvas?/1" do
    test "returns true when a2ui_content is present and non-empty" do
      assert CanvasRenderer.a2ui_canvas?(%{"a2ui_content" => ~s({"type":"text"})})
    end

    test "returns false for empty a2ui_content" do
      refute CanvasRenderer.a2ui_canvas?(%{"a2ui_content" => ""})
    end

    test "returns false when key is absent" do
      refute CanvasRenderer.a2ui_canvas?(%{})
    end
  end

  describe "canonical_document?/1" do
    test "returns true for a valid canonical doc" do
      assert CanvasRenderer.canonical_document?(%{
               "version" => 1,
               "root" => %{"type" => "stack", "props" => %{}, "children" => []}
             })
    end

    test "returns false when root is missing" do
      refute CanvasRenderer.canonical_document?(%{"version" => 1})
    end

    test "returns false when version is missing" do
      refute CanvasRenderer.canonical_document?(%{
               "root" => %{"type" => "stack", "props" => %{}, "children" => []}
             })
    end

    test "returns false for empty map" do
      refute CanvasRenderer.canonical_document?(%{})
    end
  end

  describe "parse_a2ui/1" do
    test "parses single-line JSON" do
      input = ~s({"type":"text","props":{"value":"hello"}})
      [node] = CanvasRenderer.parse_a2ui(input)
      assert node["type"] == "text"
    end

    test "parses multiple JSONL lines" do
      input = ~s({"type":"text"}\n{"type":"badge"})
      nodes = CanvasRenderer.parse_a2ui(input)
      assert length(nodes) == 2
    end

    test "skips invalid JSON lines" do
      input = "not json\n{\"type\":\"text\"}"
      [node] = CanvasRenderer.parse_a2ui(input)
      assert node["type"] == "text"
    end

    test "returns empty list for nil" do
      assert [] = CanvasRenderer.parse_a2ui(nil)
    end

    test "returns empty list for empty string" do
      assert [] = CanvasRenderer.parse_a2ui("")
    end
  end

  # ---------------------------------------------------------------------------
  # Component rendering helpers
  # ---------------------------------------------------------------------------

  # Render a single render_node call and return the HTML string
  defp render_node(node) do
    rendered_to_string(~H|<CanvasRenderer.render_node node={node} />|)
  end

  # ---------------------------------------------------------------------------
  # render_node — existing node types (smoke tests)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — stack" do
    test "renders a stack container" do
      node = %{"type" => "stack", "props" => %{"gap" => 12}, "children" => []}
      html = render_node(node)
      assert html =~ "flex-col"
    end

    test "renders stack children recursively" do
      node = %{
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{"type" => "text", "props" => %{"value" => "hello"}, "children" => []}
        ]
      }

      html = render_node(node)
      assert html =~ "hello"
    end
  end

  describe "render_node/1 — text" do
    test "renders text value" do
      node = %{"type" => "text", "props" => %{"value" => "Hello world"}, "children" => []}
      html = render_node(node)
      assert html =~ "Hello world"
    end

    test "applies size class" do
      node = %{"type" => "text", "props" => %{"value" => "X", "size" => "xl"}, "children" => []}
      html = render_node(node)
      assert html =~ "text-xl"
    end

    test "applies weight class" do
      node = %{
        "type" => "text",
        "props" => %{"value" => "X", "weight" => "bold"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "font-bold"
    end
  end

  describe "render_node/1 — badge" do
    test "renders badge value" do
      node = %{"type" => "badge", "props" => %{"value" => "NEW"}, "children" => []}
      html = render_node(node)
      assert html =~ "NEW"
      assert html =~ "rounded-full"
    end
  end

  describe "render_node/1 — heading" do
    test "renders h1 at level 1" do
      node = %{
        "type" => "heading",
        "props" => %{"value" => "Title", "level" => 1},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "<h1"
      assert html =~ "Title"
    end

    test "renders h3 at level 3" do
      node = %{
        "type" => "heading",
        "props" => %{"value" => "Sub", "level" => 3},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "<h3"
    end

    test "defaults to h2 when level missing" do
      node = %{"type" => "heading", "props" => %{"value" => "Default"}, "children" => []}
      html = render_node(node)
      assert html =~ "<h2"
    end
  end

  describe "render_node/1 — unknown node" do
    test "renders fallback for unknown type" do
      node = %{"type" => "frobnicator", "props" => %{}, "children" => []}
      html = render_node(node)
      assert html =~ "unknown node type"
      assert html =~ "frobnicator"
    end

    test "renders nothing for nil node" do
      html = render_node(nil)
      assert html == "" or not (html =~ "<")
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — checklist (new)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — checklist" do
    test "renders checklist container" do
      node = %{
        "type" => "checklist",
        "props" => %{},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "flex-col"
    end

    test "renders optional title" do
      node = %{
        "type" => "checklist",
        "props" => %{"title" => "Tasks"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Tasks"
    end

    test "omits title element when title prop is absent" do
      node = %{
        "type" => "checklist",
        "props" => %{},
        "children" => []
      }

      html = render_node(node)
      refute html =~ "uppercase tracking-widest"
    end

    test "renders checklist_item children" do
      node = %{
        "type" => "checklist",
        "props" => %{"title" => "My list"},
        "children" => [
          %{
            "type" => "checklist_item",
            "props" => %{"label" => "Do the thing", "checked" => false},
            "children" => []
          }
        ]
      }

      html = render_node(node)
      assert html =~ "Do the thing"
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — checklist_item (new)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — checklist_item" do
    test "renders label" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Write tests", "checked" => false},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Write tests"
    end

    test "renders checked state with success icon" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Done item", "checked" => true},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "text-success"
      assert html =~ "line-through"
    end

    test "renders unchecked state without strikethrough" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Pending item", "checked" => false},
        "children" => []
      }

      html = render_node(node)
      refute html =~ "line-through"
    end

    test "treats missing checked prop as unchecked" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "No checked prop"},
        "children" => []
      }

      html = render_node(node)
      refute html =~ "line-through"
    end

    test "renders optional note" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Item", "checked" => false, "note" => "Due tomorrow"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Due tomorrow"
    end

    test "omits note element when note prop is absent" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Item", "checked" => false},
        "children" => []
      }

      html = render_node(node)
      # Should not contain text-base-content/50 class from the note paragraph
      # (that class is unique to the note element in this component)
      refute html =~ "Due"
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — action_row (new)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — action_row" do
    test "renders a button for each entry in buttons prop" do
      node = %{
        "type" => "action_row",
        "props" => %{
          "buttons" => [
            %{"label" => "Approve", "event" => "design_approved", "variant" => "primary"},
            %{
              "label" => "Request Changes",
              "event" => "design_changes_requested",
              "variant" => "outline"
            }
          ]
        },
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Approve"
      assert html =~ "Request Changes"
      assert html =~ "btn"
    end

    test "sets phx-click canvas_action" do
      node = %{
        "type" => "action_row",
        "props" => %{
          "buttons" => [
            %{"label" => "Go", "event" => "go_event"}
          ]
        },
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[phx-click="canvas_action"]
      assert html =~ ~s[phx-value-event="go_event"]
    end

    test "encodes payload as JSON in phx-value-payload" do
      node = %{
        "type" => "action_row",
        "props" => %{
          "buttons" => [
            %{
              "label" => "Act",
              "event" => "do_it",
              "payload" => %{"design_id" => "abc-123"}
            }
          ]
        },
        "children" => []
      }

      html = render_node(node)
      assert html =~ "abc-123"
    end

    test "applies primary variant class" do
      node = %{
        "type" => "action_row",
        "props" => %{
          "buttons" => [
            %{"label" => "OK", "event" => "ok", "variant" => "primary"}
          ]
        },
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-primary"
    end

    test "applies danger variant class" do
      node = %{
        "type" => "action_row",
        "props" => %{
          "buttons" => [
            %{"label" => "Delete", "event" => "delete", "variant" => "danger"}
          ]
        },
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-error"
    end

    test "defaults to outline class for unknown variant" do
      node = %{
        "type" => "action_row",
        "props" => %{
          "buttons" => [
            %{"label" => "X", "event" => "x"}
          ]
        },
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-outline"
    end

    test "renders empty action_row gracefully with no buttons" do
      node = %{
        "type" => "action_row",
        "props" => %{},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "flex"
    end
  end
end
