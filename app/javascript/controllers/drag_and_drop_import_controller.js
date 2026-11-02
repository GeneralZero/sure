import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "form", "overlay"]
  static values = { invalidFileText: String }

  dragDepth = 0

  connect() {
    this.boundDragOver = this.dragOver.bind(this)
    this.boundDragEnter = this.dragEnter.bind(this)
    this.boundDragLeave = this.dragLeave.bind(this)
    this.boundDrop = this.drop.bind(this)

    // Listen on the document to catch drags anywhere
    document.addEventListener("dragover", this.boundDragOver)
    document.addEventListener("dragenter", this.boundDragEnter)
    document.addEventListener("dragleave", this.boundDragLeave)
    document.addEventListener("drop", this.boundDrop)
  }

  dragEnter(event) {
    event.preventDefault()
    this.dragDepth++
    if (this.dragDepth === 1) {
      this.overlayTarget.classList.remove("hidden")
    }
  }

  dragOver(event) {
    event.preventDefault()
  }

  dragLeave(event) {
    event.preventDefault()
    this.dragDepth--
    if (this.dragDepth <= 0) {
      this.dragDepth = 0
      this.overlayTarget.classList.add("hidden")
    }
  }

  drop(event) {
    event.preventDefault()
    this.dragDepth = 0
    this.overlayTarget.classList.add("hidden")

    if (event.dataTransfer.files.length > 0) {
      const file = event.dataTransfer.files[0]
      // Simple validation
      if (file.type === "text/csv" || file.name.toLowerCase().endsWith(".csv")) {
        this.inputTarget.files = event.dataTransfer.files
        this.formTarget.requestSubmit()
      } else {
        this.showInvalidFileMessage()
      }
    }
  }

  // A blocking window.alert() halted the whole page for an easily-recovered
  // mistake; an inline message next to the dropzone (auto-dismissed) says the
  // same thing without freezing the tab.
  showInvalidFileMessage() {
    this.invalidFileMessage?.remove()
    clearTimeout(this.invalidFileMessageTimer)

    const message = document.createElement("p")
    message.className = "text-sm text-destructive mt-2"
    message.textContent = this.invalidFileTextValue
    this.formTarget.prepend(message)

    this.invalidFileMessage = message
    this.invalidFileMessageTimer = setTimeout(() => message.remove(), 5000)
  }

  disconnect() {
    document.removeEventListener("dragover", this.boundDragOver)
    document.removeEventListener("dragenter", this.boundDragEnter)
    document.removeEventListener("dragleave", this.boundDragLeave)
    document.removeEventListener("drop", this.boundDrop)
    clearTimeout(this.invalidFileMessageTimer)
  }
}
