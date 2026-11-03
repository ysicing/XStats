// SPDX-License-Identifier: AGPL-3.0-or-later

struct AudioHeadphoneDisconnectState {
  private var previousOutput: AudioDeviceInfo?
  private var pendingDisconnect:
    (headphoneUID: String, speakerUID: String, deadline: ContinuousClock.Instant)?

  mutating func outputToLimit(
    in snapshot: AudioHardwareSnapshot, now: ContinuousClock.Instant = .now
  ) -> AudioDeviceInfo? {
    guard let output = snapshot.devices.first(where: { $0.id == snapshot.outputID }) else {
      return nil
    }
    defer { previousOutput = output }
    guard output.outputKind == .speaker, output.canSetOutputVolume,
      let volume = output.outputVolume, volume.isFinite, volume > 0.2
    else {
      pendingDisconnect = nil
      return nil
    }
    let headphoneUID: String
    if let previousOutput, previousOutput.outputKind == .headphones {
      headphoneUID = previousOutput.uid
      // HAL 的默认输出与设备移除通知可能分开到达；只关联短暂过渡，避免后来拔掉闲置耳机也调音量。
      pendingDisconnect = (headphoneUID, output.uid, now + .milliseconds(250))
    } else if let pendingDisconnect, pendingDisconnect.speakerUID == output.uid,
      now <= pendingDisconnect.deadline
    {
      headphoneUID = pendingDisconnect.headphoneUID
    } else {
      pendingDisconnect = nil
      return nil
    }
    let headphonesStillConnected = snapshot.devices.contains {
      $0.uid == headphoneUID && $0.outputKind == .headphones
    }
    guard !headphonesStillConnected else { return nil }
    pendingDisconnect = nil
    return output
  }
}
