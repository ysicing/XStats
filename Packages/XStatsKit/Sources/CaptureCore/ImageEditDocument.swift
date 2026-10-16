// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageTool: String, CaseIterable, Identifiable, Sendable {
  case crop, arrow, rectangle, pen, text, redact
  public var id: String { rawValue }
}

public struct ImageEditDocument: Sendable {
  public let original: CGImage
  public private(set) var annotations: [ImageAnnotation] = []
  public private(set) var cropRect: CGRect
  private struct Revision: Sendable {
    var annotations: [ImageAnnotation]
    var crop: CGRect
  }
  private var history: [Revision] = []
  private var future: [Revision] = []
  public init(image: CGImage) {
    original = image
    cropRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
  }
  public var canUndo: Bool { !history.isEmpty }
  public var canRedo: Bool { !future.isEmpty }
  private mutating func checkpoint() {
    history.append(Revision(annotations: annotations, crop: cropRect))
    if history.count > 100 { history.removeFirst() }
    future.removeAll()
  }
  public mutating func add(_ annotation: ImageAnnotation) {
    guard !annotation.points.isEmpty, annotations.count < 1000 else { return }
    checkpoint()
    annotations.append(annotation)
  }
  /// A detection result is one user action and one undo step. Reject oversized batches atomically.
  @discardableResult public mutating func add(_ annotations: [ImageAnnotation]) -> Bool {
    guard !annotations.isEmpty, self.annotations.count + annotations.count <= 1000,
      annotations.allSatisfy({ !$0.points.isEmpty })
    else { return false }
    checkpoint()
    self.annotations.append(contentsOf: annotations)
    return true
  }
  public mutating func crop(to rect: CGRect) throws {
    let rect = rect.standardized.intersection(cropRect).integral
    guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { throw CaptureError.invalidRegion }
    checkpoint()
    cropRect = rect
  }
  public mutating func update(_ annotation: ImageAnnotation) {
    guard let index = annotations.firstIndex(where: { $0.id == annotation.id }),
      annotations[index] != annotation
    else { return }
    checkpoint()
    annotations[index] = annotation
  }
  public mutating func remove(id: UUID) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    checkpoint()
    annotations.remove(at: index)
  }
  public func annotation(at point: CGPoint, tolerance: CGFloat) -> ImageAnnotation? {
    annotations.reversed().first { $0.contains(point, tolerance: tolerance) }
  }
  public mutating func undo() {
    guard let previous = history.popLast() else { return }
    future.append(Revision(annotations: annotations, crop: cropRect))
    annotations = previous.annotations
    cropRect = previous.crop
  }
  public mutating func redo() {
    guard let next = future.popLast() else { return }
    history.append(Revision(annotations: annotations, crop: cropRect))
    annotations = next.annotations
    cropRect = next.crop
  }
  public func render(mosaics: ImageMosaics? = nil) throws -> CGImage {
    try Task.checkCancellation()
    guard
      let context = CGContext(
        data: nil, width: Int(cropRect.width), height: Int(cropRect.height), bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CaptureError.captureFailed }
    context.translateBy(x: -cropRect.minX, y: cropRect.height + cropRect.minY)
    context.scaleBy(x: 1, y: -1)
    context.saveGState()
    context.translateBy(x: 0, y: CGFloat(original.height))
    context.scaleBy(x: 1, y: -1)
    context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
    context.restoreGState()
    let mosaics =
      try mosaics
      ?? (annotations.contains { $0.tool == .redact } ? ImageMosaics(image: original) : nil)
    for item in annotations {
      try Task.checkCancellation()
      item.draw(in: context, mosaics: mosaics)
    }
    try Task.checkCancellation()
    guard let result = context.makeImage() else { throw CaptureError.captureFailed }
    return result
  }
  public func encoded(jpeg: Bool = false) throws -> Data {
    try Task.checkCancellation()
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil)
    else { throw CaptureError.exportFailed }
    CGImageDestinationAddImage(
      destination, try render(),
      jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
    try Task.checkCancellation()
    guard CGImageDestinationFinalize(destination) else { throw CaptureError.exportFailed }
    try Task.checkCancellation()
    return data as Data
  }
  /// 只向相邻临时文件分块写入，取消后不提交到用户选择的位置。
  public func save(to url: URL, jpeg: Bool = false) throws {
    let bytes = try encoded(jpeg: jpeg)
    try Task.checkCancellation()
    let staging = url.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString).capture-image")
    defer { try? FileManager.default.removeItem(at: staging) }
    guard FileManager.default.createFile(atPath: staging.path, contents: nil) else {
      throw CaptureError.exportFailed
    }
    let handle = try FileHandle(forWritingTo: staging)
    defer { try? handle.close() }
    for offset in stride(from: 0, to: bytes.count, by: 512 * 1024) {
      try Task.checkCancellation()
      try handle.write(contentsOf: bytes[offset..<min(offset + 512 * 1024, bytes.count)])
    }
    try handle.close()
    try Task.checkCancellation()
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
    } else {
      try FileManager.default.moveItem(at: staging, to: url)
    }
  }
}
