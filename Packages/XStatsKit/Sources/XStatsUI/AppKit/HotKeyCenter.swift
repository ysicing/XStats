import AppKit
import Carbon.HIToolbox
import Localization

/// 可以绑定全局快捷键的操作
public enum HotKeyAction: String, CaseIterable, Identifiable, Codable, Sendable {
  case toggleMainWindow, showProcesses, toggleKeepAwake, purgeMemory, openCalendar, startEyeRest
  // 追加新动作，保持现有 Carbon 编号和保存的标识不变。
  case openTimer, toggleTimerHUD, startShortBreak, startLongBreak, sleepDisplay

  var requiresTimer: Bool {
    [.startEyeRest, .openTimer, .toggleTimerHUD, .startShortBreak, .startLongBreak].contains(self)
  }

  public var id: String { rawValue }

  var title: String {
    switch self {
    case .toggleMainWindow: tr("显示 / 隐藏主窗口")
    case .showProcesses: tr("打开进程页")
    case .toggleKeepAwake: tr("开关防休眠")
    case .purgeMemory: tr("释放内存")
    case .openCalendar: tr("打开日历")
    case .startEyeRest: tr("开始护眼休息")
    case .openTimer: tr("打开计时弹窗")
    case .toggleTimerHUD: tr("显示 / 隐藏迷你 HUD")
    case .startShortBreak: tr("开始短休息")
    case .startLongBreak: tr("开始长休息")
    case .sleepDisplay: tr("关闭显示器")
    }
  }

  func title(processesEnabled: Bool) -> String {
    self == .showProcesses && !processesEnabled ? tr("打开系统活动监视器") : title
  }

  /// Carbon 热键编号，从 1 开始
  var carbonID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)! + 1) }
}

/// 一个快捷键：虚拟键码加修饰键
public struct HotKey: Codable, Equatable, Sendable {
  public var keyCode: UInt16
  /// NSEvent.ModifierFlags 的原始值，只保留 ⌃⌥⇧⌘
  public var modifiers: UInt
  /// 录制时按下的字符，用于显示
  public var key: String

  public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers.intersection([.control, .option, .shift, .command]).rawValue
    self.key = key
  }

  var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

  /// 至少带一个 ⌃、⌥ 或 ⌘，避免抢走普通按键
  var isValid: Bool { !flags.intersection([.control, .option, .command]).isEmpty }

  var display: String {
    var text = ""
    if flags.contains(.control) { text += "⌃" }
    if flags.contains(.option) { text += "⌥" }
    if flags.contains(.shift) { text += "⇧" }
    if flags.contains(.command) { text += "⌘" }
    return text + Self.keyName(keyCode: keyCode, fallback: key)
  }

  var carbonModifiers: UInt32 {
    var result: UInt32 = 0
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    return result
  }

  private static let functionKeys: [Int: Int] = [
    kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
    kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12,
    kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16,
    kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
  ]

  static func keyName(keyCode: UInt16, fallback: String) -> String {
    switch Int(keyCode) {
    case kVK_Space: tr("空格")
    case kVK_Return: "↩"
    case kVK_ANSI_KeypadEnter: "⌤"
    case kVK_ANSI_KeypadClear: "⌧"
    case kVK_Tab: "⇥"
    case kVK_Delete: "⌫"
    case kVK_ForwardDelete: "⌦"
    case kVK_Escape: "⎋"
    case kVK_Help: tr("帮助")
    case kVK_Home: "↖"
    case kVK_End: "↘"
    case kVK_PageUp: "⇞"
    case kVK_PageDown: "⇟"
    case kVK_LeftArrow: "←"
    case kVK_RightArrow: "→"
    case kVK_UpArrow: "↑"
    case kVK_DownArrow: "↓"
    default:
      // F1–F20 的虚拟键码不连续，逐个对照
      functionKeys[Int(keyCode)].map { "F\($0)" } ?? fallback.uppercased()
    }
  }
}

/// 用 Carbon 注册系统级快捷键：不需要辅助功能权限，应用在后台也能响应
@MainActor
final class HotKeyCenter {
  private var references: [HotKeyAction: EventHotKeyRef] = [:]
  private var handler: EventHandlerRef?
  var onAction: (HotKeyAction) -> Void = { _ in }
  /// 注册失败（被其他应用占用）的操作
  private(set) var conflicts: Set<HotKeyAction> = []

  private static weak var current: HotKeyCenter?

  func apply(_ bindings: [HotKeyAction: HotKey]) {
    installHandlerIfNeeded()
    for reference in references.values { UnregisterEventHotKey(reference) }
    references = [:]
    conflicts = []
    // 同组重复绑定全部标记冲突，避免字典遍历顺序决定哪个动作被触发。
    let duplicates = Self.duplicateActions(in: bindings)
    conflicts = duplicates
    for action in HotKeyAction.allCases {
      guard let hotKey = bindings[action], hotKey.isValid, !duplicates.contains(action) else {
        continue
      }
      var reference: EventHotKeyRef?
      let id = EventHotKeyID(signature: Self.signature, id: action.carbonID)
      let status = RegisterEventHotKey(
        UInt32(hotKey.keyCode), hotKey.carbonModifiers, id, GetApplicationEventTarget(), 0,
        &reference)
      if status == noErr, let reference {
        references[action] = reference
      } else {
        conflicts.insert(action)
      }
    }
  }

  static func duplicateActions(in bindings: [HotKeyAction: HotKey]) -> Set<HotKeyAction> {
    let groups = Dictionary(grouping: bindings.keys) { action in
      let key = bindings[action]!
      return UInt64(key.keyCode) << 32 | UInt64(key.carbonModifiers)
    }
    return Set(groups.values.filter { $0.count > 1 }.flatMap { $0 })
  }

  private static let signature: OSType = 0x4F50_5354  // "OPST"

  private func installHandlerIfNeeded() {
    guard handler == nil else { return }
    Self.current = self
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, _ -> OSStatus in
        var id = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr, id.signature == HotKeyCenter.signature,
          let action = HotKeyAction.allCases.first(where: { $0.carbonID == id.id })
        else { return OSStatus(eventNotHandledErr) }
        MainActor.assumeIsolated { HotKeyCenter.current?.onAction(action) }
        return noErr
      }, 1, &spec, nil, &handler)
  }
}

/// 多行录制器共用单一所有者，切换行时先撤销旧监听，再接收新的组合键。
@MainActor final class ShortcutRecordingSession {
  static let shared = ShortcutRecordingSession()
  private var owner: UUID?
  private var stopOwner: (() -> Void)?
  func begin(_ id: UUID, stop: @escaping () -> Void) {
    cancel()
    owner = id
    stopOwner = stop
  }
  func end(_ id: UUID) {
    guard owner == id else { return }
    owner = nil
    stopOwner = nil
  }
  func cancel() {
    let stop = stopOwner
    owner = nil
    stopOwner = nil
    stop?()
  }
}
