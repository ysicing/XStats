// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Localization
import Metrics
import Observation
import Security
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 用 Apple 智能（系统自带的本机大模型）解释一个进程是做什么的。
/// 全程在本机运行，不联网；需要 macOS 26 且开启了 Apple 智能。
@MainActor
@Observable
public final class ProcessExplainer {
    public struct Subject: Equatable, Sendable {
        let pid: Int32
        let name: String
        let displayName: String
        let executablePath: String?
        let appBundlePath: String?
        let cpu: Double?
        let memory: UInt64?
        let networkRate: Double?
    }

    public enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    public private(set) var subject: Subject?
    public private(set) var text = ""
    public private(set) var phase: Phase = .idle

    @ObservationIgnored private var task: Task<Void, Never>?

    /// 系统版本与框架是否支持；是否真正可用（设备、开关、模型下载）在运行时再判断
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    func explain(_ subject: Subject) {
        task?.cancel()
        self.subject = subject
        text = ""
        phase = .running
        task = Task { [weak self] in
            let facts = await Task.detached { Self.facts(for: subject) }.value
            guard let self, !Task.isCancelled else { return }
            await self.run(facts: facts)
        }
    }

    func dismiss() {
        task?.cancel()
        task = nil
        subject = nil
        text = ""
        phase = .idle
    }

    private func run(facts: String) async {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .unavailable(let reason) = model.availability {
                phase = .failed(Self.message(for: reason))
                return
            }
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                for try await snapshot in session.streamResponse(to: facts) {
                    guard !Task.isCancelled else { return }
                    text = snapshot.content
                }
                phase = .done
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(tr("Apple 智能没有给出回答：\(error.localizedDescription)"))
            }
            return
        }
        #endif
        phase = .failed(tr("需要 macOS 26 及以上，并在系统设置中开启 Apple 智能。"))
    }

    private static var instructions: String {
        switch L10n.language {
        case .chinese: chineseInstructions
        case .english: englishInstructions
        default:
            englishInstructions.replacingOccurrences(of: "in English", with: "in \(L10n.language.nativeName)")
        }
    }

    private static let chineseInstructions = """
    你是熟悉 macOS 的系统工程师。用户会给出 Mac 上一个进程的事实信息（名称、路径、所属应用、签名方、资源占用）。
    请只根据这些事实和你确定知道的知识，用简体中文回答三点，每点一两句：
    1. 它是什么：属于哪个应用或系统组件，负责什么。
    2. 占用是否正常：结合给出的 CPU、内存数值判断。
    3. 能否退出：直接退出会有什么影响。
    不确定时明确说“不确定”，不要编造功能或来源。不使用 Markdown 标题，总共不超过 180 字。
    """

    private static let englishInstructions = """
    You are a systems engineer who knows macOS well. The user gives facts about a process on a Mac (name, path, owning app, signer, resource usage).
    Using only these facts and what you know for certain, answer three points in English, one or two sentences each:
    1. What it is: which app or system component it belongs to and what it does.
    2. Whether its usage is normal, judging from the CPU and memory numbers given.
    3. Whether it can be quit, and what happens if it is.
    If unsure, say you're not sure; never invent features or origins. No Markdown headings; under 120 words in total.
    """

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: tr("这台 Mac 不支持 Apple 智能。")
        case .appleIntelligenceNotEnabled: tr("请先在“系统设置 → Apple 智能与 Siri”中开启 Apple 智能。")
        case .modelNotReady: tr("Apple 智能模型还在下载或准备中，请稍后再试。")
        @unknown default: tr("Apple 智能暂时不可用。")
        }
    }
    #endif

    // MARK: 事实

    /// 交给模型的事实：路径位置、所属应用、签名方都能明显减少模型胡猜
    nonisolated static func facts(for subject: Subject) -> String {
        var lines = [tr("进程名：\(subject.name)")]
        if subject.displayName != subject.name { lines.append(tr("显示名称：\(subject.displayName)")) }
        let path = subject.executablePath ?? executablePath(pid: subject.pid)
        if let path {
            lines.append(tr("可执行文件：\(path)"))
            lines.append(tr("位置：\(location(of: path))"))
            if let signer = signer(of: path) { lines.append(tr("签名方：\(signer)")) }
        }
        if let bundlePath = subject.appBundlePath, let bundle = Bundle(path: bundlePath) {
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
            lines.append(tr("所属应用：\(name)（\(bundle.bundleIdentifier ?? tr("无 Bundle ID"))）"))
        }
        if let cpu = subject.cpu { lines.append(tr("CPU：\(Format.percent(cpu))（以单核满载为 100%）")) }
        if let memory = subject.memory { lines.append(tr("内存：\(Format.bytes(memory))")) }
        if let rate = subject.networkRate { lines.append(tr("网络：\(Format.menuBarRate(rate))")) }
        return lines.joined(separator: "\n")
    }

    nonisolated private static func location(of path: String) -> String {
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") || path.hasPrefix("/bin/") {
            return tr("macOS 系统目录（系统组件）")
        }
        if path.hasPrefix("/Applications/") || path.contains("/Applications/") { return tr("应用程序文件夹") }
        if path.hasPrefix("/Library/") { return tr("系统级资源库（第三方驱动、辅助工具或后台服务）") }
        if path.contains("/Library/") { return tr("用户资源库") }
        return tr("其他位置")
    }

    nonisolated private static func signer(of path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement,
           SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess {
            return tr("Apple（系统自带）")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String {
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
            let summary = certificates?.first.flatMap { SecCertificateCopySubjectSummary($0) as String? }
            return [summary, tr("团队 \(team)")].compactMap { $0 }.joined(separator: tr("，"))
        }
        return tr("未签名或临时签名")
    }

    nonisolated private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

extension ProcessExplainer.Subject {
    @MainActor
    init(_ process: ProcessUsage) {
        self.init(pid: process.pid, name: process.name, displayName: process.displayName,
                  executablePath: process.executablePath, appBundlePath: process.appBundlePath,
                  cpu: process.cpu, memory: process.memory, networkRate: nil)
    }

    @MainActor
    init(_ process: NetworkProcessUsage) {
        self.init(pid: process.pid, name: process.name, displayName: process.localizedName,
                  executablePath: nil, appBundlePath: process.appBundlePath,
                  cpu: nil, memory: nil, networkRate: process.download + process.upload)
    }
}
