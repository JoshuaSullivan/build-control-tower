import Foundation

/// Reports whether a build appears to be actively consuming CPU right now.
///
/// Behind a protocol so `BuildQueue`'s decision logic can be exercised with a
/// deterministic stub instead of real system inspection.
protocol BuildProbe: Sendable {
    /// `true` when a qualifying build process is currently running: either
    /// `xcodebuild` (present at all) or the Swift/Clang toolchain consuming
    /// combined CPU above the configured threshold.
    func buildActivityDetected() async -> Bool
}

/// Inspects live processes with `ps` to decide whether a build is running.
struct SystemBuildProbe: BuildProbe {
    var cpuThresholdPercent: Double

    /// Presence of any of these commands means a build is underway, regardless
    /// of CPU — `xcodebuild` only runs while it is driving a build.
    static let orchestratorNames = ["xcodebuild"]

    /// These run for as long as Xcode is open (its build service) or only
    /// briefly (compiler/linker), so mere presence proves nothing. They count
    /// only when their *combined* CPU crosses the threshold, i.e. active
    /// compilation. `ld` is deliberately omitted: as a substring it matches far
    /// too many unrelated process paths, and compilation dominates a build's
    /// wall-clock anyway.
    static let compilerNames = [
        "swift-frontend", "swiftc", "swift-build", "clang",
        "SWBBuildService", "XCBBuildService",
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
        // Emit "<%cpu> <command-path>" per line, no header.
        process.arguments = ["-Axo", "%cpu=,comm="]
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
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: " ") else { continue }

            let cpuText = trimmed[..<separator]
            let command = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard let cpu = Double(cpuText) else { continue }

            if orchestratorNames.contains(where: { command.localizedStandardContains($0) }) {
                return true
            }
            if compilerNames.contains(where: { command.localizedStandardContains($0) }) {
                compilerCPU += cpu
            }
        }

        return compilerCPU >= cpuThreshold
    }
}
