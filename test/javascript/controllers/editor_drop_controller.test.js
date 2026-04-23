/**
 * @vitest-environment jsdom
 */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { Application } from "@hotwired/stimulus"
import EditorDropController from "../../../app/javascript/controllers/editor_drop_controller.js"

global.window = global.window || {}
window.t = (key) => key

vi.mock("@rails/request.js", () => ({
  post: vi.fn()
}))

import { post } from "@rails/request.js"

describe("EditorDropController", () => {
  let application, controller, element

  beforeEach(() => {
    document.body.innerHTML = `
      <div data-controller="editor-drop" data-editor-drop-target="editor">
      </div>
    `

    const meta = document.createElement("meta")
    meta.name = "csrf-token"
    meta.content = "test-token"
    document.head.appendChild(meta)

    element = document.querySelector('[data-controller="editor-drop"]')
    application = Application.start()
    application.register("editor-drop", EditorDropController)

    global.alert = vi.fn()

    vi.mocked(post).mockReset()

    return new Promise((resolve) => {
      setTimeout(() => {
        controller = application.getControllerForElementAndIdentifier(element, "editor-drop")
        resolve()
      }, 0)
    })
  })

  afterEach(() => {
    application.stop()
    vi.restoreAllMocks()
    document.head.querySelector('meta[name="csrf-token"]')?.remove()
  })

  describe("isImageEvent()", () => {
    it("returns true for event with image files", () => {
      const event = {
        dataTransfer: {
          types: ["Files"],
          items: [
            { kind: "file", type: "image/png" }
          ]
        }
      }

      expect(controller.isImageEvent(event)).toBe(true)
    })

    it("returns false for event without files", () => {
      const event = {
        dataTransfer: {
          types: ["Files"],
          items: []
        }
      }

      expect(controller.isImageEvent(event)).toBe(false)
    })

    it("returns false for non-image files", () => {
      const event = {
        dataTransfer: {
          types: ["Files"],
          items: [
            { kind: "file", type: "text/plain" }
          ]
        }
      }

      expect(controller.isImageEvent(event)).toBe(false)
    })
  })

  describe("getImageFiles()", () => {
    it("returns only image files", () => {
      const imageFile = new File(["test"], "test.png", { type: "image/png" })
      const textFile = new File(["test"], "test.txt", { type: "text/plain" })

      const event = {
        dataTransfer: {
          files: [imageFile, textFile]
        }
      }

      const files = controller.getImageFiles(event)
      expect(files).toHaveLength(1)
      expect(files[0].name).toBe("test.png")
    })

    it("returns empty array for no files", () => {
      const event = {
        dataTransfer: {
          files: null
        }
      }

      expect(controller.getImageFiles(event)).toEqual([])
    })
  })

  describe("fileToBase64()", () => {
    it("converts file to base64 string", async () => {
      const file = new File(["test content"], "test.png", { type: "image/png" })

      const base64 = await controller.fileToBase64(file)
      expect(base64).toBe("dGVzdCBjb250ZW50")
    })
  })

  describe("generateFilename()", () => {
    it("generates timestamp-based filename", () => {
      const filename = controller.generateFilename()
      expect(filename).toMatch(/^pasted_\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.png$/)
    })
  })

  describe("handlePaste()", () => {
    it("handles paste event with image", async () => {
      const file = new File(["test"], "clipboard.png", { type: "image/png" })
      const clipboardData = {
        items: [
          {
            type: "image/png",
            getAsFile: () => file
          }
        ]
      }

      const event = {
        preventDefault: vi.fn(),
        clipboardData,
        originalEvent: { clipboardData }
      }

      vi.mocked(post).mockResolvedValue({
        ok: true,
        json: { url: "images/test.png" }
      })

      const dispatchSpy = vi.spyOn(controller, "dispatch")

      await controller.handlePaste(event)

      expect(event.preventDefault).toHaveBeenCalled()
      expect(dispatchSpy).toHaveBeenCalledWith("image-insert", {
        detail: { markdown: "![clipboard.png](images/test.png)" }
      })
    })

    it("ignores paste event without image", async () => {
      const clipboardData = {
        items: [
          {
            type: "text/plain",
            getAsFile: () => null
          }
        ]
      }

      const event = {
        preventDefault: vi.fn(),
        clipboardData,
        originalEvent: { clipboardData }
      }

      const dispatchSpy = vi.spyOn(controller, "dispatch")

      await controller.handlePaste(event)

      expect(event.preventDefault).not.toHaveBeenCalled()
      expect(dispatchSpy).not.toHaveBeenCalled()
    })
  })

  describe("handleDrop()", () => {
    it("processes dropped image files", async () => {
      const file = new File(["test"], "dropped.png", { type: "image/png" })

      const event = {
        preventDefault: vi.fn(),
        stopPropagation: vi.fn(),
        dataTransfer: {
          files: [file],
          types: ["Files"]
        }
      }

      vi.mocked(post).mockResolvedValue({
        ok: true,
        json: { url: "images/dropped.png" }
      })

      const dispatchSpy = vi.spyOn(controller, "dispatch")

      await controller.handleDrop(event)

      expect(event.preventDefault).toHaveBeenCalled()
      expect(dispatchSpy).toHaveBeenCalledWith("image-insert", {
        detail: { markdown: "![dropped.png](images/dropped.png)" }
      })
    })

    it("ignores non-image drops", async () => {
      const file = new File(["test"], "test.txt", { type: "text/plain" })

      const event = {
        preventDefault: vi.fn(),
        stopPropagation: vi.fn(),
        dataTransfer: {
          files: [file],
          types: ["Files"],
          items: [{ kind: "file", type: "text/plain" }]
        }
      }

      const dispatchSpy = vi.spyOn(controller, "dispatch")

      await controller.handleDrop(event)

      expect(dispatchSpy).not.toHaveBeenCalled()
    })
  })

  describe("drag and drop classes", () => {
    it("adds editor-drop-active class on dragenter", () => {
      const event = {
        preventDefault: vi.fn(),
        stopPropagation: vi.fn(),
        dataTransfer: {
          files: [],
          types: ["Files"]
        }
      }

      controller.handleDragEnter(event)

      expect(element.classList.contains("editor-drop-active")).toBe(true)
    })

    it("removes editor-drop-active class on dragleave", () => {
      element.classList.add("editor-drop-active")

      const event = {
        preventDefault: vi.fn(),
        stopPropagation: vi.fn(),
        dataTransfer: {
          files: [],
          types: ["Files"]
        }
      }

      controller.handleDragLeave(event)

      expect(element.classList.contains("editor-drop-active")).toBe(false)
    })
  })

  describe("error handling", () => {
    it("shows error alert on upload failure", async () => {
      const file = new File(["test"], "fail.png", { type: "image/png" })

      const event = {
        preventDefault: vi.fn(),
        stopPropagation: vi.fn(),
        dataTransfer: {
          files: [file],
          types: ["Files"]
        }
      }

      vi.mocked(post).mockResolvedValue({
        ok: false,
        json: { error: "Upload failed" }
      })

      await controller.handleDrop(event)

      expect(global.alert).toHaveBeenCalledWith("Failed to insert image: Upload failed")
    })
  })

  describe("disconnect()", () => {
    it("cleans up event listeners", () => {
      const removeSpy = vi.spyOn(element, "removeEventListener")
      const removePasteSpy = vi.spyOn(document, "removeEventListener")

      controller.disconnect()

      expect(removeSpy).toHaveBeenCalledWith("dragenter", controller.handleDragEnter)
      expect(removeSpy).toHaveBeenCalledWith("dragover", controller.handleDragOver)
      expect(removeSpy).toHaveBeenCalledWith("dragleave", controller.handleDragLeave)
      expect(removeSpy).toHaveBeenCalledWith("drop", controller.handleDrop)
      expect(removePasteSpy).toHaveBeenCalledWith("paste", controller.handlePaste)
    })
  })
})