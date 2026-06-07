import Foundation

/// `StemSeparator` backed by `demucs_mt.cpp.main` (sevagh/demucs.cpp) running
/// as a subprocess.
///
/// In development the binary + weights live where
/// `scripts/stem-separation-poc.sh` puts them: `<projectRoot>/.stems-poc/…`.
/// In production we'll either bundle them inside the .app or swap the whole
/// backend out for MLX-Swift; either way the `StemSeparator` protocol stays
/// the same so the engine and UI above don't notice.
struct DemucsCppSeparator: StemSeparator {
    let binaryURL: URL
    let weightsURL: URL
    let threadCount: Int
    let ompThreadCount: Int

    let modelID = "htdemucs"
    let modelDisplayName = "Demucs HT (4-source)"
    let stemOrder = ["vocals", "drums", "bass", "other"]

    init(binaryURL: URL,
         weightsURL: URL,
         threadCount: Int = 4,
         ompThreadCount: Int = 4) {
        self.binaryURL = binaryURL
        self.weightsURL = weightsURL
        self.threadCount = threadCount
        self.ompThreadCount = ompThreadCount
    }

    /// Convenience for development: locates the binary + weights that
    /// `scripts/stem-separation-poc.sh` produces under
    /// `<projectRoot>/.stems-poc/`.
    ///
    /// `projectRoot` is discovered (in order):
    ///  1. The `AUDIOLENS_STEMS_POC` env var, if set — point this at the
    ///     project root in your Xcode scheme to override everything.
    ///  2. `~/Documents/GitHub/AudioLens` resolved via `getpwuid(getuid())`,
    ///     so it works even when the App Sandbox is enabled (which redirects
    ///     `FileManager.homeDirectoryForCurrentUser` to the container's
    ///     fake "home" inside `~/Library/Containers/…/Data/`).
    ///
    /// Note: the subprocess launch *itself* still requires the sandbox to
    /// be off — flip `com.apple.security.app-sandbox` to `false` in
    /// `AudioLens/AudioLens.entitlements`, **then Clean Build Folder** so
    /// the entitlement change actually takes effect.
    static func developmentLocal() -> DemucsCppSeparator {
        if let override = ProcessInfo.processInfo.environment["AUDIOLENS_STEMS_POC"] {
            return developmentLocal(projectRoot: URL(fileURLWithPath: override))
        }
        let home = realHomeDirectory()
        let projectRoot = home
            .appendingPathComponent("Documents")
            .appendingPathComponent("GitHub")
            .appendingPathComponent("AudioLens")
        return developmentLocal(projectRoot: projectRoot)
    }

    /// Explicit override: use this if your project lives somewhere other
    /// than `~/Documents/GitHub/AudioLens/`.
    static func developmentLocal(projectRoot: URL) -> DemucsCppSeparator {
        let pocDir = projectRoot.appendingPathComponent(".stems-poc")
        return DemucsCppSeparator(
            binaryURL: pocDir
                .appendingPathComponent("demucs.cpp")
                .appendingPathComponent("build")
                .appendingPathComponent("demucs_mt.cpp.main"),
            weightsURL: pocDir
                .appendingPathComponent("weights")
                .appendingPathComponent("ggml-model-htdemucs-4s-f16.bin"))
    }

    /// True home directory (`/Users/<username>/`) from the system password
    /// database, even from inside an App Sandbox that would otherwise remap
    /// `FileManager.homeDirectoryForCurrentUser` to the container path.
    private static func realHomeDirectory() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func separate(
        sourceURL: URL,
        outputDirectory: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> [StemFile] {
        try preflight(sourceURL: sourceURL)
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)
        progress(0.0)

        let handle = SubprocessHandle(env: ["OMP_NUM_THREADS": String(ompThreadCount)])
        do {
            try handle.start(
                binary: binaryURL,
                arguments: [
                    weightsURL.path,
                    sourceURL.path,
                    outputDirectory.path,
                    String(threadCount),
                ])
        } catch {
            throw StemSeparationError.launchFailed(String(describing: error))
        }

        // The subprocess can run for minutes; wait on a detached worker so
        // we don't pin a structured-concurrency cooperative thread.
        let exitCode = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                handle.waitUntilExit()
            }.value
        } onCancel: {
            handle.terminate()
        }

        if Task.isCancelled {
            cleanupPartials(in: outputDirectory)
            throw StemSeparationError.cancelled
        }
        if exitCode != 0 {
            throw StemSeparationError.inferenceFailed(
                exitCode: exitCode, stderr: handle.collectStderr())
        }

        let stems = try Self.collectStems(in: outputDirectory, order: stemOrder)
        progress(1.0)
        return stems
    }

    // MARK: - helpers

    private func preflight(sourceURL: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: binaryURL.path) else {
            throw StemSeparationError.missingBinary(binaryURL)
        }
        guard fm.isExecutableFile(atPath: binaryURL.path) else {
            throw StemSeparationError.missingBinary(binaryURL)
        }
        guard fm.fileExists(atPath: weightsURL.path) else {
            throw StemSeparationError.missingWeights(weightsURL)
        }
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw StemSeparationError.sourceFileMissing(sourceURL)
        }
    }

    /// Walks the output dir for `target_<n>_<name>.wav` files and returns
    /// them in the requested `order`. The CLI writes them in the model's
    /// internal order (drums, bass, other, vocals); we look them up by name
    /// rather than by the numeric prefix so future model variants can
    /// reorder freely.
    private static func collectStems(in dir: URL, order: [String]) throws -> [StemFile] {
        let displayNames: [String: String] = [
            "vocals": "Vocals", "drums": "Drums",
            "bass": "Bass", "other": "Other",
            "guitar": "Guitar", "piano": "Piano",
        ]
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var byName: [String: URL] = [:]
        for filename in contents {
            guard filename.hasPrefix("target_"), filename.hasSuffix(".wav") else { continue }
            // "target_0_drums.wav" → strip "target_" prefix and ".wav" suffix,
            // then grab everything after the first underscore.
            let middle = filename
                .dropFirst("target_".count)
                .dropLast(".wav".count)
            if let underscore = middle.firstIndex(of: "_") {
                let name = String(middle[middle.index(after: underscore)...])
                byName[name] = dir.appendingPathComponent(filename)
            }
        }

        var stems: [StemFile] = []
        for stemID in order {
            guard let url = byName[stemID] else {
                throw StemSeparationError.missingOutput(expected: "target_*_\(stemID).wav")
            }
            stems.append(StemFile(
                id: stemID,
                displayName: displayNames[stemID] ?? stemID.capitalized,
                url: url))
        }
        return stems
    }

    /// After a cancellation, sweep half-written WAVs so a retry starts clean.
    private func cleanupPartials(in dir: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for filename in contents where filename.hasPrefix("target_") && filename.hasSuffix(".wav") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(filename))
        }
    }
}

/// Holds the `Process` + `Pipe` (neither Sendable) behind an
/// `@unchecked Sendable` boundary so async/awaitable code and the
/// cancellation closure can both reach in. The internal lock guards the
/// stderr buffer that the readability handler fills from a background queue.
private final class SubprocessHandle: @unchecked Sendable {
    private let process = Process()
    private let stderrPipe = Pipe()
    private let env: [String: String]
    private let lock = NSLock()
    private var stderrBuffer = Data()

    init(env: [String: String]) { self.env = env }

    func start(binary: URL, arguments: [String]) throws {
        process.executableURL = binary
        process.arguments = arguments
        process.standardError = stderrPipe
        // Discard stdout — demucs_mt.cpp.main is chatty but we don't parse it.
        process.standardOutput = Pipe()

        var fullEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { fullEnv[k] = v }
        process.environment = fullEnv

        // Drain stderr as it arrives so the pipe buffer never fills and
        // blocks the child.
        let handle = stderrPipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] file in
            let chunk = file.availableData
            if chunk.isEmpty {
                file.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.withLock { self.stderrBuffer.append(chunk) }
        }

        try process.run()
    }

    func waitUntilExit() -> Int32 {
        process.waitUntilExit()
        return process.terminationStatus
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func collectStderr() -> String {
        let trailing = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let snapshot = lock.withLock { stderrBuffer + trailing }
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}
