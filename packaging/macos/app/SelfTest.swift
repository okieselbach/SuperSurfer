import Foundation

/// `SuperSurfer --self-test`: checks, on a real Mac, that this binary and the
/// Rust core linked into it still agree on the JSON they exchange. The Rust
/// tests pin the reply shapes from their side; this decodes real replies with
/// the structs the app uses. Runs against a scratch HOME, so the real
/// configuration is never touched. No window server needed.
enum SelfTest {
    static func run() -> Int32 {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("supersurfer-self-test-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        setenv("HOME", scratch.path, 1)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var failures = 0
        func check(_ name: String, _ passed: Bool) {
            print(passed ? "ok    \(name)" : "FAIL  \(name)")
            if !passed {
                failures += 1
            }
        }

        let engine = EngineBridge()
        let noKeys = ModifierState()

        let status = engine.status()
        check("status decodes", status?.ok == true && status?.version?.isEmpty == false)
        check("first run creates a config", status?.freshBootstrap == true && status?.configError == nil)
        check("scratch HOME is in use", status?.configPath?.hasPrefix(scratch.path) == true)

        let browsers = engine.browsers()
        let installed = browsers?.browsers ?? []
        check("browsers decode", browsers?.ok == true && !installed.isEmpty)
        check("unreadable profile lists are reported", browsers?.profilesBlocked != nil)

        let opener = OpenerInfo(name: "Self Test", bundleId: "dev.supersurfer.selftest", path: nil)
        let routed = engine.route(
            url: "https://www.example.com/page?utm_source=x",
            opener: opener,
            modifiers: noKeys,
            preview: true
        )
        check("route decodes", routed?.ok == true && routed?.decision != nil && routed?.launch != nil)
        check("tracking parameters are stripped", routed?.decision?.launchUrl == "https://www.example.com/page")
        check("remember suggestion", routed?.decision?.rememberHosts == ["example.com"])
        check("default route", routed?.decision?.source == "default")

        if let first = installed.first {
            let saved = engine.remember(domain: "selftest.example", browserId: first.id, profile: nil)
            let savedRules = saved?.rules ?? []
            check("remember decodes", saved?.ok == true && savedRules.contains { $0.domain == "selftest.example" })

            let ruled = engine.route(url: "https://a.selftest.example/", opener: nil, modifiers: noKeys, preview: true)
            check("saved rule applies", ruled?.decision?.source == "rule" && ruled?.decision?.browserId == first.id)

            let plan = engine.plan(url: "https://selftest.example/", inputUrl: nil, browserId: first.id, profile: nil)
            check("plan decodes", plan?.ok == true && plan?.launch?.appPath == first.appPath)

            let forgotten = engine.forget(domain: "selftest.example")
            let leftRules = forgotten?.rules ?? []
            check("forget decodes", forgotten?.ok == true && !leftRules.contains { $0.domain == "selftest.example" })
        }

        let refused = engine.route(url: "javascript:alert(1)", opener: nil, modifiers: noKeys, preview: true)
        check("unsafe URL gets no launch plan", refused != nil && refused?.launch == nil)

        let reloaded = engine.reload()
        check("reload decodes", reloaded?.ok == true && reloaded?.freshBootstrap == false)

        check("URL with characters old macOS rejects", Launcher.makeURL("https://example.com/a b|c?q={x}") != nil)

        print(failures == 0 ? "self-test passed" : "self-test FAILED (\(failures))")
        return failures == 0 ? 0 : 1
    }
}
