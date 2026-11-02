// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

struct NetworkTrafficPoint: Identifiable, Sendable {
  var id: Date { date }
  let date: Date
  var receivedBytesPerSecond: Double?
  var sentBytesPerSecond: Double?
  var segment: Int
}
