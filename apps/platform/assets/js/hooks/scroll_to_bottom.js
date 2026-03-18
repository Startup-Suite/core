// ScrollToBottom hook — scrolls a container to its bottom on mount and on
// each DOM update (i.e. when new messages arrive via phx-update="stream").
const ScrollToBottom = {
  mounted() {
    this.scrollToBottom();
    // MutationObserver fires when stream inserts new message rows
    this._observer = new MutationObserver(() => this.scrollToBottom());
    this._observer.observe(this.el, { childList: true, subtree: true });
  },
  updated() {
    this.scrollToBottom();
  },
  destroyed() {
    if (this._observer) this._observer.disconnect();
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default ScrollToBottom;
