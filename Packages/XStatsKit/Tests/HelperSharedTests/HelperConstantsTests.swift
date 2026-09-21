// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import HelperShared
import Testing

@Suite struct HelperConstantsTests {
    @Test func unsafeHelperVersionsRequireUpgrade() {
        #expect(HelperConstants.protocolVersion == 5)
        #expect(HelperConstants.isCompatible(version: 4) == false)
        #expect(HelperConstants.isCompatible(version: nil) == false)
        #expect(HelperConstants.isCompatible(version: 5))
    }
    /// 辅助工具以 root 运行。没有团队签名时必须拒绝服务，不能退化成只校验 bundle identifier——
    /// 单独的 `identifier` 不含 anchor 约束，任何进程 `codesign -s -` 伪造同名即可连上。
    @Test func adHocBuildHasNoClientRequirement() {
        #expect(HelperConstants.clientRequirement(teamIdentifier: nil) == nil)
        #expect(HelperConstants.clientRequirement(teamIdentifier: "") == nil)
    }

    @Test func teamSignedRequirementPinsAnchorAndTeam() throws {
        let requirement = try #require(HelperConstants.clientRequirement(teamIdentifier: "ABCDE12345"))
        #expect(requirement.contains("identifier \"\(HelperConstants.appBundleIdentifier)\""))
        // anchor 缺失时 identifier 可被任意 ad-hoc 签名伪造，这一条是整个鉴权的根基
        #expect(requirement.contains("anchor apple generic"))
        #expect(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
    }
}
