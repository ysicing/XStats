// SPDX-License-Identifier: AGPL-3.0-or-later
public enum UpdatePhase: Equatable, Sendable {
  case idle, checking, upToDate, available
  case downloading(Double)
  case verifying, installing
  case failed(String)
}
