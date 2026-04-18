defmodule Platform.Chat.MentionBackfillTest do
  @moduledoc "Tests the rewrite logic used by `Platform.Chat.MentionBackfill.run/1`."
  use ExUnit.Case, async: true

  alias Platform.Chat.MentionBackfill

  defp roster(entries) do
    Enum.map(entries, fn {display_name, participant_id} ->
      %{display_name: display_name, participant_id: participant_id}
    end)
  end

  describe "rewrite_content/2" do
    test "rewrites single-word legacy mention to bracketed" do
      r = roster([{"Zip", "agent-1"}])
      assert MentionBackfill.rewrite_content("hey @zip", r) == "hey @[Zip]"
    end

    test "rewrites multi-word legacy mention with space in display name" do
      r = roster([{"Ryan Milvenan", "usr-1"}])

      assert MentionBackfill.rewrite_content("hi @Ryan Milvenan!", r) ==
               "hi @[Ryan Milvenan]!"
    end

    test "prefers longest match when shorter name is a prefix" do
      r = roster([{"Ryan", "usr-1"}, {"Ryan Milvenan", "usr-2"}])

      assert MentionBackfill.rewrite_content("@Ryan Milvenan hi", r) ==
               "@[Ryan Milvenan] hi"

      assert MentionBackfill.rewrite_content("@Ryan hey", r) == "@[Ryan] hey"
    end

    test "canonicalizes casing from the roster display name" do
      r = roster([{"Mycroft", "agent-mycroft"}])
      assert MentionBackfill.rewrite_content("@mycroft here", r) == "@[Mycroft] here"
    end

    test "leaves bare @ without a matching roster entry untouched" do
      r = roster([{"Zip", "agent-1"}])

      assert MentionBackfill.rewrite_content("ping @nobody please", r) ==
               "ping @nobody please"
    end

    test "does not trigger on mid-word @ (e.g. email addresses)" do
      r = roster([{"example", "usr-1"}])

      assert MentionBackfill.rewrite_content("email me at foo@example.com", r) ==
               "email me at foo@example.com"
    end

    test "preserves trailing non-word characters like punctuation" do
      r = roster([{"Ryan", "usr-1"}])
      assert MentionBackfill.rewrite_content("sup @Ryan?", r) == "sup @[Ryan]?"
      assert MentionBackfill.rewrite_content("@Ryan, hi", r) == "@[Ryan], hi"
    end

    test "respects word boundary: @Ryans does not match Ryan" do
      r = roster([{"Ryan", "usr-1"}])

      assert MentionBackfill.rewrite_content("happy @Ryans party", r) ==
               "happy @Ryans party"
    end

    test "rewrites multiple mentions in one message" do
      r = roster([{"Zip", "agent-1"}, {"Nova", "agent-2"}])

      assert MentionBackfill.rewrite_content("@zip and @nova help", r) ==
               "@[Zip] and @[Nova] help"
    end

    test "matches by participant_id when display_name is absent from content" do
      r = [%{display_name: "Ryan", participant_id: "ryan-slug"}]
      assert MentionBackfill.rewrite_content("@ryan-slug hi", r) == "@[Ryan] hi"
    end

    test "handles empty roster gracefully" do
      assert MentionBackfill.rewrite_content("@alice @bob", []) == "@alice @bob"
    end

    test "handles nil / non-string content gracefully" do
      assert MentionBackfill.rewrite_content(nil, roster([{"A", "1"}])) == nil
    end
  end

  describe "module existence" do
    test "release-callable module is defined" do
      assert Code.ensure_loaded?(Platform.Chat.MentionBackfill)
      assert function_exported?(Platform.Chat.MentionBackfill, :run, 0)
      assert function_exported?(Platform.Chat.MentionBackfill, :run, 1)
    end

    test "mix task shim is defined" do
      assert Code.ensure_loaded?(Mix.Tasks.Platform.BackfillMentions)
    end
  end
end
