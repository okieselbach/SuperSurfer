import Foundation

// Swift face of the Rust routing engine. Every call is one JSON request and
// one JSON reply (src/engine.rs); the property names below are the JSON keys.

struct OpenerInfo {
    let name: String
    let bundleId: String?
    let path: String?
}

struct ModifierState {
    var shift = false
    var alt = false
    var ctrl = false
    var cmd = false
}

struct LaunchPlan: Decodable {
    let appPath: String
    let url: String
    let args: [String]
    let newInstance: Bool
}

struct Decision: Decodable {
    let inputUrl: String
    let routedUrl: String
    let launchUrl: String
    let host: String?
    let browserId: String
    let browser: String
    let profile: String?
    let privateWindow: Bool
    /// "handler" (config.js), "rule" (rules.json), "default" or "emergency".
    let source: String
    let ruleDomain: String?
    let fallback: Bool
    let rememberHosts: [String]
}

struct RouteReply: Decodable {
    let ok: Bool
    let error: String?
    let decision: Decision?
    let launch: LaunchPlan?
    let launchError: String?
    let configError: String?
}

struct PlanReply: Decodable {
    let ok: Bool
    let error: String?
    let browser: String?
    let profile: String?
    let launch: LaunchPlan?
}

struct BrowserInfo: Decodable {
    let id: String
    let name: String
    let appPath: String
    let profiles: [String]
}

struct BrowsersReply: Decodable {
    let ok: Bool
    let error: String?
    let defaultBrowserId: String?
    let browsers: [BrowserInfo]?
}

struct RuleInfo: Decodable {
    let domain: String
    let browser: String
    let browserName: String
    let profile: String?
    let privateWindow: Bool
}

struct RulesReply: Decodable {
    let ok: Bool
    let error: String?
    let path: String?
    let rules: [RuleInfo]?
}

struct StatusReply: Decodable {
    let ok: Bool
    let error: String?
    let version: String?
    let configPath: String?
    let rulesPath: String?
    let logPath: String?
    let configError: String?
    let rulesError: String?
    let defaultBrowser: String?
    let freshBootstrap: Bool?
    let landingUrl: String?
}

/// The engine serializes requests on its own thread, so these methods may be
/// called from any queue. They block until the reply is there: a few hundredths
/// of a millisecond for a routed link, longer only while config.js is reloaded
/// or a `resolve` rule makes a network request.
final class EngineBridge {
    func route(url: String, opener: OpenerInfo?, modifiers: ModifierState, preview: Bool) -> RouteReply? {
        var request: [String: Any] = [
            "op": "route",
            "url": url,
            "preview": preview,
            "modifiers": [
                "shift": modifiers.shift,
                "alt": modifiers.alt,
                "ctrl": modifiers.ctrl,
                "cmd": modifiers.cmd,
            ],
        ]
        if let opener = opener {
            var fields: [String: Any] = ["name": opener.name]
            if let bundleId = opener.bundleId {
                fields["bundleId"] = bundleId
            }
            if let path = opener.path {
                fields["path"] = path
            }
            request["opener"] = fields
        }
        return call(request, as: RouteReply.self)
    }

    /// The launch for a browser the user picked by hand. Also writes the
    /// decision log, which a preview route deliberately skipped.
    func plan(url: String, inputUrl: String?, browserId: String, profile: String?) -> PlanReply? {
        var request: [String: Any] = ["op": "plan", "url": url, "browser": browserId]
        if let inputUrl = inputUrl {
            request["inputUrl"] = inputUrl
        }
        if let profile = profile {
            request["profile"] = profile
        }
        return call(request, as: PlanReply.self)
    }

    func browsers() -> BrowsersReply? {
        return call(["op": "browsers"], as: BrowsersReply.self)
    }

    func rules() -> RulesReply? {
        return call(["op": "rules"], as: RulesReply.self)
    }

    func remember(domain: String, browserId: String, profile: String?) -> RulesReply? {
        var request: [String: Any] = ["op": "remember", "domain": domain, "browser": browserId]
        if let profile = profile {
            request["profile"] = profile
        }
        return call(request, as: RulesReply.self)
    }

    func forget(domain: String) -> RulesReply? {
        return call(["op": "forget", "domain": domain], as: RulesReply.self)
    }

    func reload() -> StatusReply? {
        return call(["op": "reload"], as: StatusReply.self)
    }

    func status() -> StatusReply? {
        return call(["op": "status"], as: StatusReply.self)
    }

    private func call<Reply: Decodable>(_ request: [String: Any], as type: Reply.Type) -> Reply? {
        guard let body = try? JSONSerialization.data(withJSONObject: request, options: []),
              let text = String(data: body, encoding: .utf8) else {
            NSLog("SuperSurfer: request could not be encoded")
            return nil
        }
        guard let raw = text.withCString({ supersurfer_call($0) }) else {
            return nil
        }
        defer { supersurfer_free(raw) }
        let reply = Data(String(cString: raw).utf8)
        do {
            return try JSONDecoder().decode(type, from: reply)
        } catch {
            NSLog("SuperSurfer: unexpected engine reply: %@", String(describing: error))
            return nil
        }
    }
}

/// Runs the `supersurfer` command line inside this process.
func runCommandLine(_ arguments: [String]) -> Int32 {
    guard let body = try? JSONSerialization.data(withJSONObject: arguments, options: []),
          let text = String(data: body, encoding: .utf8) else {
        return 2
    }
    return text.withCString { supersurfer_cli($0) }
}
