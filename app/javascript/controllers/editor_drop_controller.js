import { Controller } from "@hotwired/stimulus"
import { post } from "@rails/request.js"

export default class extends Controller {
  static targets = ["editor"]

  connect() {
    this.setupDragAndDrop()
    this.setupPasteHandler()
  }

  disconnect() {
    this.removeDragAndDrop()
    this.removePasteHandler()
  }

  setupDragAndDrop() {
    this.element.addEventListener("dragenter", this.handleDragEnter)
    this.element.addEventListener("dragover", this.handleDragOver)
    this.element.addEventListener("dragleave", this.handleDragLeave)
    this.element.addEventListener("drop", this.handleDrop)
  }

  removeDragAndDrop() {
    this.element.removeEventListener("dragenter", this.handleDragEnter)
    this.element.removeEventListener("dragover", this.handleDragOver)
    this.element.removeEventListener("dragleave", this.handleDragLeave)
    this.element.removeEventListener("drop", this.handleDrop)
  }

  setupPasteHandler() {
    this.handlePaste = this.handlePaste.bind(this)
    document.addEventListener("paste", this.handlePaste)
  }

  removePasteHandler() {
    document.removeEventListener("paste", this.handlePaste)
  }

  handleDragEnter = (event) => {
    if (this.isImageEvent(event)) {
      event.preventDefault()
      event.stopPropagation()
      this.element.classList.add("editor-drop-active")
    }
  }

  handleDragOver = (event) => {
    if (this.isImageEvent(event)) {
      event.preventDefault()
      event.stopPropagation()
      event.dataTransfer.dropEffect = "copy"
    }
  }

  handleDragLeave = (event) => {
    if (this.isImageEvent(event)) {
      event.preventDefault()
      event.stopPropagation()
      this.element.classList.remove("editor-drop-active")
    }
  }

  handleDrop = async (event) => {
    event.preventDefault()
    event.stopPropagation()
    this.element.classList.remove("editor-drop-active")

    if (!this.isImageEvent(event)) return

    const files = this.getImageFiles(event)
    if (files.length === 0) return

    for (const file of files) {
      await this.processAndInsertImage(file)
    }
  }

  handlePaste = async (event) => {
    const clipboardData = event.clipboardData || event.originalEvent?.clipboardData
    if (!clipboardData) return

    const items = clipboardData.items
    if (!items) return

    const imageItem = Array.from(items).find(
      (item) => item.type.startsWith("image/")
    )

    if (!imageItem) return

    event.preventDefault()

    const file = imageItem.getAsFile()
    if (!file) return

    await this.processAndInsertImage(file)
  }

  isImageEvent(event) {
    const types = event.dataTransfer?.types
    if (!types) return false

    if (types.includes("Files")) {
      const items = event.dataTransfer?.items
      if (items) {
        return Array.from(items).some(
          (item) => item.kind === "file" && item.type.startsWith("image/")
        )
      }
      return true
    }

    return Array.from(types).some((type) => type.startsWith("image/"))
  }

  getImageFiles(event) {
    const files = event.dataTransfer?.files
    if (!files) return []

    return Array.from(files).filter((file) =>
      file.type.startsWith("image/")
    )
  }

  async processAndInsertImage(file) {
    try {
      const base64 = await this.fileToBase64(file)
      const filename = file.name || this.generateFilename()

      const response = await post("/images/upload_base64", {
        body: {
          data: base64,
          mime_type: file.type,
          filename: filename
        },
        responseKind: "json"
      })

      if (!response.ok) {
        const data = await response.json
        throw new Error(data?.error || "Upload failed")
      }

      const result = await response.json
      const markdown = `![${file.name || "Image"}](${result.url})`

      this.insertMarkdown(markdown)
    } catch (error) {
      console.error("Error processing image:", error)
      this.showError(error.message)
    }
  }

  fileToBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => {
        const result = reader.result
        const base64 = result.split(",")[1]
        resolve(base64)
      }
      reader.onerror = reject
      reader.readAsDataURL(file)
    })
  }

  generateFilename() {
    const timestamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)
    return `pasted_${timestamp}.png`
  }

  insertMarkdown(markdown) {
    this.dispatch("image-insert", { detail: { markdown } })
  }

  showError(message) {
    alert(`Failed to insert image: ${message}`)
  }
}