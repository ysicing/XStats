// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security

enum AppCloneSourceSignature {
  static func validate(_ bundle: URL, identifier: String, application: CloneApplication) throws {
    guard application.sourceIdentifiers.contains(identifier) else {
      throw AppCloneStore.Failure.untrustedSource
    }
    let team =
      switch application {
      case .weChat: "5A4RE8SF68"
      case .qq: "FN2V63AD2J"
      case .lark: "XY6NLV7YTS"
      case .telegram: "6N38VWS5BX"
      case .telegramDesktop: "C67CF9S4VU"
      case .weCom: "88L2Q4487U"
      }
    // Mac App Store 证书由 Apple 签发，发布团队取自已验证的代码签名。
    let rule = """
      identifier "\(identifier)" and anchor apple generic and (
        certificate leaf[field.1.2.840.113635.100.6.1.9] exists or (
          certificate 1[field.1.2.840.113635.100.6.2.6] exists and
          certificate leaf[field.1.2.840.113635.100.6.1.13] exists and
          certificate leaf[subject.OU] = "\(team)"
        )
      )
      """
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let flags = SecCSFlags(
      rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess,
      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
      let code, let requirement,
      SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    else { throw AppCloneStore.Failure.untrustedSource }
    var info: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let signing = info as? [String: Any],
      signing[kSecCodeInfoTeamIdentifier as String] as? String == team
    else { throw AppCloneStore.Failure.untrustedSource }
  }
}
