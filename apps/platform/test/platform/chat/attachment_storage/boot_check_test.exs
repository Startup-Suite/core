defmodule Platform.Chat.AttachmentStorage.BootCheckTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.AttachmentStorage.BootCheck

  setup do
    root = Path.join(System.tmp_dir!(), "platform-bootcheck-test-#{Ecto.UUID.generate()}")
    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end
    end)

    {:ok, root: root}
  end

  describe "init/1" do
    test "returns :ignore when storage is writable" do
      assert BootCheck.init(:ok) == :ignore
    end

    test "propagates the ensure_writable! raise when storage is broken" do
      parent = Path.join(System.tmp_dir!(), "platform-bootcheck-parent-#{Ecto.UUID.generate()}")
      File.mkdir_p!(parent)
      File.chmod!(parent, 0o000)
      bad_root = Path.join(parent, "uploads")
      Application.put_env(:platform, :chat_attachments_root, bad_root)

      try do
        assert_raise RuntimeError, ~r/attachment storage is not writable/i, fn ->
          BootCheck.init(:ok)
        end
      after
        File.chmod!(parent, 0o755)
        File.rm_rf(parent)
      end
    end
  end
end
