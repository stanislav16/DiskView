import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var smartDelete = SmartDelete.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Find leftovers when I move an app to the Trash", isOn: $smartDelete.isEnabled)
                Text("DiskView keeps running in the menu bar after you close its window, so it can notice. It stays quiet when another copy of the app is still installed, for example after an update.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem = smartDelete.problem, smartDelete.isEnabled {
                    HStack {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.system(size: 12))
                        Spacer()
                        Button("Open Settings") { AppModel.openFullDiskAccessSettings() }
                        Button("Try Again") { smartDelete.stop(); smartDelete.start() }
                    }
                }
            }
            Section {
                Toggle("Open DiskView at login", isOn: $openAtLogin)
                    .disabled(!smartDelete.isEnabled && !openAtLogin)
                    .onChange(of: openAtLogin) { _, on in setLogin(on) }
                Text("Starts quietly in the menu bar so deleted apps are caught even if you haven't opened DiskView.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let loginError {
                    Text(loginError).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change this: \(error.localizedDescription)"
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var smartDelete = SmartDelete.shared

    var body: some View {
        Button("Open DiskView") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        Toggle("Find Leftovers of Deleted Apps", isOn: $smartDelete.isEnabled)
        if smartDelete.problem != nil {
            Text("Needs Full Disk Access")
        }
        Button("Settings…") {
            NSApp.setActivationPolicy(.regular)
            openSettings()
            NSApp.activate()
        }
        Divider()
        Button("Quit DiskView") { NSApp.terminate(nil) }
    }
}
