// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

struct AppClonesPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @Environment(\.locale) private var locale
  let search: String
  @Binding var showsNewClone: Bool
  @State private var removing: AppClone?

  private var controller: AppCloneController { model.appClones }

  var body: some View {
    let rows = controller.clones.filter {
      search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        || $0.application.displayName.localizedCaseInsensitiveContains(search)
    }
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      if let error = controller.error {
        InfoBanner(icon: "exclamationmark.triangle", text: error, tone: .error)
      }
      if rows.isEmpty {
        Group {
          if controller.clones.isEmpty, controller.operation == .creating {
            ProgressView(AppCloneController.Operation.creating.title)
          } else {
            ContentUnavailableView(
              search.isEmpty ? tr("暂无应用分身") : tr("没有匹配的分身"),
              systemImage: "square.on.square"
            )
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Table(rows) {
          TableColumn(tr("应用")) { clone in
            let app = clone.application
            Label {
              Text(app.displayName)
            } icon: {
              if let icon = controller.applicationIcons[app] {
                Image(nsImage: icon)
                  .resizable().frame(width: 20, height: 20)
              } else {
                Image(systemName: "app")
              }
            }
          }
          TableColumn(tr("分身名称"), value: \.name)
          TableColumn(tr("状态")) { clone in
            if let operation = controller.operation, operation.targetID == clone.id {
              HStack(spacing: DS.Space.s2) {
                ProgressView().controlSize(.small).accessibilityHidden(true)
                Text(operation.title)
              }
            } else {
              Text(controller.runningIDs.contains(clone.bundleID) ? tr("正在运行") : tr("未运行"))
                .foregroundStyle(.secondary)
            }
          }
          .width(min: 92, ideal: 120)
          TableColumn("") { clone in
            HStack {
              Button(tr("打开")) { controller.launch(clone) }
                .disabled(controller.isWorking)
              Menu {
                Button(tr("更新分身")) { controller.update(clone) }
                  .disabled(controller.isWorking)
                Button(tr("在 Finder 中显示")) { controller.reveal(clone) }
                Button(tr("显示分身资料")) { controller.reveal(clone, data: true) }
                Divider()
                Button(tr("移到废纸篓"), role: .destructive) { removing = clone }
                  .disabled(controller.isWorking)
              } label: {
                Image(systemName: "ellipsis")
              }
              .accessibilityLabel(tr("分身操作"))
              .menuStyle(.borderlessButton)
              .fixedSize()
            }
          }
          .width(min: 92, ideal: 110)
        }
        let count = rows.count.formatted(.number.locale(locale))
        Text(tr("\(count) 个分身"))
          .dsFont(.xs)
          .foregroundStyle(.secondary)
      }
    }
    .task {
      guard !isSnapshot else { return }
      await controller.refresh()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didLaunchApplicationNotification)
    ) { _ in
      controller.refreshRunning()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.didTerminateApplicationNotification)
    ) { _ in
      controller.refreshRunning()
    }
    .sheet(isPresented: $showsNewClone) {
      AppCloneCreationSheet(controller: controller)
    }
    .confirmationDialog(
      removing.map { tr("将“\($0.name)”移到废纸篓？") } ?? tr("移到废纸篓"),
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
      titleVisibility: .visible,
      presenting: removing
    ) { clone in
      Button(tr("仅移除应用"), role: .destructive) {
        controller.moveToTrash(clone, includingData: false)
      }
      Button(tr("连同资料移到废纸篓"), role: .destructive) {
        controller.moveToTrash(clone, includingData: true)
      }
    } message: { _ in
      Text(tr("仅移除应用会保留分身资料，也可以将应用和资料一起移到废纸篓。"))
    }
  }
}

private struct AppCloneCreationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale
  let controller: AppCloneController
  @State private var application: CloneApplication?
  @State private var name = ""
  @State private var available: [CloneApplication] = []

  var body: some View {
    let suggestedName = application.map { controller.suggestedName(for: $0, locale: locale) } ?? ""
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(tr("新建分身")).font(.headline)
      if available.isEmpty {
        Text(tr("找不到受支持的原应用")).foregroundStyle(.secondary)
      }
      Picker(tr("应用"), selection: $application) {
        ForEach(available) { app in Text(app.displayName).tag(Optional(app)) }
      }
      .disabled(available.isEmpty)
      TextField(tr("分身名称"), text: $name, prompt: Text(suggestedName))
      HStack {
        Spacer()
        Button(tr("取消"), role: .cancel) { dismiss() }
        Button(tr("新建分身")) {
          guard let application else { return }
          controller.create(
            application: application, name: trimmedName.isEmpty ? suggestedName : trimmedName)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(
          application == nil || trimmedName.count > 64
            || trimmedName.rangeOfCharacter(from: .controlCharacters) != nil)
      }
    }
    .padding(DS.Space.s6)
    .frame(width: 470)
    .onAppear {
      available = CloneApplication.allCases.filter { $0.installedURL != nil }
      application = available.first
    }
  }
}
