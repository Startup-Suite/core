// ComposeInput hook — auto-expanding textarea, Enter for newline, @mention autocomplete

// Per-space draft store. Module-level so it survives LiveView re-renders and space
// navigation for the lifetime of the page session.
const draftStore = {};

const ComposeInput = {
  mounted() {
    this._lastMentionQuery = null;

    // Auto-resize: collapse to 0 then expand to exact content height (capped at 200px)
    this._autoResize = () => {
      this.el.style.height = "0";
      const contentHeight = this.el.scrollHeight;
      this.el.style.height = Math.min(contentHeight, 200) + "px";
      // Toggle internal scroll when content exceeds max
      this.el.style.overflowY = contentHeight > 200 ? "auto" : "hidden";
    };
    // Only resize if field-sizing:content isn't supported
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    // Track current space for draft keying
    this._spaceId = this.el.dataset.spaceId;

    // Restore any saved draft for this space
    const saved = this._spaceId && draftStore[this._spaceId];
    if (saved) {
      this.el.value = saved;
      if (!CSS.supports("field-sizing", "content")) { this._autoResize(); }
      // Sync server-side assign so incoming re-renders don't overwrite the restored value
      this.pushEvent("compose_changed", { compose: { text: saved } });
    }

    // Reset viewport after iOS keyboard dismisses
    this.el.addEventListener("blur", () => {
      setTimeout(() => {
        window.scrollTo({ top: 0, behavior: "instant" });
      }, 100);
    });

    this.el.addEventListener("keydown", (e) => {
      // Enter inserts newline (default textarea behavior) — no preventDefault.
      // Shift+Enter or Cmd/Ctrl+Enter sends the message.
      if (e.key === "Enter" && (e.shiftKey || e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        this.pushEvent("clear_mention_suggestions", {});
        this._lastMentionQuery = null;

        const form = this.el.closest("form");
        if (form) form.requestSubmit();
        return;
      }

      if (e.key === "Escape") {
        this.pushEvent("clear_mention_suggestions", {});
        this._lastMentionQuery = null;
      }

      if (e.key === "Tab" && this._lastMentionQuery !== null) {
        const dropdown = this.el.closest("form")?.querySelector("[data-mention-suggestion]");
        if (dropdown) {
          e.preventDefault();
          dropdown.click();
        }
      }
    });

    this.el.addEventListener("input", () => {
      if (!CSS.supports("field-sizing", "content")) {
        this._autoResize();
      }
      this._detectMention();
      // Save draft on every keystroke
      if (this._spaceId) { draftStore[this._spaceId] = this.el.value; }
    });

    // Reset height after form submission (LiveView clears the value)
    this.handleEvent && this.handleEvent("compose_reset", () => {
      if (!CSS.supports("field-sizing", "content")) {
        this.el.style.height = "33px";
        this.el.style.overflowY = "hidden";
      }
      // Clear saved draft for this space after a successful send
      if (this._spaceId) { delete draftStore[this._spaceId]; }
    });

    // Handle insert-mention events dispatched by suggestion buttons
    this.el.addEventListener("chat:insert-mention", (e) => {
      const name = e.detail && e.detail.name;
      if (!name) return;

      const value = this.el.value;
      const cursor = this.el.selectionStart;

      // Find the @ that triggered the suggestion
      const before = value.slice(0, cursor);
      const atIndex = before.lastIndexOf("@");

      if (atIndex !== -1) {
        const after = value.slice(cursor);
        this.el.value = before.slice(0, atIndex) + "@" + name + " " + after;

        // Move cursor after the inserted mention
        const newPos = atIndex + name.length + 2;
        this.el.setSelectionRange(newPos, newPos);
      }

      this.pushEvent("clear_mention_suggestions", {});
      this._lastMentionQuery = null;
      this.el.focus();
    });
  },

  beforeUpdate() {
    // Capture draft before LiveView patches the DOM. On space navigation,
    // handle_params calls assign_compose("") which would overwrite the textarea —
    // saving here preserves whatever the user had typed.
    if (this._spaceId) {
      draftStore[this._spaceId] = this.el.value;
    }
  },

  updated() {
    // Re-apply auto-resize when LiveView patches the textarea (e.g., after send clears it)
    if (!CSS.supports("field-sizing", "content")) {
      this._autoResize();
    }

    // Detect space navigation: data-space-id changes when handle_params loads a new space
    const newSpaceId = this.el.dataset.spaceId;
    if (newSpaceId !== this._spaceId) {
      this._spaceId = newSpaceId;
      const draft = (this._spaceId && draftStore[this._spaceId]) || "";
      this.el.value = draft;
      if (!CSS.supports("field-sizing", "content")) { this._autoResize(); }
      // Sync server state so re-renders don't stomp the restored draft
      if (draft) {
        this.pushEvent("compose_changed", { compose: { text: draft } });
      }
    }
  },

  _detectMention() {
    const value = this.el.value;
    const cursor = this.el.selectionStart;
    const before = value.slice(0, cursor);

    // Look for @ followed by word chars (no spaces) since last whitespace
    const match = before.match(/@(\w*)$/);

    if (match) {
      const query = match[1];
      if (query !== this._lastMentionQuery) {
        this._lastMentionQuery = query;
        this.pushEvent("mention_query", { query });
      }
    } else {
      if (this._lastMentionQuery !== null) {
        this._lastMentionQuery = null;
        this.pushEvent("clear_mention_suggestions", {});
      }
    }
  },
};

export default ComposeInput;
