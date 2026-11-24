import Cocoa

enum LaunchError: LocalizedError {
    case unusableURL(String)

    var errorDescription: String? {
        switch self {
        case .unusableURL(let text):
            return "not a usable URL: \(text)"
        }
    }
}

/// Starts browsers through Launch Services from inside this process. That is
/// the same path `/usr/bin/open` takes, without starting an `open` process for
/// every link, and the browser stays its own responsible process for privacy
/// permissions, exactly as with `open`.
enum Launcher {
    /// The completion handler runs on an arbitrary queue.
    static func open(_ plan: LaunchPlan, completion: @escaping (Error?) -> Void) {
        let application = URL(fileURLWithPath: plan.appPath, isDirectory: true)
        let configuration = NSWorkspace.OpenConfiguration()

        if plan.newInstance || !plan.args.isEmpty {
            // Profile and private-window flags are command-line arguments, and
            // Launch Services drops arguments for an app that is already
            // running. A new instance receives them; Chromium and Gecko then
            // hand the URL to the running browser and the extra instance
            // exits. The URL travels as an argument too, so it is not opened
            // as a document in the last-used profile. This is `open -n -a App
            // --args <flags> <url>`.
            configuration.arguments = plan.args + [plan.url]
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                completion(error)
            }
            return
        }

        guard let url = makeURL(plan.url) else {
            completion(LaunchError.unusableURL(plan.url))
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration) { _, error in
            completion(error)
        }
    }

    /// Last resort when the routing engine gave no usable answer at all: a
    /// web link still opens somewhere instead of vanishing.
    static func openInSafari(_ text: String) {
        guard let url = makeURL(text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else {
            NSLog("SuperSurfer: nowhere to open %@", text)
            return
        }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: safari,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
    }

    /// The engine serializes URLs the way browsers do, which leaves a few
    /// characters (`|`, `{`, `}`, `^`, non-ASCII) that older macOS versions of
    /// `URL` reject. Escape exactly those and nothing that is already legal.
    static func makeURL(_ text: String) -> URL? {
        if let url = URL(string: text) {
            return url
        }
        let legal = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard let escaped = text.addingPercentEncoding(withAllowedCharacters: legal) else {
            return nil
        }
        return URL(string: escaped)
    }
}
