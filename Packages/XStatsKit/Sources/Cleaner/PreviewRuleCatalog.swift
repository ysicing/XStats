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
        root: "Library", previewOnly: true),
      // Mole 2ef974753572: lib/clean/app_caches.sh:906.
      ApplicationCacheCatalog.cache(
        id: "preview.zoom", name: "Zoom",
        directories: ["Caches"], names: ["us.zoom.xos"],
        bundleIDs: [], applicationNames: ["Zoom", "zoom.us"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/app_caches.sh:908.
      ApplicationCacheCatalog.cache(
        id: "preview.telegram", name: "Telegram",
        directories: ["Caches"], names: ["ru.keepcoder.Telegram"],
        bundleIDs: [], applicationNames: ["Telegram"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/app_caches.sh:911.
      ApplicationCacheCatalog.cache(
        id: "preview.whatsapp", name: "WhatsApp",
        directories: ["Caches"], names: ["net.whatsapp.WhatsApp"],
        bundleIDs: [], applicationNames: ["WhatsApp"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/app_caches.sh:945.
      ApplicationCacheCatalog.cache(
        id: "preview.chatgpt", name: "ChatGPT",
        directories: ["Caches"], names: ["com.openai.chat"],
        bundleIDs: [], applicationNames: ["ChatGPT"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/app_caches.sh:964.
      ApplicationCacheCatalog.cache(
        id: "preview.figma", name: "Figma",
        directories: ["Caches"], names: ["com.figma.Desktop"],
        bundleIDs: [], applicationNames: ["Figma"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2145.
      ApplicationCacheCatalog.cache(
        id: "preview.opera", name: "Opera",
        directories: ["Caches"], names: ["com.operasoftware.Opera"],
        bundleIDs: [], applicationNames: ["Opera"], root: "Library",
        category: .browser, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2148.
      ApplicationCacheCatalog.cache(
        id: "preview.vivaldi", name: "Vivaldi",
        directories: ["Caches"], names: ["com.vivaldi.Vivaldi"],
        bundleIDs: [], applicationNames: ["Vivaldi"], root: "Library",
        category: .browser, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2168.
      ApplicationCacheCatalog.cache(
        id: "preview.orion", name: "Orion",
        directories: ["Caches"], names: ["com.kagi.kagimacOS"],
        bundleIDs: [], applicationNames: ["Orion"], root: "Library",
        category: .browser, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:794.
      ApplicationCacheCatalog.cache(
        id: "preview.dropbox", name: "Dropbox",
        directories: ["Caches"], names: ["com.getdropbox.dropbox"],
        bundleIDs: [], applicationNames: ["Dropbox"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2215.
      ApplicationCacheCatalog.cache(
        id: "preview.googleDrive", name: "Google Drive",
        directories: ["Caches"], names: ["com.google.GoogleDrive"],
        bundleIDs: [], applicationNames: ["Google Drive"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2235.
      ApplicationCacheCatalog.cache(
        id: "preview.oneDrive", name: "OneDrive",
        directories: ["Caches"], names: ["com.microsoft.OneDrive"],
        bundleIDs: [], applicationNames: ["OneDrive"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2258.
      ApplicationCacheCatalog.cache(
        id: "preview.word", name: "Microsoft Word",
        directories: ["Caches"], names: ["com.microsoft.Word"],
        bundleIDs: [], applicationNames: ["Microsoft Word"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2265.
      ApplicationCacheCatalog.cache(
        id: "preview.excel", name: "Microsoft Excel",
        directories: ["Caches"], names: ["com.microsoft.Excel"],
        bundleIDs: [], applicationNames: ["Microsoft Excel"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2272.
      ApplicationCacheCatalog.cache(
        id: "preview.powerpoint", name: "Microsoft PowerPoint",
        directories: ["Caches"], names: ["com.microsoft.Powerpoint"],
        bundleIDs: [], applicationNames: ["Microsoft PowerPoint"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2273.
      ApplicationCacheCatalog.cache(
        id: "preview.outlook", name: "Microsoft Outlook",
        directories: ["Caches"], names: ["com.microsoft.Outlook"],
        bundleIDs: [], applicationNames: ["Microsoft Outlook"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/app_caches.sh:444、447.
      ApplicationCacheCatalog.cache(
        id: "preview.zed", name: "Zed",
        directories: ["Caches"], names: ["Zed"],
        bundleIDs: [], applicationNames: ["Zed"], root: "Library",
        category: .developer, previewOnly: true,
        additionalPaths: ["Library/Application Support/Zed/node/cache"]),
      // Mole 2ef974753572: lib/clean/dev.sh:864、865.
      ApplicationCacheCatalog.cache(
        id: "preview.poetry", name: "Poetry",
        directories: ["Caches/pypoetry"], names: ["artifacts", "cache"],
        bundleIDs: [], applicationNames: ["Poetry"], root: "Library",
        category: .developer, previewOnly: true, tracksApplicationPresence: false),
      // Mole 2ef974753572: lib/clean/dev.sh:4181.
      ApplicationCacheCatalog.cache(
        id: "preview.postman", name: "Postman",
        directories: ["Caches"], names: ["com.postmanlabs.mac"],
        bundleIDs: [], applicationNames: ["Postman"], root: "Library",
        category: .developer, previewOnly: true),
      // Mole 2ef974753572: lib/clean/dev.sh:4182.
      ApplicationCacheCatalog.cache(
        id: "preview.insomnia", name: "Insomnia",
        directories: ["Caches"], names: ["com.konghq.insomnia"],
        bundleIDs: [], applicationNames: ["Insomnia"], root: "Library",
        category: .developer, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2396.
      ApplicationCacheCatalog.cache(
        id: "preview.vmware", name: "VMware Fusion",
        directories: ["Caches"], names: ["com.vmware.fusion"],
        bundleIDs: [], applicationNames: ["VMware Fusion"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2294.
      ApplicationCacheCatalog.cache(
        id: "preview.utm", name: "UTM",
        directories: ["Caches"], names: ["com.utmapp.UTM"],
        bundleIDs: [], applicationNames: ["UTM"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/clean/user.sh:2400.
      ApplicationCacheCatalog.cache(
        id: "preview.lima", name: "Lima",
        directories: ["Caches/lima/download"], names: ["by-url-sha256"],
        bundleIDs: [], applicationNames: ["Lima"], root: "Library",
        category: .system, previewOnly: true, tracksApplicationPresence: false),
      // Mole 2ef974753572: lib/clean/app_caches.sh:1880.
      ApplicationCacheCatalog.cache(
        id: "preview.battleNet", name: "Battle.net",
        directories: ["Application Support/Battle.net"], names: ["Cache"],
        bundleIDs: [], applicationNames: ["Battle.net"], root: "Library",
        category: .system, previewOnly: true),
      // Mole 2ef974753572: lib/optimize/tasks.sh:207.
      ApplicationCacheCatalog.cache(
        id: "preview.quickLook", name: "QuickLook",
        directories: ["Caches"], names: ["com.apple.QuickLook.thumbnailcache"],
        bundleIDs: [], applicationNames: ["QuickLook"], root: "Library",
        category: .system, previewOnly: true, tracksApplicationPresence: false),
      // Mole 2ef974753572: lib/clean/user.sh:1173.
      ApplicationCacheCatalog.cache(
        id: "preview.quickLookLegacy", name: "QuickLook",
        directories: ["Caches"], names: ["Quick Look"],
        bundleIDs: [], applicationNames: ["QuickLook"], root: "Library",
        category: .system, previewOnly: true, tracksApplicationPresence: false),
      // Mole 2ef974753572: lib/optimize/tasks.sh:209.
      ApplicationCacheCatalog.cache(
        id: "preview.iconServices", name: "Icon Services",
        directories: ["Caches"], names: ["com.apple.iconservices"],
        bundleIDs: [], applicationNames: ["Icon Services"], root: "Library",
        category: .system, previewOnly: true, tracksApplicationPresence: false),
    ]
  }
}
