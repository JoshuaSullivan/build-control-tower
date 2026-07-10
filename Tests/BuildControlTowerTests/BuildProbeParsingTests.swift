import Testing

@testable import BuildControlTower

/// Tests for the pure `ps`-output parser that decides whether a build is
/// actively running. Uses representative `ps -Axo %cpu=,comm=` lines.
struct BuildProbeParsingTests {
    private let threshold = 40.0

    @Test func detectsXcodebuildRegardlessOfCPU() {
        let output = """
             0.1 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild
             0.0 /usr/sbin/cfprefsd
            """
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func detectsActiveCompilationAboveThreshold() {
        let output = """
            98.4 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
            75.2 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend
             0.0 /usr/libexec/secinitd
            """
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func idleXcodeBuildServiceDoesNotCount() {
        // XCBBuildService is always running while Xcode is open, but idle here.
        let output = """
             0.0 /Applications/Xcode.app/Contents/SharedFrameworks/SwiftPM.framework/.../XCBBuildService
             0.3 /usr/libexec/runningboardd
             1.1 /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func unrelatedBusyProcessesDoNotCount() {
        let output = """
            180.0 /Applications/Safari.app/Contents/MacOS/Safari
             99.0 /usr/bin/python3
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func compilationBelowThresholdDoesNotCount() {
        let output = """
             5.0 /Applications/Xcode.app/.../usr/bin/clang
             3.0 /Applications/Xcode.app/.../usr/bin/swift-frontend
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func toleratesBlankAndMalformedLines() {
        let output = """

            not-a-cpu-value /some/path
             42.0
            50.0 /Applications/Xcode.app/.../usr/bin/clang
            """
        // The single clang line at 50% >= 40% threshold should still register.
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }
}
