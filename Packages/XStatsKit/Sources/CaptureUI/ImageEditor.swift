// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import Observation
import CaptureCore
import Localization

extension ImageTool {
    var title: String {
        switch self {
        case .crop: tr("裁剪"); case .arrow: tr("箭头"); case .rectangle: tr("矩形")
        case .pen: tr("画笔"); case .text: tr("文字"); case .redact: tr("遮挡")
        }
    }
}

@MainActor @Observable final class ImageEditorModel {
    var document: ImageEditDocument
    var image: NSImage
    var tool: ImageTool = .arrow
    var text = ""
    var dirty = true
    var rendering = false
    var imageIsCurrent = true
    var error: String?
    var onPin: (CGImage) -> Void = { _ in }
    private var renderTask: Task<Void, Never>?
    init(image: CGImage) {
        document = ImageEditDocument(image: image)
        self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }
    func commit(_ points: [CGPoint]) {
        guard !rendering, !points.isEmpty else { return }
        do {
            if tool == .crop, let first = points.first, let last = points.last {
                try document.crop(to: CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(first.x - last.x), height: abs(first.y - last.y)))
            } else if tool != .text || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.add(ImageAnnotation(tool: tool, points: points, text: text))
            }
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    func undo() { document.undo(); refresh() }
    func redo() { document.redo(); refresh() }
    private func refresh() {
        renderTask?.cancel()
        rendering = true; dirty = true; imageIsCurrent = false; error = nil
        let document = document
        renderTask = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try document.render() }.value
                guard !Task.isCancelled else { return }
                image = NSImage(cgImage: result, size: CGSize(width: result.width, height: result.height))
                imageIsCurrent = true
            } catch { self.error = error.localizedDescription }
            rendering = false
        }
    }
    func copy() {
        guard !rendering, imageIsCurrent else { return }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { dirty = false }
        else { error = CaptureError.exportFailed.localizedDescription }
    }
    func save(jpeg: Bool) {
        guard !rendering else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = jpeg ? [.jpeg] : [.png]
        panel.nameFieldStringValue = "Screenshot.\(jpeg ? "jpg" : "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let document = document
        rendering = true; error = nil
        renderTask = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let bytes = try document.encoded(jpeg: jpeg)
                    try Task.checkCancellation()
                    try bytes.write(to: url, options: .atomic)
                }.value
                dirty = false
            } catch { self.error = error.localizedDescription }
            rendering = false
        }
    }
    func pin() {
        guard imageIsCurrent, !rendering, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        onPin(cgImage)
    }
    func finishPendingWork() async { await renderTask?.value }
}

@MainActor final class ImageEditorWindow: NSWindowController, NSWindowDelegate {
    let model: ImageEditorModel
    var onClose: () -> Void = {}
    init(image: CGImage) {
        model = ImageEditorModel(image: image)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 950, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = tr("截图编辑")
        window.minSize = CGSize(width: 700, height: 450)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: ImageEditorView(model: model).environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight).environment(\.locale, L10n.locale))
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.rendering else { return false }
        guard model.dirty else { return true }
        let alert = NSAlert()
        alert.messageText = tr("丢弃未保存的截图？")
        alert.addButton(withTitle: tr("丢弃")); alert.addButton(withTitle: tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func windowWillClose(_ notification: Notification) { onClose() }
}

private struct ImageEditorView: View {
    @Bindable var model: ImageEditorModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(tr("标注工具"), selection: $model.tool) { ForEach(ImageTool.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                Button(tr("撤销"), systemImage: "arrow.uturn.backward") { model.undo() }.disabled(!model.document.canUndo)
                Button(tr("重做"), systemImage: "arrow.uturn.forward") { model.redo() }.disabled(!model.document.canRedo)
            }.padding()
            if model.tool == .text { TextField(tr("标注文字"), text: $model.text).textFieldStyle(.roundedBorder).padding(.horizontal).padding(.bottom, 8) }
            ImageCanvas(model: model)
                .background(.quaternary)
            HStack {
                if model.rendering { ProgressView().controlSize(.small) }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button(tr("置顶")) { model.pin() }.disabled(!model.imageIsCurrent)
                Button(tr("复制")) { model.copy() }.keyboardShortcut("c", modifiers: .command).disabled(!model.imageIsCurrent)
                Menu(tr("保存")) {
                    Button("PNG") { model.save(jpeg: false) }
                    Button("JPEG") { model.save(jpeg: true) }
                }
            }.padding()
        }.disabled(model.rendering)
    }
}

private struct ImageCanvas: NSViewRepresentable {
    let model: ImageEditorModel
    func makeNSView(context: Context) -> ImageCanvasView { ImageCanvasView(model: model) }
    func updateNSView(_ view: ImageCanvasView, context: Context) { view.needsDisplay = true }
}

@MainActor private final class ImageCanvasView: NSView {
    let model: ImageEditorModel
    private var points: [CGPoint] = []
    override var isFlipped: Bool { true }
    init(model: ImageEditorModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    private var imageRect: CGRect {
        let size = model.image.size
        let scale = min((bounds.width - 24) / size.width, (bounds.height - 24) / size.height)
        let width = max(1, size.width * scale), height = max(1, size.height * scale)
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect, crop = model.document.cropRect
        return CGPoint(x: crop.minX + min(max(0, (point.x - rect.minX) / rect.width), 1) * crop.width,
                       y: crop.minY + min(max(0, (point.y - rect.minY) / rect.height), 1) * crop.height)
    }
    override func mouseDown(with event: NSEvent) {
        guard !model.rendering, imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        points = [imagePoint(event)]; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !points.isEmpty, points.count < 4096 else { return }
        if model.tool == .pen { points.append(imagePoint(event)) }
        else { points = [points[0], imagePoint(event)] }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard !points.isEmpty else { return }
        if model.tool != .pen { points = [points[0], imagePoint(event)] }
        model.commit(points); points.removeAll(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        model.image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let first = points.first else { return }
        let path = NSBezierPath()
        let crop = model.document.cropRect, rect = imageRect
        let scale = rect.width / crop.width
        path.move(to: CGPoint(x: rect.minX + (first.x - crop.minX) * scale, y: rect.minY + (first.y - crop.minY) * scale))
        for point in points.dropFirst() { path.line(to: CGPoint(x: rect.minX + (point.x - crop.minX) * scale, y: rect.minY + (point.y - crop.minY) * scale)) }
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 2; path.stroke()
    }
}
