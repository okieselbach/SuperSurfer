import Cocoa

enum LaunchError: LocalizedError {
    case unusableURL(String)
    /// /usr/bin/open ended with this status and said this.
    case openFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .unusableURL(let text):
            return "not a usable URL: \(text)"
        case .openFailed(let status, let said):
            return said.isEmpty ? "/usr/bin/open ended with status \(status)" : said
        }
    }
}

/// What macOS is asked to open, whichever way it is asked.
struct LaunchRequest {
    enum What {
        /// An app, with arguments. Launch Services drops arguments for an
        /// app that is already running, so with arguments the app is
        /// started as an instance of its own (`newInstance`). Chromium and
        /// Gecko then pass them on to the running browser, and the extra
        /// instance ends.
        case app(URL, arguments: [String], newInstance: Bool)
        /// A link or a file, for this app to open.
        case document(URL, with: URL)
        /// A file, a folder or a link, for whichever app macOS has for it.
        case item(URL)
    }

    let what: What
    /// Runs on an arbitrary queue.
    let completion: (Error?) -> Void

    /// What the trace calls it.
    var name: String {
        switch what {
        case .app(let application, _, _), .document(_, let application):
            return application.lastPathComponent
        case .item(let item):
            return item.isFileURL ? item.lastPathComponent : item.absoluteString
        }
    }
}

/// Which way the next request to macOS goes.
///
/// Launch Services hands on what one app asks it to open one request at a
/// time, on a queue of its own, and each waits there until macOS can say
/// how the start went. For a browser that is running that takes one to
/// three tenths of a second, and for one that has to start a second or
/// three. A browser that does not get through its start gets no answer, and
/// one that was quit in that state has been seen to get none ever (GitHub's
/// macOS 15 runner, with Edge). Whatever the app asks for after that waits
/// behind it: no link opens any more, in any browser.
///
/// So SuperSurfer gives macOS one request at a time itself and keeps the
/// next ones back. They have their turn when the answer comes, in the order
/// they came in. If the answer has not come after `patience`, they go
/// through /usr/bin/open instead, each in a process of its own, which waits
/// for nobody else's answer. So does every later request, until the answer
/// is there.
///
/// This is the bookkeeping alone, without a clock and without anything it
/// starts, so that `--self-test` can go through it.
struct LaunchLane<Request> {
    enum Way {
        /// To macOS, in this process. Nothing else is with it.
        case direct
        /// Kept back until the request that is with macOS is answered, or
        /// patience with it runs out.
        case wait
        /// Through /usr/bin/open, now.
        case aside
    }

    /// When the request that is with macOS was handed over. Nil when none is.
    private(set) var inHandSince: TimeInterval?
    /// Counts the requests handed over, to tell one from the next.
    private(set) var generation = 0
    private(set) var waiting: [Request] = []

    mutating func arrive(_ request: Request, at now: TimeInterval, patience: TimeInterval) -> Way {
        guard let since = inHandSince else {
            inHandSince = now
            generation += 1
            return .direct
        }
        if now - since >= patience {
            return .aside
        }
        waiting.append(request)
        return .wait
    }

    /// macOS has answered the request it had. Returns the one whose turn it
    /// is now, which is handed over in its place.
    mutating func answered(at now: TimeInterval) -> Request? {
        guard !waiting.isEmpty else {
            inHandSince = nil
            return nil
        }
        inHandSince = now
        generation += 1
        return waiting.removeFirst()
    }

    /// Whether the request numbered `generation` is still with macOS.
    func inHand(_ generation: Int) -> Bool {
        return generation == self.generation && inHandSince != nil
    }

    /// Patience with the request numbered `generation` may be over. Returns
    /// the requests that waited behind it, which go another way now. None
    /// if that request has been answered meanwhile, or its time is not up.
    mutating func outOfPatience(with generation: Int, at now: TimeInterval, patience: TimeInterval) -> [Request] {
        guard generation == self.generation, let since = inHandSince, now - since >= patience else {
            return []
        }
        let late = waiting
        waiting = []
        return late
    }
}

/// Starts browsers through Launch Services from inside this process. That is
/// the same path `/usr/bin/open` takes, without starting an `open` process for
/// every link, and the browser stays its own responsible process for privacy
/// permissions, exactly as with `open`. Only a request that would have to
/// wait for another one's answer for too long goes through `open` itself:
/// see `LaunchLane`.
enum Launcher {
    /// How long a request waits for the one before it to be answered before
    /// it goes through /usr/bin/open. Answers take a few tenths of a second
    /// where all is well.
    static let patience: TimeInterval = 1
    /// After how long without an answer the system log gets a line. A
    /// browser that has to start takes a second or three, which is nothing
    /// to write down.
    static let worry: TimeInterval = 10

    private static let lock = NSLock()
    private static var lane = LaunchLane<LaunchRequest>()
    /// The `open` processes that have not ended yet.
    private static var asides: [ObjectIdentifier: Process] = [:]
    private static let clockQueue = DispatchQueue(label: "dev.supersurfer.launch", qos: .userInitiated)

    private static func now() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    /// The completion handler runs on an arbitrary queue.
    static func open(_ plan: LaunchPlan, completion: @escaping (Error?) -> Void) {
        let application = URL(fileURLWithPath: plan.appPath, isDirectory: true)
        if plan.newInstance || !plan.args.isEmpty {
            // Profile and private-window flags are command-line arguments.
            // The URL travels as an argument too, so it is not opened as a
            // document in the last-used profile. This is `open -n -a App
            // --args <flags> <url>`.
            send(LaunchRequest(
                what: .app(application, arguments: plan.args + [plan.url], newInstance: true),
                completion: completion
            ))
            return
        }
        guard let url = makeURL(plan.url) else {
            completion(LaunchError.unusableURL(plan.url))
            return
        }
        send(LaunchRequest(what: .document(url, with: application), completion: completion))
    }

    /// Asks a browser for a window of one profile without giving it a link:
    /// `open -n -a App --args <flags>`. A browser that is not running starts
    /// with that profile. One that is running gets the flags from a second
    /// instance, opens a new window of the profile and the instance ends.
    /// The completion handler runs on an arbitrary queue.
    static func openProfileWindow(appPath: String, arguments: [String], completion: @escaping (Error?) -> Void) {
        send(LaunchRequest(
            what: .app(
                URL(fileURLWithPath: appPath, isDirectory: true),
                arguments: arguments,
                // Without flags there is nothing a second instance could
                // pass on.
                newInstance: !arguments.isEmpty
            ),
            completion: completion
        ))
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
        send(LaunchRequest(what: .document(url, with: safari), completion: { _ in }))
    }

    /// Opens a file, a folder or a pane of System Settings with whatever
    /// macOS has for it: what the menu's own commands do. It goes the way
    /// links go, so that it does not wait behind a start that macOS has not
    /// answered either.
    static func show(_ item: URL) {
        send(LaunchRequest(what: .item(item), completion: { error in
            if let error = error {
                NSLog("SuperSurfer: could not open %@: %@", item.absoluteString, error.localizedDescription)
            }
        }))
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

    // MARK: - One at a time, and nobody waits for long

    private static func send(_ request: LaunchRequest) {
        lock.lock()
        let way = lane.arrive(request, at: now(), patience: patience)
        let generation = lane.generation
        lock.unlock()

        switch way {
        case .direct:
            handOver(request, generation: generation)
        case .wait:
            // Its turn comes with the answer to the request before it, or
            // with the end of patience, whichever is first.
            break
        case .aside:
            sendAside(request)
        }
    }

    /// To macOS, in this process.
    private static func handOver(_ request: LaunchRequest, generation: Int) {
        clockQueue.asyncAfter(deadline: .now() + patience) {
            lock.lock()
            let late = lane.outOfPatience(with: generation, at: now(), patience: patience)
            lock.unlock()
            for waiting in late {
                sendAside(waiting)
            }
        }
        clockQueue.asyncAfter(deadline: .now() + worry) {
            lock.lock()
            let unanswered = lane.inHand(generation)
            lock.unlock()
            guard unanswered else {
                return
            }
            // Worth a line in the system log: links still open, but this is
            // what to look for when a browser was asked for and never came.
            let text = "macOS was asked for \(request.name) \(Int(worry)) s ago and has not answered. "
                + "Until it does, what is to be opened goes through /usr/bin/open."
            NSLog("SuperSurfer: %@", text)
            if AppDelegate.traceToStderr {
                fputs("SuperSurfer: \(text)\n", stderr)
            }
        }
        let answered: (Error?) -> Void = { error in
            request.completion(error)
            lock.lock()
            let next = lane.answered(at: now())
            let nextGeneration = lane.generation
            lock.unlock()
            if let next = next {
                handOver(next, generation: nextGeneration)
            }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        switch request.what {
        case .app(let application, let arguments, let newInstance):
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = newInstance
            NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
                answered(error)
            }
        case .document(let document, let application):
            NSWorkspace.shared.open([document], withApplicationAt: application, configuration: configuration) { _, error in
                answered(error)
            }
        case .item(let item):
            NSWorkspace.shared.open(item, configuration: configuration) { _, error in
                answered(error)
            }
        }
    }

    /// What /usr/bin/open is started with for a request.
    static func openArguments(for request: LaunchRequest) -> [String] {
        switch request.what {
        case .app(let application, let arguments, let newInstance):
            var given: [String] = newInstance ? ["-n"] : []
            given += ["-a", application.path]
            if !arguments.isEmpty {
                given.append("--args")
                given += arguments
            }
            return given
        case .document(let document, let application):
            return ["-a", application.path, document.absoluteString]
        case .item(let item):
            return [item.absoluteString]
        }
    }

    /// Through /usr/bin/open, in a process of its own. Launch Services keeps
    /// that process waiting for its answer as it would keep this one, and
    /// nothing here waits for it.
    private static func sendAside(_ request: LaunchRequest) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = openArguments(for: request)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { finished in
            lock.lock()
            asides[ObjectIdentifier(finished)] = nil
            lock.unlock()
            let said = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = finished.terminationStatus
            request.completion(status == 0 ? nil : LaunchError.openFailed(status, said))
        }
        lock.lock()
        asides[ObjectIdentifier(process)] = process
        lock.unlock()
        if AppDelegate.traceToStderr {
            fputs("SuperSurfer: \(request.name) is asked for through /usr/bin/open\n", stderr)
        }
        do {
            try process.run()
        } catch {
            lock.lock()
            asides[ObjectIdentifier(process)] = nil
            lock.unlock()
            request.completion(error)
        }
    }

    // MARK: - Self-test

    static func selfTest(_ check: (String, Bool) -> Void) {
        var lane = LaunchLane<String>()
        let first = lane.arrive("a", at: 10.0, patience: 1)
        let second = lane.arrive("b", at: 10.2, patience: 1)
        let third = lane.arrive("c", at: 10.4, patience: 1)
        check(
            "starts: one request is with macOS at a time, the next ones wait",
            first == .direct && second == .wait && third == .wait && lane.generation == 1 && lane.inHand(1)
        )
        check(
            "starts: they wait as long as patience lasts",
            lane.outOfPatience(with: 1, at: 10.5, patience: 1).isEmpty && lane.waiting == ["b", "c"]
        )
        let next = lane.answered(at: 10.6)
        check(
            "starts: with the answer the next one has its turn",
            next == "b" && lane.generation == 2 && lane.waiting == ["c"] && lane.inHandSince == 10.6
                && !lane.inHand(1) && lane.inHand(2)
        )
        check(
            "starts: patience is with the request that is with macOS now",
            lane.outOfPatience(with: 1, at: 11.1, patience: 1).isEmpty
                && lane.outOfPatience(with: 2, at: 11.1, patience: 1).isEmpty
        )
        let late = lane.outOfPatience(with: 2, at: 11.7, patience: 1)
        check("starts: without an answer in time the ones that waited go another way", late == ["c"] && lane.waiting.isEmpty)
        check("starts: and so does what comes after", lane.arrive("d", at: 11.8, patience: 1) == .aside && lane.waiting.isEmpty)
        check(
            "starts: once the answer is there all is as before",
            lane.answered(at: 30) == nil && lane.inHandSince == nil && !lane.inHand(2)
                && lane.arrive("e", at: 30.1, patience: 1) == .direct && lane.generation == 3
        )

        let edge = URL(fileURLWithPath: "/Applications/Microsoft Edge.app", isDirectory: true)
        let safari = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let link = URL(string: "https://example.com/a%20b") ?? edge
        func given(_ what: LaunchRequest.What) -> [String] {
            return openArguments(for: LaunchRequest(what: what, completion: { _ in }))
        }
        check(
            "starts: what /usr/bin/open is given for a link with a profile",
            given(.app(edge, arguments: ["--profile-directory=Profile 1", "https://example.com/a"], newInstance: true))
                == ["-n", "-a", "/Applications/Microsoft Edge.app", "--args", "--profile-directory=Profile 1", "https://example.com/a"]
        )
        check(
            "starts: and for a link without one, an app alone, and a file",
            given(.document(link, with: safari)) == ["-a", "/Applications/Safari.app", "https://example.com/a%20b"]
                && given(.app(edge, arguments: [], newInstance: false)) == ["-a", "/Applications/Microsoft Edge.app"]
                && given(.item(URL(fileURLWithPath: "/tmp/a b.js"))) == ["file:///tmp/a%20b.js"]
        )
        check(
            "starts: what the trace calls a request",
            LaunchRequest(what: .document(link, with: safari), completion: { _ in }).name == "Safari.app"
                && LaunchRequest(what: .item(URL(fileURLWithPath: "/tmp/config.js")), completion: { _ in }).name == "config.js"
        )
    }
}
