// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreBluetooth
import Foundation
import IOBluetooth

@MainActor
protocol BluetoothConnectionObserving: AnyObject {
  func start(onChange: @escaping @MainActor () -> Void) -> Bool
  func stop()
}

/// 只观察已获授权的系统连接，不扫描附近设备，也不主动请求蓝牙权限。
@MainActor
final class BluetoothConnectionObserver: NSObject, BluetoothConnectionObserving {
  private var connection: IOBluetoothUserNotification?
  private var disconnections: [String: IOBluetoothUserNotification] = [:]
  private var onChange: (@MainActor () -> Void)?

  isolated deinit { stop() }

  func start(onChange: @escaping @MainActor () -> Void) -> Bool {
    if connection != nil { return true }
    guard CBManager.authorization == .allowedAlways else { return false }
    self.onChange = onChange
    connection = IOBluetoothDevice.register(
      forConnectNotifications: self, selector: #selector(connected(_:device:)))
    guard connection != nil else {
      self.onChange = nil
      return false
    }
    // 连接通知不一定重放已有连接；这些设备也必须能收到后续断开通知。
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    for device in paired.prefix(256) where device.isConnected() { watchDisconnection(device) }
    return true
  }

  func stop() {
    onChange = nil
    let connection = self.connection
    let disconnections = self.disconnections
    self.connection = nil
    self.disconnections.removeAll()
    connection?.unregister()
    for notification in disconnections.values { notification.unregister() }
  }

  private func watchDisconnection(_ device: IOBluetoothDevice) {
    guard let address = device.addressString, !address.isEmpty,
      disconnections[address] != nil || disconnections.count < 256
    else { return }
    let notification = device.register(
      forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
    guard let notification else { return }
    disconnections.updateValue(notification, forKey: address)?.unregister()
  }

  // 原生回调不假定执行线程。仅传递值到主 actor，避免跨线程持有 IOBluetoothDevice。
  @objc nonisolated private func connected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let identity = ObjectIdentifier(notification)
    let address = device.addressString
    Task { @MainActor [weak self] in
      guard let self, let current = self.connection, ObjectIdentifier(current) == identity else {
        return
      }
      if let address, let device = IOBluetoothDevice(addressString: address) {
        self.watchDisconnection(device)
      }
      self.onChange?()
    }
  }

  @objc nonisolated private func disconnected(
    _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
  ) {
    let identity = ObjectIdentifier(notification)
    let address = device.addressString
    Task { @MainActor [weak self] in
      guard let self, let address, let current = self.disconnections[address],
        ObjectIdentifier(current) == identity
      else { return }
      self.disconnections.removeValue(forKey: address)?.unregister()
      self.onChange?()
    }
  }
}
