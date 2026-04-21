# Dev-only canvas zoo seed. Run with:
#
#   cd apps/platform && mix run priv/seeds/canvas_zoo.exs
#
# Idempotent: soft-deletes existing canvases in the `canvas-zoo` space
# before re-seeding, so the output is always the same 14 kind-demo
# canvases + 4 complex multi-kind stacks in predictable order.

alias Platform.Chat
alias Platform.Chat.Attachment
alias Platform.Chat.AttachmentStorage
alias Platform.Chat.Canvas
alias Platform.Repo

import Ecto.Query, only: [from: 2]

# ── Ensure dev user + canvas-zoo space + participant ──────────────────────────

{:ok, user} =
  Platform.Accounts.find_or_create_from_oidc(%{
    sub: "dev-local-user",
    email: "dev@localhost",
    name: "Dev User"
  })

space =
  Chat.get_space_by_slug("canvas-zoo") ||
    elem(Chat.create_space(%{name: "Canvas Zoo", slug: "canvas-zoo", kind: "channel"}), 1)

participant =
  Repo.get_by(Platform.Chat.Participant,
    space_id: space.id,
    participant_type: "user",
    participant_id: user.id
  ) ||
    elem(
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      }),
      1
    )

# ── Idempotent reset — soft-delete existing zoo canvases ──────────────────────

now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

{wiped, _} =
  Repo.update_all(
    Ecto.Query.from(c in Canvas, where: c.space_id == ^space.id and is_nil(c.deleted_at)),
    set: [deleted_at: now]
  )

IO.puts("soft-deleted #{wiped} prior canvas(es) in #{space.slug}")

# ── Upload the sample image so phase-6 image-src sanitizer accepts it ────────

sample_path = Path.join([:code.priv_dir(:platform), "seeds", "assets", "canvas-zoo-sample.png"])

{:ok, stored} =
  AttachmentStorage.persist_upload(sample_path, "canvas-zoo-sample.png", "image/png")

{:ok, image_attachment} =
  Chat.create_attachment(
    Map.merge(stored, %{
      space_id: space.id,
      uploaded_by_agent_id: nil
    })
  )

image_url = "/chat/attachments/#{image_attachment.id}"
IO.puts("uploaded sample image: #{image_url}")

# ── Canvas document helpers ────────────────────────────────────────────────────

defmodule Zoo do
  def wrap(children) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => List.wrap(children)
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  # ── One-kind demos ────────────────────────────────────────────────────────

  def node_for("stack"),
    do: %{
      "id" => "inner-stack",
      "type" => "stack",
      "props" => %{"gap" => 8},
      "children" => [
        %{
          "id" => "s1",
          "type" => "text",
          "props" => %{"value" => "stacked line 1"},
          "children" => []
        },
        %{
          "id" => "s2",
          "type" => "text",
          "props" => %{"value" => "stacked line 2"},
          "children" => []
        }
      ]
    }

  def node_for("row"),
    do: %{
      "id" => "row-demo",
      "type" => "row",
      "props" => %{"gap" => 12},
      "children" => [
        %{"id" => "r1", "type" => "badge", "props" => %{"value" => "ONE"}, "children" => []},
        %{
          "id" => "r2",
          "type" => "badge",
          "props" => %{"value" => "TWO", "tone" => "info"},
          "children" => []
        },
        %{
          "id" => "r3",
          "type" => "badge",
          "props" => %{"value" => "THREE", "tone" => "warning"},
          "children" => []
        }
      ]
    }

  def node_for("card"),
    do: %{
      "id" => "card-demo",
      "type" => "card",
      "props" => %{"title" => "Sprint goal"},
      "children" => [
        %{
          "id" => "card-body",
          "type" => "markdown",
          "props" => %{"content" => "Ship the canvas zoo — end-to-end browser verification."},
          "children" => []
        }
      ]
    }

  def node_for("text"),
    do: %{
      "id" => "text-demo",
      "type" => "text",
      "props" => %{"value" => "Hello from the text kind.", "size" => "lg", "weight" => "bold"},
      "children" => []
    }

  def node_for("markdown"),
    do: %{
      "id" => "md-demo",
      "type" => "markdown",
      "props" => %{
        "content" =>
          "# Markdown kind\n\nThis block shows pre-formatted content.\n\n- bullet A\n- bullet B\n- bullet C"
      },
      "children" => []
    }

  def node_for("heading"),
    do: %{
      "id" => "h-demo",
      "type" => "heading",
      "props" => %{"value" => "Heading demo (level 2)", "level" => 2},
      "children" => []
    }

  def node_for("badge"),
    do: %{
      "id" => "b-demo",
      "type" => "badge",
      "props" => %{"value" => "READY", "tone" => "success"},
      "children" => []
    }

  def node_for("image", image_url),
    do: %{
      "id" => "img-demo",
      "type" => "image",
      "props" => %{
        "src" => image_url,
        "alt" => "Generated gradient",
        "caption" => "Image kind — local attachment, ADR-0039 phase-6 conformant",
        "border" => true,
        "rounded" => true
      },
      "children" => []
    }

  def node_for("code"),
    do: %{
      "id" => "code-demo",
      "type" => "code",
      "props" => %{
        "language" => "elixir",
        "source" =>
          "defmodule Greeter do\n  def hello(name), do: IO.puts(\"Hello, \" <> name)\nend\n\nGreeter.hello(\"canvas\")"
      },
      "children" => []
    }

  def node_for("mermaid"),
    do: %{
      "id" => "mermaid-demo",
      "type" => "mermaid",
      "props" => %{
        "source" =>
          "graph TD\n  Idea --> Design\n  Design --> Build\n  Build --> Review\n  Review --> Ship"
      },
      "children" => []
    }

  def node_for("table"),
    do: %{
      "id" => "tbl-demo",
      "type" => "table",
      "props" => %{
        "columns" => ["Kind", "Accepts children", "Notes"],
        "rows" => [
          %{"Kind" => "stack", "Accepts children" => "any", "Notes" => "vertical"},
          %{"Kind" => "row", "Accepts children" => "any", "Notes" => "horizontal"},
          %{"Kind" => "checklist", "Accepts children" => "checklist_item", "Notes" => "list"}
        ]
      },
      "children" => []
    }

  def node_for("form"),
    do: %{
      "id" => "form-demo",
      "type" => "form",
      "props" => %{
        "title" => "Feedback form",
        "submit_label" => "Send",
        "fields" => [
          %{"name" => "headline", "label" => "Headline", "type" => "text", "required" => true},
          %{"name" => "details", "label" => "Details", "type" => "textarea"}
        ]
      },
      "children" => []
    }

  def node_for("action_row"),
    do: %{
      "id" => "ar-demo",
      "type" => "action_row",
      "props" => %{
        "label" => "Choose one",
        "actions" => [
          %{"label" => "Approve", "value" => "approve", "variant" => "primary"},
          %{"label" => "Reject", "value" => "reject", "variant" => "danger"},
          %{"label" => "Defer", "value" => "defer", "variant" => "ghost"}
        ]
      },
      "children" => []
    }

  def node_for("checklist"),
    do: %{
      "id" => "cl-demo",
      "type" => "checklist",
      "props" => %{"title" => "Launch readiness"},
      "children" => [
        %{
          "id" => "ci-1",
          "type" => "checklist_item",
          "props" => %{"label" => "Design approved", "state" => "complete"},
          "children" => []
        },
        %{
          "id" => "ci-2",
          "type" => "checklist_item",
          "props" => %{"label" => "Tests passing", "state" => "active"},
          "children" => []
        },
        %{
          "id" => "ci-3",
          "type" => "checklist_item",
          "props" => %{
            "label" => "Deploy queued",
            "state" => "pending",
            "note" => "Blocked on CI"
          },
          "children" => []
        }
      ]
    }

  def node_for("checklist_item"), do: nil

  # ── Complex multi-kind stacks ─────────────────────────────────────────────

  @doc "Review flow — a card that bundles context + decision form + action row."
  def complex_review_flow do
    %{
      "id" => "review-card",
      "type" => "card",
      "props" => %{"title" => "PR #142 — add canvas emission consumer"},
      "children" => [
        %{
          "id" => "review-context",
          "type" => "markdown",
          "props" => %{
            "content" =>
              "Two bugs silently dropped every canvas emission:\n\n" <>
                "1. 4-tuple pattern vs 3-tuple broadcast\n" <>
                "2. No canvas-topic subscription from the LiveView\n\n" <>
                "Fix ships with a regression test."
          },
          "children" => []
        },
        %{
          "id" => "review-form",
          "type" => "form",
          "props" => %{
            "title" => "Reviewer notes",
            "submit_label" => "Submit review",
            "fields" => [
              %{"name" => "summary", "label" => "Summary", "type" => "text", "required" => true},
              %{"name" => "notes", "label" => "Open questions", "type" => "textarea"}
            ]
          },
          "children" => []
        },
        %{
          "id" => "review-actions",
          "type" => "action_row",
          "props" => %{
            "label" => "Decision",
            "actions" => [
              %{"label" => "Approve", "value" => "approve", "variant" => "primary"},
              %{
                "label" => "Request changes",
                "value" => "request_changes",
                "variant" => "danger"
              },
              %{"label" => "Defer", "value" => "defer", "variant" => "ghost"}
            ]
          },
          "children" => []
        }
      ]
    }
  end

  @doc "Launch readiness — a checklist followed by a sticky action row."
  def complex_launch_readiness do
    [
      %{
        "id" => "lr-heading",
        "type" => "heading",
        "props" => %{"value" => "Launch readiness", "level" => 2},
        "children" => []
      },
      %{
        "id" => "lr-checklist",
        "type" => "checklist",
        "props" => %{"title" => "Gates"},
        "children" => [
          %{
            "id" => "lr-g1",
            "type" => "checklist_item",
            "props" => %{"label" => "Tests green", "state" => "complete"},
            "children" => []
          },
          %{
            "id" => "lr-g2",
            "type" => "checklist_item",
            "props" => %{"label" => "Docs updated", "state" => "active"},
            "children" => []
          },
          %{
            "id" => "lr-g3",
            "type" => "checklist_item",
            "props" => %{"label" => "Deploy window confirmed", "state" => "pending"},
            "children" => []
          },
          %{
            "id" => "lr-g4",
            "type" => "checklist_item",
            "props" => %{"label" => "Rollback plan written", "state" => "pending"},
            "children" => []
          }
        ]
      },
      %{
        "id" => "lr-actions",
        "type" => "action_row",
        "props" => %{
          "label" => "Launch control",
          "actions" => [
            %{"label" => "Mark all complete", "value" => "complete_all", "variant" => "primary"},
            %{"label" => "Snooze 1 day", "value" => "snooze_1d", "variant" => "secondary"},
            %{"label" => "Block launch", "value" => "block", "variant" => "danger"}
          ]
        },
        "children" => []
      }
    ]
  end

  @doc "Data + actions — a table on the left, action row on the right, horizontally."
  def complex_data_actions do
    %{
      "id" => "da-row",
      "type" => "row",
      "props" => %{"gap" => 16},
      "children" => [
        %{
          "id" => "da-table",
          "type" => "table",
          "props" => %{
            "columns" => ["Agent", "Status", "Last seen"],
            "rows" => [
              %{"Agent" => "geordi", "Status" => "active", "Last seen" => "just now"},
              %{"Agent" => "higgins", "Status" => "active", "Last seen" => "2m ago"},
              %{"Agent" => "mycroft", "Status" => "idle", "Last seen" => "1h ago"}
            ]
          },
          "children" => []
        },
        %{
          "id" => "da-stack",
          "type" => "stack",
          "props" => %{"gap" => 8},
          "children" => [
            %{
              "id" => "da-text",
              "type" => "text",
              "props" => %{"value" => "Bulk actions", "weight" => "bold"},
              "children" => []
            },
            %{
              "id" => "da-actions",
              "type" => "action_row",
              "props" => %{
                "actions" => [
                  %{"label" => "Refresh", "value" => "refresh", "variant" => "primary"},
                  %{
                    "label" => "Dispatch all",
                    "value" => "dispatch_all",
                    "variant" => "secondary"
                  },
                  %{"label" => "Pause all", "value" => "pause_all", "variant" => "ghost"}
                ]
              },
              "children" => []
            }
          ]
        }
      ]
    }
  end

  @doc "Deep nesting — stack → row → card → form. Stress-tests event propagation through layers."
  def complex_deep_nesting do
    %{
      "id" => "dn-outer-row",
      "type" => "row",
      "props" => %{"gap" => 16},
      "children" => [
        %{
          "id" => "dn-card-1",
          "type" => "card",
          "props" => %{"title" => "Level 2"},
          "children" => [
            %{
              "id" => "dn-nested-stack",
              "type" => "stack",
              "props" => %{"gap" => 8},
              "children" => [
                %{
                  "id" => "dn-md",
                  "type" => "markdown",
                  "props" => %{
                    "content" =>
                      "Form below is **four levels deep**. Its submit should still emit."
                  },
                  "children" => []
                },
                %{
                  "id" => "dn-form",
                  "type" => "form",
                  "props" => %{
                    "title" => "Deep form",
                    "submit_label" => "Send from depth",
                    "fields" => [
                      %{
                        "name" => "payload",
                        "label" => "Payload",
                        "type" => "text",
                        "required" => true
                      }
                    ]
                  },
                  "children" => []
                }
              ]
            }
          ]
        },
        %{
          "id" => "dn-card-2",
          "type" => "card",
          "props" => %{"title" => "Side controls"},
          "children" => [
            %{
              "id" => "dn-actions",
              "type" => "action_row",
              "props" => %{
                "actions" => [
                  %{"label" => "Ping", "value" => "ping", "variant" => "primary"},
                  %{"label" => "Pong", "value" => "pong", "variant" => "secondary"}
                ]
              },
              "children" => []
            }
          ]
        }
      ]
    }
  end
end

# ── Seed ──────────────────────────────────────────────────────────────────────

kinds =
  ~w(stack row card text markdown heading badge image code mermaid table form action_row checklist)

Enum.each(kinds, fn kind ->
  child =
    case kind do
      "image" -> Zoo.node_for("image", image_url)
      other -> Zoo.node_for(other)
    end

  if child do
    doc = Zoo.wrap([child])

    case Chat.create_canvas_with_message(space.id, participant.id, %{
           "title" => "Kind demo: #{kind}",
           "document" => doc
         }) do
      {:ok, canvas, _msg} ->
        IO.puts("kind #{kind}: #{canvas.id}")

      {:error, reason} ->
        IO.puts("FAILED kind #{kind}: #{inspect(reason)}")
    end
  end
end)

complex_canvases = [
  {"Complex: review flow", [Zoo.complex_review_flow()]},
  {"Complex: launch readiness", Zoo.complex_launch_readiness()},
  {"Complex: data + actions", [Zoo.complex_data_actions()]},
  {"Complex: deep nesting", [Zoo.complex_deep_nesting()]}
]

Enum.each(complex_canvases, fn {title, children} ->
  doc = Zoo.wrap(children)

  case Chat.create_canvas_with_message(space.id, participant.id, %{
         "title" => title,
         "document" => doc
       }) do
    {:ok, canvas, _msg} ->
      IO.puts("complex #{title}: #{canvas.id}")

    {:error, reason} ->
      IO.puts("FAILED complex #{title}: #{inspect(reason)}")
  end
end)

IO.puts("\nSpace: #{space.slug} (#{space.id})")
IO.puts("Open: http://localhost:4000/chat/#{space.slug}")
