// ScrollToBottom hook — scrolls a container to its bottom on mount and on
// each DOM update (i.e. when new messages arrive via phx-update="stream").
// Also applies Slack-style message grouping: consecutive messages from the
// same sender hide the avatar and sender name row.
const ScrollToBottom = {
  mounted() {
    this.applyGrouping();
    this.scrollToBottom();
    // MutationObserver fires when stream inserts new message rows
    this._observer = new MutationObserver(() => {
      this.applyGrouping();
      this.scrollToBottom();
    });
    this._observer.observe(this.el, { childList: true, subtree: false });
  },
  updated() {
    this.applyGrouping();
    this.scrollToBottom();
  },
  destroyed() {
    if (this._observer) this._observer.disconnect();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  // Walk visible message rows; if the participant matches the previous row,
  // collapse the avatar + header for a compact grouped look.
  applyGrouping() {
    const rows = Array.from(this.el.querySelectorAll("[data-participant-id]"));
    let prevParticipantId = null;

    rows.forEach((row) => {
      const pid = row.dataset.participantId;
      const avatar = row.querySelector(".message-avatar");
      const header = row.querySelector(".message-header");

      if (pid && pid === prevParticipantId) {
        // Grouped — hide avatar and header, reduce top padding
        if (avatar) avatar.style.visibility = "hidden";
        if (header) header.style.display = "none";
        row.style.paddingTop = "1px";
      } else {
        // First in group — show avatar and header normally
        if (avatar) avatar.style.visibility = "";
        if (header) header.style.display = "";
        row.style.paddingTop = "";
      }

      prevParticipantId = pid || null;
    });
  },
};

export default ScrollToBottom;
