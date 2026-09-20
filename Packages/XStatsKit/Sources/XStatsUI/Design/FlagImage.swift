import AppKit
import SwiftUI

/// 国旗：使用包内由 flag-icons（MIT）渲染好的 PNG，不使用 emoji。
/// 不直接读 SVG：系统的 SVG 渲染器对嵌套 <use> 等写法支持不好，中国、乌兹别克斯坦等旗子会画错（见 Scripts/render_flags.sh）
struct FlagImage: View {
    let countryCode: String
    var height: CGFloat = DS.Space.s3

    var body: some View {
        if let image = FlagCache.shared.image(for: countryCode) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm / 2))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm / 2).strokeBorder(DS.Palette.border, lineWidth: DS.Size.stroke))
                .accessibilityHidden(true)
        }
    }
}

@MainActor
final class FlagCache {
    static let shared = FlagCache()
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func image(for countryCode: String) -> NSImage? {
        let code = countryCode.lowercased()
        // 只接受两位字母，避免拼出包外路径
        guard code.count == 2, code.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
        if let image = images[code] { return image }
        guard !missing.contains(code) else { return nil }
        guard let url = Bundle.module.url(forResource: code, withExtension: "png", subdirectory: "Flags"),
              let image = NSImage(contentsOf: url) else {
            missing.insert(code)
            return nil
        }
        images[code] = image
        return image
    }
}
