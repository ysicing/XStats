// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 新增规则默认只有预览权限，沿用既有应用身份、目录和运行状态保护。
public enum PreviewRuleCatalog {
  public static var rules: [CleanRule] {
    [
      // Mole 2ef974753572：lib/clean/app_caches.sh:910，仅登记实际列出的缓存目录。
      ApplicationCacheCatalog.cache(
        id: "preview.teams", name: "Microsoft Teams",
        directories: ["Caches"], names: ["com.microsoft.teams2"],
        bundleIDs: ["com.microsoft.teams2"], applicationNames: ["Microsoft Teams"],
        root: "Library", previewOnly: true)
    ]
  }
}
