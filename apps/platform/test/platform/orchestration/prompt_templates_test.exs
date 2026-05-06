defmodule Platform.Orchestration.PromptTemplatesTest do
  @moduledoc """
  Asserts that the seeded prompt templates carry the e2e_behavior + manual_approval
  guidance that downstream stages (planner output, dispatch routing) depend on.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  describe "default_content_for_slug/1 — dispatch.planning" do
    test "instructs the planner to emit exactly one e2e_behavior validation per task" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")
      assert is_binary(content)

      assert content =~ "e2e_behavior"
      assert content =~ "exactly one"
      assert content =~ "evaluation_payload"
    end

    test "documents the four required payload keys" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      for key <- ~w(setup actions expected failure_feedback) do
        assert content =~ key, "expected dispatch.planning to mention #{key}"
      end
    end

    test "scopes manual_approval to UI-touching stages with file-path tokens" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "manual_approval"

      assert content =~ ".heex"
      assert content =~ "assets/js/"
      assert content =~ "tasks_live.ex"
    end

    test "forbids code_review and warns against multiple e2e_behavior" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "code_review"
      assert content =~ "Forbidden"
    end

    test "includes a worked e2e_behavior payload example" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      # The example is a JSON-style block with the four payload keys
      assert content =~ "\"kind\": \"e2e_behavior\""
      assert content =~ "\"setup\":"
      assert content =~ "\"failure_feedback\":"
    end
  end

  describe "default_content_for_slug/1 — dispatch.in_review" do
    test "no longer mentions e2e behavioral validation (handled by dispatch.review_e2e)" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")
      assert is_binary(content)

      refute content =~ "e2e_behavior",
             "dispatch.in_review should not mention e2e_behavior — that's dispatch.review_e2e's job"
    end

    test "still covers the manual_approval / UI-judgment review path" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")

      assert content =~ "manual_approval"
      assert content =~ "review_request_create" or content =~ "suite_review_request_create"
    end
  end

  describe "default_content_for_slug/1 — dispatch.review_e2e" do
    test "exists as a seeded template slug" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      assert is_binary(content),
             "dispatch.review_e2e must be registered in default_templates/0"
    end

    test "references the four evaluation_payload fields and validation_id" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      for token <- ~w(setup actions expected failure_feedback validation_id) do
        assert content =~ token, "expected dispatch.review_e2e to mention #{token}"
      end
    end

    test "instructs the agent to disposition via validation_evaluate (passed/failed)" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      assert content =~ "validation_evaluate"
      assert content =~ "passed"
      assert content =~ "failed"
    end

    test "forbids self-bouncing the task status" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      # Plan engine handles the in_review→in_progress transition on a failed
      # e2e_behavior verdict; the agent must not call task_update for it.
      assert content =~ "task_update" or content =~ "self-bounce" or
               content =~ "do not transition" or content =~ "Do NOT"
    end

    test "renders payload fields when supplied via assigns" do
      assigns = %{
        task_title: "Render dependency badges",
        validation_id: "00000000-0000-0000-0000-deadbeefcafe",
        evaluation_payload_json:
          ~s({"setup":"create A and B","actions":"complete A","expected":"badge clears","failure_feedback":"badge stuck"}),
        execution_space_id: "11111111-1111-1111-1111-111111111111",
        repo_url: "git@github.com:acme/widgets.git",
        task_slug: "deadbeef",
        skills_reference: "Use bundled skills."
      }

      # Seed the template into the test DB so render_template can find it.
      :ok = PromptTemplates.seed_defaults()
      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.review_e2e", assigns)

      assert rendered =~ "Render dependency badges"
      assert rendered =~ "00000000-0000-0000-0000-deadbeefcafe"
      assert rendered =~ "create A and B"
      assert rendered =~ "11111111-1111-1111-1111-111111111111"
      assert rendered =~ "git@github.com:acme/widgets.git"
      assert rendered =~ "deadbeef"
    end
  end

  describe "seed_defaults/0 + migration parity" do
    test "seed_defaults seeds dispatch.planning with current default content" do
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      assert template

      expected = PromptTemplates.default_content_for_slug("dispatch.planning")
      assert template.content == expected
    end
  end
end
