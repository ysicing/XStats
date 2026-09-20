import AppKit

/// 网络页面共用的包内 SVG 缓存，不依赖账号登录界面。
@MainActor
final class LogoCache {
    static let shared = LogoCache()
    private var images: [String: NSImage] = [:]

    func image(named name: String, template: Bool) -> NSImage? {
        if let image = images[name] { return image }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        images[name] = image
        return image
    }
}
