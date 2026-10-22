// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import Observation
import CaptureCore
import Localization
import os

extension ImageTool {
  var title: String {
    switch self {
    case .crop: tr("裁剪")
    case .arrow: tr("箭头")
    case .rectangle: tr("矩形")
    case .pen: tr("画笔")
    case .text: tr("文字")
    case .redact: tr("马赛克")
    }
  }
}

@MainActor @Observable final class ImageEditorModel {
  var document: ImageEditDocument
  var image: NSImage
  var tool: ImageTool?
  var selectedID: UUID?
  var color = NSColor.systemRed
  var lineWidth: CGFloat = 4
  var fontSize: CGFloat = 26
  var mosaicSize: MosaicSize = .medium
  var mosaics: ImageMosaics?
  private(set) var detecting = false
  var detectedCount: Int?
  private let mosaicWorker: Task<ImageMosaics, Error>
  private var detectRegions: (@Sendable (CGImage, CGRect) throws -> [CGRect])?
  private var recognitionID: UUID?
  private var cancelRecognition: (() -> Void)?
  private static let logger = Logger(
    subsystem: CaptureRequest.bundleIdentifier, category: "image-editor")
  var editingText = false
  @ObservationIgnored var finishEditing: () -> Void = {}
  var dirty = true
  var rendering = false
  var imageIsCurrent = true
  var canPin = true {
    didSet {
      // 录制禁用置顶后，旧请求即失效；重新允许时不能复活仍在等待图片处理的请求。
      if !canPin { pinGeneration = UUID() }
    }
  }
  private var pinGeneration = UUID()
  var error: String?
  var onPin: (CGImage) -> Void = { _ in }
  private(set) var terminating = false
  private var renderTask: Task<Void, Never>?
  private var cancelWorker: (() -> Void)?
  private var pendingTasks: [UUID: Task<Void, Never>] = [:]
  private let saveImage: @Sendable (ImageEditDocument, URL, Bool, ImageMosaics?) throws -> Void
  init(
    image: CGImage,
    makeMosaics: @escaping @Sendable (CGImage) throws -> ImageMosaics = {
      try ImageMosaics(image: $0)
    },
    saveImage: @escaping @Sendable (ImageEditDocument, URL, Bool, ImageMosaics?) throws -> Void = {
      try $0.save(to: $1, jpeg: $2, mosaics: $3)
    }
  ) {
    self.saveImage = saveImage
    let worker = Task.detached(priority: .userInitiated) { try makeMosaics(image) }
    mosaicWorker = worker
    document = ImageEditDocument(image: image)
    self.image = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    let id = UUID()
    pendingTasks[id] = Task {
      defer { pendingTasks[id] = nil }
      if let result = try? await worker.value, !terminating { mosaics = result }
    }
  }
  convenience init(
    image: CGImage, detectRegions: @escaping @Sendable (CGImage, CGRect) throws -> [CGRect]
  ) {
    self.init(image: image)
    self.detectRegions = detectRegions
  }
  var selected: ImageAnnotation? { document.annotations.first { $0.id == selectedID } }
  var effectiveTool: ImageTool? { selected?.tool ?? tool }
  func select(_ id: UUID?) {
    selectedID = id
    if let item = selected {
      color = NSColor(cgColor: item.color) ?? .systemRed
      lineWidth = item.lineWidth
      fontSize = item.fontSize
      mosaicSize = item.mosaicSize
    }
  }
  func annotation(tool: ImageTool, points: [CGPoint], text: String = "") -> ImageAnnotation {
    ImageAnnotation(
      tool: tool, points: points, text: text, color: color.cgColor, lineWidth: lineWidth,
      fontSize: fontSize, mosaicSize: mosaicSize)
  }
  func commit(_ item: ImageAnnotation) {
    guard !terminating, !rendering, !detecting, !item.points.isEmpty else { return }
    if item.tool == .crop {
      do {
        try document.crop(to: item.bounds)
        select(nil)
        refresh()
      } catch { self.error = error.localizedDescription }
      return
    }
    guard item.tool != .text || !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    if document.annotations.contains(where: { $0.id == item.id }) {
      guard selected != item else { return }
      document.update(item)
    } else {
      document.add(item)
    }
    tool = nil
    select(item.id)
    refresh()
  }
  func applyStyle() {
    // Inline text uses the current style when committed; avoid replacing its draft mid-edit.
    if editingText {
      if let item = selected, item.color != color.cgColor || item.fontSize != fontSize {
        dirty = true
      }
      return
    }
    guard var item = selected else { return }
    if item.tool != .redact { item.color = color.cgColor }
    item.lineWidth = lineWidth
    item.fontSize = fontSize
    item.mosaicSize = mosaicSize
    commit(item)
  }
  func deleteSelected() {
    guard !terminating, !rendering, !detecting, let id = selectedID else { return }
    finishEditing()
    document.remove(id: id)
    select(nil)
    refresh()
  }
  func undo() {
    guard !terminating, !detecting else { return }
    finishEditing()
    document.undo()
    select(nil)
    refresh()
  }
  func redo() {
    guard !terminating, !detecting else { return }
    finishEditing()
    document.redo()
    select(nil)
    refresh()
  }
  private func refresh() {
    guard !terminating else { return }
    detectedCount = nil
    cancelPendingWork()
    rendering = true
    dirty = true
    imageIsCurrent = false
    error = nil
    let document = document
    let mosaicWorker = mosaicWorker
    let worker = Task.detached(priority: .userInitiated) {
      // 普通标注不依赖马赛克；预计算失败不应阻断红框、文字或撤销后的导出。
      let mosaics =
        document.annotations.contains { $0.tool == .redact }
        ? try await mosaicWorker.value : nil
      try Task.checkCancellation()
      return try document.render(mosaics: mosaics)
    }
    cancelWorker = { worker.cancel() }
    let id = UUID()
    let task = Task {
      defer { pendingTasks[id] = nil }
      do {
        let result = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard !Task.isCancelled else { return }
        image = NSImage(cgImage: result, size: CGSize(width: result.width, height: result.height))
        imageIsCurrent = true
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
      rendering = false
      cancelWorker = nil
    }
    renderTask = task
    pendingTasks[id] = task
  }
  func detectSensitiveInformation() {
    guard !terminating, !rendering, !detecting else { return }
    finishEditing()
    // Committing an inline text draft may start rendering; retry after it finishes.
    guard !rendering else { return }
    detecting = true
    detectedCount = nil
    error = nil
    let id = UUID()
    recognitionID = id
    let original = document.original
    let crop = document.cropRect
    let detectRegions = detectRegions
    let detector = SensitiveTextDetector()
    let worker = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      return try detectRegions?(original, crop) ?? detector.regions(in: original, crop: crop)
    }
    cancelRecognition = {
      worker.cancel()
      detector.cancel()
    }
    Self.logger.info("Sensitive text recognition started")
    pendingTasks[id] = Task {
      defer {
        pendingTasks[id] = nil
        // Only one worker can exist; cancellation keeps the slot occupied until it exits.
        recognitionID = nil
        detecting = false
        cancelRecognition = nil
      }
      do {
        let regions = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
          detector.cancel()
        }
        guard !terminating, recognitionID == id, !Task.isCancelled else { return }
        let existing = document.annotations.filter { $0.tool == .redact }
        let items = regions.filter { rect in !existing.contains { $0.bounds.contains(rect) } }.map {
          rect in
          ImageAnnotation(
            tool: .redact, points: [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)],
            mosaicSize: mosaicSize)
        }
        if !items.isEmpty {
          guard document.add(items) else {
            error = tr("标注数量已达上限，请先删除部分标注。")
            return
          }
          select(nil)
          tool = nil
          refresh()
        }
        detectedCount = items.count
        Self.logger.info("Sensitive text recognition finished; added \(items.count) masks")
      } catch {
        guard !terminating, recognitionID == id, !Task.isCancelled else { return }
        self.error = tr("敏感信息识别未完成，请重试。")
        Self.logger.error("Sensitive text recognition failed")
      }
    }
  }
  func cancelDetection() {
    guard detecting, recognitionID != nil else { return }
    cancelRecognition?()
    cancelRecognition = nil
    recognitionID = nil
    Self.logger.info("Sensitive text recognition cancelled")
  }
  func copy() {
    finishEditing()
    Task {
      await waitForPendingWork()
      guard !terminating, !rendering, !detecting, imageIsCurrent else { return }
      NSPasteboard.general.clearContents()
      if NSPasteboard.general.writeObjects([image]) {
        dirty = false
      } else {
        error = CaptureError.exportFailed.localizedDescription
      }
    }
  }
  func save(jpeg: Bool) {
    finishEditing()
    Task {
      await waitForPendingWork()
      guard !terminating, !rendering, !detecting else { return }
      let panel = NSSavePanel()
      panel.allowedContentTypes = jpeg ? [.jpeg] : [.png]
      panel.nameFieldStringValue = "Screenshot.\(jpeg ? "jpg" : "png")"
      guard panel.runModal() == .OK, let url = panel.url else { return }
      save(to: url, jpeg: jpeg)
    }
  }
  func save(to url: URL, jpeg: Bool) {
    guard !terminating, !rendering, !detecting else { return }
    let document = document
    rendering = true
    error = nil
    let saveImage = saveImage
    let mosaicWorker = mosaicWorker
    let worker = Task.detached(priority: .userInitiated) {
      // 复用编辑器预计算；失败时由 render 按需重试，仍不允许遗漏遮挡。
      let mosaics =
        document.annotations.contains { $0.tool == .redact }
        ? try? await mosaicWorker.value : nil
      try Task.checkCancellation()
      try saveImage(document, url, jpeg, mosaics)
    }
    cancelWorker = { worker.cancel() }
    let id = UUID()
    let task = Task {
      defer { pendingTasks[id] = nil }
      do {
        try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard !Task.isCancelled else { return }
        dirty = false
      } catch {
        guard !Task.isCancelled else { return }
        self.error = CaptureError.exportFailed.localizedDescription
      }
      rendering = false
      cancelWorker = nil
    }
    renderTask = task
    pendingTasks[id] = task
  }
  @discardableResult
  func pin() -> Task<Void, Never>? {
    guard canPin else { return nil }
    let generation = pinGeneration
    finishEditing()
    return Task {
      await waitForPendingWork()
      guard canPin, generation == pinGeneration, !terminating, imageIsCurrent, !rendering,
        !detecting,
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { return }
      onPin(cgImage)
    }
  }
  func cancelPendingWork(terminating: Bool = false) {
    if terminating {
      self.terminating = true
      cancelDetection()
      mosaicWorker.cancel()
    }
    renderTask?.cancel()
    cancelWorker?()
    renderTask = nil
    cancelWorker = nil
    rendering = false
  }
  /// 取消不等于工作线程已退出；保留所有未收尾任务，直到编码与临时文件清理完成。
  func waitForPendingWork() async {
    while let task = pendingTasks.values.first { await task.value }
  }
}

@MainActor final class ImageEditorWindow: NSWindowController, NSWindowDelegate {
  let model: ImageEditorModel
  var onClose: () -> Void = {}
  private var closeTask: Task<Void, Never>?
  private var closeAlert: NSAlert?
  private var closed = false
  init(image: CGImage) {
    model = ImageEditorModel(image: image)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 950, height: 680),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    super.init(window: window)
    window.minSize = CGSize(width: 700, height: 450)
    window.isReleasedWhenClosed = false
    window.delegate = self
    applyLanguage(L10n.language)
    window.center()
  }
  required init?(coder: NSCoder) { fatalError() }
  func applyLanguage(_ language: AppLanguage) {
    model.finishEditing()
    window?.title = L10n.translate("截图编辑", language: language)
    let content = NSHostingView(
      rootView: ImageEditorView(model: model).environment(
        \.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight
      ).environment(\.locale, L10n.locale(for: language)))
    // This resizable editor has an explicit minimum; property changes must not resize it.
    content.sizingOptions = []
    window?.contentView = content
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !closed, closeTask == nil, closeAlert == nil else { return false }
    model.finishEditing()
    model.cancelDetection()
    if model.rendering || model.detecting {
      closeTask = Task { [weak self] in
        guard let self else { return }
        await model.waitForPendingWork()
        guard !Task.isCancelled, !closed else { return }
        closeTask = nil
        sender.performClose(nil)
      }
      return false
    }
    guard model.dirty else { return true }
    let alert = NSAlert()
    alert.messageText = tr("丢弃未保存的截图？")
    alert.addButton(withTitle: tr("丢弃"))
    alert.addButton(withTitle: tr("取消"))
    closeAlert = alert
    alert.beginSheetModal(for: sender) { [weak self] response in
      guard let self else { return }
      closeAlert = nil
      guard !closed, response == .alertFirstButtonReturn else { return }
      sender.close()
    }
    return false
  }
  func windowWillClose(_ notification: Notification) {
    closed = true
    closeTask?.cancel()
    closeTask = nil
    if let sheet = window?.attachedSheet {
      window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }
    closeAlert = nil
    model.cancelPendingWork(terminating: true)
    onClose()
  }
}

private struct ImageEditorView: View {
  @Bindable var model: ImageEditorModel
  private let colors: [NSColor] = [
    .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black,
  ]
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        toolButton(nil, title: tr("选择"), symbol: "cursorarrow")
        Divider().frame(height: 24)
        ForEach(ImageTool.allCases) { tool in
          toolButton(tool, title: tool.title, symbol: tool.symbol)
        }
        Spacer(minLength: 12)
        Button {
          model.undo()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .help(tr("撤销")).accessibilityLabel(tr("撤销"))
        .keyboardShortcut("z", modifiers: .command).disabled(!model.document.canUndo)
        Button {
          model.redo()
        } label: {
          Image(systemName: "arrow.uturn.forward")
        }
        .help(tr("重做")).accessibilityLabel(tr("重做"))
        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.document.canRedo)
      }.padding(.horizontal, 16).padding(.vertical, 12).disabled(model.detecting)
      Divider()
      HStack(spacing: 12) {
        if let tool = model.effectiveTool, tool != .crop, tool != .redact {
          Text(tr("颜色")).font(.caption).foregroundStyle(.secondary)
          ForEach(colors.indices, id: \.self) { index in
            Button {
              model.color = colors[index]
              model.applyStyle()
            } label: {
              Circle().fill(Color(nsColor: colors[index])).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 1))
                .padding(3)
                .overlay(
                  Circle().stroke(
                    colorIsSelected(colors[index]) ? Color.accentColor : .clear, lineWidth: 2))
            }.buttonStyle(.borderless)
              .help(tr(colorNames[index])).accessibilityLabel(tr(colorNames[index]))
              .accessibilityAddTraits(colorIsSelected(colors[index]) ? .isSelected : [])
          }
          Divider().frame(height: 18)
          if tool == .text {
            Stepper(value: $model.fontSize, in: 12...96, step: 2) {
              Text(
                tr("字号 {}").replacingOccurrences(
                  of: "{}", with: Int(model.fontSize).formatted(.number.locale(L10n.locale))))
            }.fixedSize().onChange(of: model.fontSize) { model.applyStyle() }
          } else {
            Picker(tr("粗细"), selection: $model.lineWidth) {
              Text(tr("细")).tag(CGFloat(2))
              Text(tr("中")).tag(CGFloat(4))
              Text(tr("粗")).tag(CGFloat(8))
            }.fixedSize().onChange(of: model.lineWidth) { model.applyStyle() }
          }
        } else if model.effectiveTool == .redact {
          Picker(tr("颗粒大小"), selection: $model.mosaicSize) {
            Text(tr("细")).tag(MosaicSize.fine)
            Text(tr("中")).tag(MosaicSize.medium)
            Text(tr("粗")).tag(MosaicSize.coarse)
          }.pickerStyle(.segmented).fixedSize()
            .onChange(of: model.mosaicSize) { model.applyStyle() }

        }
        Spacer()
        if model.effectiveTool == .redact {
          Button(tr("一键打码"), systemImage: "sparkle.magnifyingglass") {
            model.detectSensitiveInformation()
          }
          .help(tr("在本机识别手机号、邮箱、身份证号和银行卡号。"))
        }
        if model.selected != nil {
          Button(tr("删除标注"), systemImage: "trash") { model.deleteSelected() }
        }
      }.frame(minHeight: 28).padding(.horizontal, 16).padding(.vertical, 8).disabled(
        model.detecting)
      ImageCanvas(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).background(
        .quaternary)
      HStack {
        Text(instruction).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        if model.rendering { ProgressView().controlSize(.small) }
        Button(tr("置顶"), systemImage: "pin") { model.pin() }.disabled(
          !model.imageIsCurrent || !model.canPin)
        Button(tr("复制"), systemImage: "doc.on.doc") { model.copy() }
          .keyboardShortcut("c", modifiers: .command).disabled(!model.imageIsCurrent)
        Button(tr("保存"), systemImage: "square.and.arrow.down") { model.save(jpeg: false) }
          .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
        Menu {
          Button("PNG") { model.save(jpeg: false) }
          Button("JPEG") { model.save(jpeg: true) }
        } label: {
          Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton).fixedSize().help(tr("图片格式")).accessibilityLabel(tr("图片格式"))
      }.padding(16).disabled(model.detecting)
      if model.detecting {
        HStack {
          ProgressView().controlSize(.small)
          Text(tr("正在识别敏感信息…")).font(.caption)
          Button(tr("取消")) { model.cancelDetection() }
        }.padding(.horizontal, 16).padding(.bottom, 12)
      } else if let count = model.detectedCount {
        Text(
          count == 0
            ? tr("未发现新的敏感信息，可手动补充马赛克。")
            : tr("已添加 {} 处马赛克，请检查并补充遗漏。").replacingOccurrences(
              of: "{}", with: count.formatted(.number.locale(L10n.locale)))
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).padding(.bottom, 12)
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 16).padding(
          .bottom, 12)
      }
    }.disabled(model.rendering || model.terminating)
  }
  private var colorNames: [String] { ["红色", "橙色", "黄色", "绿色", "蓝色", "白色", "黑色"] }
  private func colorIsSelected(_ color: NSColor) -> Bool {
    guard let current = model.color.usingColorSpace(.sRGB),
      let candidate = color.usingColorSpace(.sRGB)
    else { return false }
    return abs(current.redComponent - candidate.redComponent) < 0.005
      && abs(current.greenComponent - candidate.greenComponent) < 0.005
      && abs(current.blueComponent - candidate.blueComponent) < 0.005
  }
  private var instruction: String {
    if model.selected != nil { return tr("拖动标注移动，拖动控制点调整；双击文字编辑，Delete 删除。") }
    if model.tool == .text { return tr("点击图片输入文字，按回车完成，Esc 取消。") }
    if model.tool == nil { return tr("点击标注选中，拖动移动；Esc 取消选择。") }
    return tr("在图片上拖动绘制，Esc 取消。")
  }
  private func toolButton(_ tool: ImageTool?, title: String, symbol: String) -> some View {
    Button {
      model.finishEditing()
      model.select(nil)
      model.tool = tool
    } label: {
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 17))
        Text(title).font(.caption)
      }.frame(minWidth: 36, minHeight: 38).padding(.horizontal, 4)
        .foregroundStyle(model.tool == tool ? Color.accentColor : .primary)
        .background(
          model.tool == tool ? Color.accentColor.opacity(0.12) : .clear,
          in: RoundedRectangle(cornerRadius: 6))
    }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
      .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
  }
}

extension ImageTool {
  var symbol: String {
    switch self {
    case .crop: "crop"
    case .arrow: "arrow.up.right"
    case .rectangle: "rectangle"
    case .pen: "pencil.tip"
    case .text: "textformat"
    case .redact: "square.grid.3x3.fill"
    }
  }
}
