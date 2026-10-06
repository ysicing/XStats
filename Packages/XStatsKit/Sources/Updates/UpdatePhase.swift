// SPDX-License-Identifier: AGPL-3.0-or-later
public enum UpdatePhase: Equatable, Sendable {
    case idle, checking, upToDate, available, downloading(Double), verifying, installing, failed(String)
}
