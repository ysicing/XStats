import AppKit

/// 网络页面共用的包内 SVG 缓存，不依赖账号登录界面。
@MainActor
final class LogoCache {
    static let shared = LogoCache()
    private var images: [String: NSImage] = [:]

    func image(named name: String, template: Bool) -> NSImage? {
        // 同一 SVG 会同时用于彩色页面和单色菜单栏，模板属性必须分别缓存。
        let key = "\(name):\(template)"
        if let image = images[key] { return image }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        images[key] = image
        return image
    }
}
