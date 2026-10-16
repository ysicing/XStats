// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

struct NetworkProbeSummary: Equatable {
  let count: Int
  let latestLatency: Double?
  let lossFraction: Double?

  init(samples: [ProbeSample]) {
    count = samples.count
    latestLatency = samples.last?.latency
    lossFraction =
      samples.isEmpty
      ? nil : Double(samples.filter { $0.latency == nil }.count) / Double(samples.count)
  }
}
