import Foundation

/// Reports whether a build appears to be actively consuming CPU right now.
///
/// Behind a protocol so `BuildQueue`'s decision logic can be exercised with a
/// deterministic stub instead of real system inspection.
protocol BuildProbe: Sendable {
    /// `true` for a build-driving `xcodebuild` invocation or non-indexing
    /// compiler processes consuming combined CPU above the threshold.
    func buildActivityDetected() async -> Bool
}

/// Inspects live processes with `ps` to decide whether a build is running.
struct SystemBuildProbe: BuildProbe {
    var cpuThresholdPercent: Double

    // Build services also drive background indexing; their CPU is not evidence
    // of a build. Inspect their compiler children instead.
    private static let compilerNames: Set<String> = [
        "swift-frontend", "swiftc", "swift-build", "clang", "clang++",
    ]

    private static let xcodebuildQueryOptions: Set<String> = [
        "-list", "-showBuildSettings", "-showBuildSettingsForIndex",
        "-showdestinations", "-showsdks", "-version", "-help", "-usage",
        "-checkFirstLaunchStatus", "-find-executable", "-find-library",
    ]

    func buildActivityDetected() async -> Bool {
        // Run the blocking `ps` off the current executor.
        let output = await Task.detached(priority: .utility) {
            Self.runPS()
        }.value
        return Self.isBuildActive(psOutput: output, cpuThreshold: cpuThresholdPercent)
    }

    /// Runs `ps` and returns its stdout, or "" on failure. Never throws: a
    /// probe failure is reported to the caller as "no build detected", which is
    /// the safe default — the queue still serializes correctly via explicit
    /// `finish_build`; only the external-build guard is temporarily blind.
    static func runPS() -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        // ucomm is the executable basename, independent of paths/arguments.
        // -ww preserves the full argument list, including indexing flags.
        process.arguments = ["-Awwxo", "%cpu=,ucomm=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Pure parser over `ps` output. Exposed for unit testing.
    static func isBuildActive(psOutput: String, cpuThreshold: Double) -> Bool {
        var compilerCPU = 0.0

        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                let cpu = Double(fields[0]), cpu.isFinite, cpu >= 0
            else { continue }
            let command = String(fields[1])
            guard command == "xcodebuild" || compilerNames.contains(command) else { continue }
            let arguments = fields[2].split(whereSeparator: \.isWhitespace)
            let options = Set(arguments.filter { $0.hasPrefix("-") }.map(String.init))

            // Do not exclude -index-store-path or -index-unit-output-path:
            // normal compilation also writes index data.
            let indexing =
                !options.isDisjoint(with: ["-index-file", "-index-file-path", "-fsyntax-only", "-typecheck"])
                || fields[2].contains("/Index.noindex/Build/")
            guard !indexing else { continue }

            if command == "xcodebuild", options.isDisjoint(with: xcodebuildQueryOptions) {
                return true
            }
            if compilerNames.contains(command) {
                compilerCPU += cpu
            }
        }

        return compilerCPU >= cpuThreshold
    }
}
