defmodule Platform.Repo.Migrations.BackfillAttachmentContentTypes do
  @moduledoc """
  Re-labels existing `chat_attachments` rows that were stored with
  `content_type = 'application/octet-stream'` because the uploading client
  (commonly iOS Safari picking a photo) didn't send a specific MIME type.

  Without this, those rows fail the `image_attachment?/1` check in the
  renderer (`image/*` prefix only) AND get `Content-Disposition: attachment`
  from `ChatAttachmentController`, so they show up in the UI as a grey
  file chip instead of inlining in the image gallery.

  The fix for new uploads lives in `AttachmentStorage.normalize_content_type/2`;
  this migration brings past rows up to par. Unknown extensions are left
  as `application/octet-stream` — safest default.
  """

  use Ecto.Migration

  @extension_to_mime [
    {"png", "image/png"},
    {"jpg", "image/jpeg"},
    {"jpeg", "image/jpeg"},
    {"gif", "image/gif"},
    {"webp", "image/webp"},
    {"heic", "image/heic"},
    {"heif", "image/heif"},
    {"svg", "image/svg+xml"},
    {"pdf", "application/pdf"}
  ]

  def up do
    Enum.each(@extension_to_mime, fn {ext, mime} ->
      execute("""
      UPDATE chat_attachments
      SET content_type = '#{mime}'
      WHERE content_type = 'application/octet-stream'
        AND lower(filename) LIKE '%.#{ext}'
      """)
    end)
  end

  def down do
    # Reverting would blanket re-label rows back to application/octet-stream
    # and reintroduce the rendering bug. A silent no-op would make a rollback
    # appear successful while leaving data in the post-migration state — so
    # raise loudly instead. Re-run the backfill manually if data was restored
    # from a pre-fix backup.
    raise "Irreversible data backfill — re-run manually after restoring pre-fix data"
  end
end
