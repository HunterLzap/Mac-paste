import ServiceManagement

/// 开机自启动（macOS 13+ SMAppService），需 app 以 .app bundle 形式运行
enum LaunchAtLogin {
    static var isAppBundled: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isAppBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
