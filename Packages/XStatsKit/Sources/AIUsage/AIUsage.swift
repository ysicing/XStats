// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum AIProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
  case codex, claude

  public var id: Self { self }
}
