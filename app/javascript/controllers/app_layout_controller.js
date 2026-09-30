import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="dialog"
export default class extends Controller {
  static targets = ["leftSidebar", "rightSidebar", "mobileSidebar"];
  static values = { userId: String };
  static classes = [
    "expandedSidebar",
    "collapsedSidebar",
    "expandedTransition",
    "collapsedTransition",
  ];

  connect() {
    document.addEventListener("keydown", this.handleKeydown);
  }

  disconnect() {
    document.removeEventListener("keydown", this.handleKeydown);
  }

  openMobileSidebar() {
    this.mobileSidebarTarget.classList.remove("hidden");
  }

  closeMobileSidebar() {
    this.mobileSidebarTarget.classList.add("hidden");
  }

  // Escape closes the mobile nav overlay, matching every other full-screen
  // panel in the app. DS::Dialog gets this for free from the native
  // <dialog> element; this is a plain full-bleed div (it covers the whole
  // viewport, so there's no "outside" to click either), so it needs its
  // own listener. The explicit close button remained the only way out
  // otherwise.
  handleKeydown = (event) => {
    if (event.key !== "Escape") return;
    if (!this.hasMobileSidebarTarget) return;
    if (this.mobileSidebarTarget.classList.contains("hidden")) return;

    this.closeMobileSidebar();
  };

  toggleLeftSidebar() {
    const isOpen = this.leftSidebarTarget.classList.contains("w-full");
    this.#updateUserPreference("show_sidebar", !isOpen);
    this.#toggleSidebarWidth(this.leftSidebarTarget, isOpen, "left");
  }

  toggleRightSidebar() {
    const isOpen = this.rightSidebarTarget.classList.contains("w-full");
    this.#updateUserPreference("show_ai_sidebar", !isOpen);
    this.#toggleSidebarWidth(this.rightSidebarTarget, isOpen, "right");
  }

  // For actions that send content into the chat sidebar (quick prompts,
  // AI review): make sure it is visible, and never close it.
  openRightSidebar() {
    const isOpen = this.rightSidebarTarget.classList.contains("w-full");
    if (isOpen) return;

    this.#updateUserPreference("show_ai_sidebar", true);
    this.#toggleSidebarWidth(this.rightSidebarTarget, false, "right");
  }

  #toggleSidebarWidth(el, isCurrentlyOpen, side) {
    const expandedClasses = side === "left" ? [...this.expandedSidebarClasses, "border-r"] : [...this.expandedSidebarClasses, "border-l"];
    const collapsedClasses = side === "left" ? [...this.collapsedSidebarClasses, "border-r-0"] : [...this.collapsedSidebarClasses, "border-l-0"];

    if (isCurrentlyOpen) {
      el.classList.remove(...expandedClasses);
      el.classList.add(...collapsedClasses);
      el.inert = true;
    } else {
      el.classList.add(...expandedClasses);
      el.classList.remove(...collapsedClasses);
      el.inert = false;
    }
  }

  #updateUserPreference(field, value) {
    fetch(`/users/${this.userIdValue}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
        "X-CSRF-Token": document.querySelector('[name="csrf-token"]').content,
        Accept: "application/json",
      },
      body: new URLSearchParams({
        [`user[${field}]`]: value,
      }).toString(),
    });
  }
}
