import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { userPreference: String };

  connect() {
    this.startSystemThemeListener();
  }

  disconnect() {
    this.stopSystemThemeListener();
  }

  // Called automatically by Stimulus when the userPreferenceValue changes (e.g., after form submit/page reload)
  userPreferenceValueChanged() {
    this.applyTheme();
  }

  // Called when a theme radio button is clicked
  updateTheme(event) {
    const selectedTheme = event.currentTarget.value;
    if (selectedTheme === "system") {
      this.setTheme(this.systemPrefersDark(), { persist: false });
    } else if (selectedTheme === "dark") {
      this.setTheme(true);
    } else {
      this.setTheme(false);
    }
  }

  // Applies theme based on the userPreferenceValue (from server)
  applyTheme() {
    if (this.userPreferenceValue === "system") {
      this.setTheme(this.systemPrefersDark(), { persist: false });
    } else if (this.userPreferenceValue === "dark") {
      this.setTheme(true);
    } else {
      this.setTheme(false);
    }
  }

  // Sets the data-theme attribute and broadcasts a `theme:change` event so
  // imperative consumers (D3/SVG/canvas) can repaint without polling.
  //
  // `persist: false` for a "system"-derived theme — otherwise this pins
  // localStorage.theme to whatever the OS happened to resolve to *at this
  // pageview*. The anti-FOUC inline script (_dark_mode_check.html.erb) then
  // trusts that stale explicit value over a fresh OS read on the next load,
  // flashing the wrong theme for a frame if the OS theme changed since.
  // Leaving localStorage.theme unset for "system" keeps that script
  // re-evaluating the live media query every load, as intended.
  setTheme(isDark, { persist = true } = {}) {
    const theme = isDark ? "dark" : "light";
    if (persist) {
      localStorage.theme = theme;
    } else {
      localStorage.removeItem("theme");
    }
    document.documentElement.setAttribute("data-theme", theme);
    document.documentElement.dispatchEvent(
      new CustomEvent("theme:change", { detail: { theme } }),
    );
  }

  systemPrefersDark() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  handleSystemThemeChange = (event) => {
    // Only apply system theme changes if the user preference is currently 'system'
    if (this.userPreferenceValue === "system") {
      this.setTheme(event.matches, { persist: false });
    }
  };

  toggle() {
    const currentTheme = document.documentElement.getAttribute("data-theme");
    if (currentTheme === "dark") {
      this.setTheme(false);
    } else {
      this.setTheme(true);
    }
  }

  startSystemThemeListener() {
    this.darkMediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    this.darkMediaQuery.addEventListener(
      "change",
      this.handleSystemThemeChange,
    );
  }

  stopSystemThemeListener() {
    if (this.darkMediaQuery) {
      this.darkMediaQuery.removeEventListener(
        "change",
        this.handleSystemThemeChange,
      );
    }
  }
}
