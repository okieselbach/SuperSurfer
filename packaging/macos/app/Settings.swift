import Cocoa
import ServiceManagement

/// The modifier key that, held while a link is clicked, asks which browser to
/// use instead of following the rules.
enum PickerKey: String, CaseIterable {
    case option
    case shift
    case control
    case command
    case function
    case off

    private static let defaultsKey = "pickerKey"

    static var current: PickerKey {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return PickerKey(rawValue: stored) ?? .option
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .function: return "fn"
        case .off: return tr("Off", "Aus")
        }
    }

    var symbol: String {
        switch self {
        case .option: return "⌥"
        case .shift: return "⇧"
        case .control: return "⌃"
        case .command: return "⌘"
        case .function: return "fn"
        case .off: return ""
        }
    }

    func isHeld(in flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .option: return flags.contains(.option)
        case .shift: return flags.contains(.shift)
        case .control: return flags.contains(.control)
        case .command: return flags.contains(.command)
        case .function: return flags.contains(.function)
        case .off: return false
        }
    }
}

/// "Launch at Login" through the system's own login-item list (macOS 13+).
enum LoginItem {
    static var isSupported: Bool {
        if #available(macOS 13.0, *) {
            return true
        }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}

enum DefaultBrowser {
    static var isSuperSurfer: Bool {
        guard let probe = URL(string: "https://example.com/"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let ours = Bundle.main.bundleIdentifier else {
            return false
        }
        return Bundle(url: handler)?.bundleIdentifier == ours
    }

    /// macOS asks the user to confirm. The completion handler runs on the main
    /// queue with the error, if any.
    static func claim(completion: @escaping (Error?) -> Void) {
        if #available(macOS 12.0, *) {
            // Both schemes belong to "the default web browser"; macOS asks once.
            let app = Bundle.main.bundleURL
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { first in
                NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { second in
                    DispatchQueue.main.async {
                        completion(first ?? second)
                    }
                }
            }
        } else {
            // No API before macOS 12: the choice lives in System Preferences.
            if let pane = URL(string: "x-apple.systempreferences:com.apple.preference.general") {
                NSWorkspace.shared.open(pane)
            }
            completion(nil)
        }
    }
}
