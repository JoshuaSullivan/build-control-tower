import Testing

@testable import BuildControlTower

/// Tests for the pure `ps`-output parser that decides whether a build is
/// actively running. Uses representative `ps -Awwxo %cpu=,ucomm=,args=` lines.
struct BuildProbeParsingTests {
    private let threshold = 40.0

    @Test func detectsXcodebuildRegardlessOfCPU() {
        let output = """
             0.1 xcodebuild /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build
             0.0 cfprefsd /usr/sbin/cfprefsd
            """
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func detectsActiveCompilationAboveThreshold() {
        let output = """
            98.4 swift-frontend /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c Main.swift
            75.2 swift-frontend /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c Other.swift
             0.0 secinitd /usr/libexec/secinitd
            """
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func idleXcodeBuildServiceDoesNotCount() {
        // XCBBuildService is always running while Xcode is open, but idle here.
        let output = """
             0.0 XCBBuildService /Applications/Xcode.app/Contents/SharedFrameworks/SwiftPM.framework/.../XCBBuildService
             0.3 runningboardd /usr/libexec/runningboardd
             1.1 Dock /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func unrelatedBusyProcessesDoNotCount() {
        let output = """
            180.0 Safari /Applications/Safari.app/Contents/MacOS/Safari
             99.0 python3 /usr/bin/python3
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func compilationBelowThresholdDoesNotCount() {
        let output = """
             5.0 clang /Applications/Xcode.app/.../usr/bin/clang -c Main.c
             3.0 swift-frontend /Applications/Xcode.app/.../usr/bin/swift-frontend -c Main.swift
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func toleratesBlankAndMalformedLines() {
        let output = """

            not-a-cpu-value clang /some/path
             42.0
            nan clang /usr/bin/clang -c Bad.c
            -50.0 clang /usr/bin/clang -c Bad.c
            50.0 clang /Applications/Xcode.app/.../usr/bin/clang -c Main.c
            """
        // The single clang line at 50% >= 40% threshold should still register.
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test(arguments: [
        "SWBBuildService /Applications/Xcode.app/Contents/MacOS/SWBBuildService",
        "XCBBuildService /Applications/Xcode.app/Contents/MacOS/XCBBuildService",
        "SourceKitService /Applications/Xcode.app/Contents/MacOS/SourceKitService",
        "node /opt/homebrew/bin/xcodebuildmcp project-discovery list-schemes",
        "bash /bin/bash -c xcodebuild build",
        "python3 /tmp/clang-tools/worker.py",
        "not-clang /usr/local/bin/not-clang",
    ])
    func busyServicesAndLookalikeCommandsDoNotCount(command: String) {
        #expect(!SystemBuildProbe.isBuildActive(psOutput: "200.0 \(command)", cpuThreshold: threshold))
    }

    @Test(arguments: [
        "-list -workspace App.xcworkspace",
        "-showBuildSettings -scheme App",
        "-showBuildSettingsForIndex -scheme App",
        "-showdestinations -scheme App",
        "-showsdks",
        "-version",
    ])
    func xcodebuildQueriesDoNotCount(arguments: String) {
        let output = "435.1 xcodebuild /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \(arguments)"
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test(arguments: [
        "swift-frontend /usr/bin/swift-frontend -frontend -index-file Main.swift",
        "swiftc /usr/bin/swiftc -typecheck Main.swift",
        "clang /usr/bin/clang -cc1 -fsyntax-only Main.m",
        "clang /usr/bin/clang -cc1 -index-file-path Main.m",
        "swift-frontend /usr/bin/swift-frontend -emit-module -o /DerivedData/App/Index.noindex/Build/Products/App.swiftmodule",
    ])
    func indexingDoesNotCount(command: String) {
        let output = """
            200.0 \(command)
            20.0 clang /usr/bin/clang -c Main.c
            """
        #expect(!SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func normalCompilationStillCountsWhenItWritesIndexData() {
        let output = """
            25.0 swift-frontend /Applications/Xcode 27.app/usr/bin/swift-frontend -c Main.swift -index-store-path /DerivedData/Index.noindex/DataStore -index-unit-output-path /Build/Main.o
            20.0 clang++ /Applications/Xcode 27.app/usr/bin/clang++ -c Other.cpp -index-store-path /DerivedData/Index.noindex/DataStore
            """
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }

    @Test func aQueryDoesNotHideAnotherBuild() {
        let output = """
            435.1 xcodebuild /usr/bin/xcodebuild -list
              0.0 xcodebuild /Applications/Xcode 27.app/usr/bin/xcodebuild -scheme App test
            """
        #expect(SystemBuildProbe.isBuildActive(psOutput: output, cpuThreshold: threshold))
    }
}
