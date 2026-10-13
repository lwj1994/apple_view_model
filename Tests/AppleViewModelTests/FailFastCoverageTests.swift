#if os(macOS)
import Darwin
import XCTest
@_spi(Internal) @testable import AppleViewModel

private enum FailFastCoverageError: Error { case rejected }

@MainActor
final class FailFastCoverageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The startup probe verifies the original logger before the first reset.
        if ProcessInfo.processInfo.environment["APPLE_VIEW_MODEL_FAIL_FAST_CASE"] != "startup-logging" {
            TestEnv.reset()
        }
    }

    func test_processContracts() throws {
        let environment = ProcessInfo.processInfo.environment
        if let scenario = environment["APPLE_VIEW_MODEL_FAIL_FAST_CASE"] {
            exerciseScenario(scenario)
            if scenario == "startup-logging" { return }
            XCTFail("Expected \(scenario) to terminate the process")
            return
        }

        let scenarios: [(String, String?)] = [
            ("resolution", "ViewModel resolution failed:"),
            ("spec-build", "ViewModel builder failed:"),
            ("spec-builder", "ViewModel builder failed:"),
            ("arg1", "ViewModel builder failed:"),
            ("arg2", "ViewModel builder failed:"),
            ("arg3", "ViewModel builder failed:"),
            ("arg4", "ViewModel builder failed:"),
            ("binding-context", "No binding available."),
            ("disposed-dependency", "Cannot resolve dependencies from a disposed"),
            ("unknown-recycle", "instance not found in registry."),
            ("startup-logging", nil)
        ]
        // Each child runs only this probe, and exits before the next starts.
        // The parent suite remains serial and its registry is never shared.
        for (scenario, expectedMessage) in scenarios {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [
                "-XCTest", "AppleViewModelTests.FailFastCoverageTests/test_processContracts",
                Bundle(for: Self.self).bundleURL.path
            ]
            // Do not forward unrelated developer credentials to crash diagnostics.
            let inheritedKeys: Set<String> = ["PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"]
            var childEnvironment = environment.filter { inheritedKeys.contains($0.key) }
            childEnvironment["APPLE_VIEW_MODEL_FAIL_FAST_CASE"] = scenario
            childEnvironment["SWIFT_BACKTRACE"] = "enable=no"
            if let profile = environment["LLVM_PROFILE_FILE"] {
                // LLVM continuous mode keeps real counters even after a trap.
                // SwiftPM merges these alongside the normal test profiles.
                let directory = URL(fileURLWithPath: profile).deletingLastPathComponent()
                childEnvironment["LLVM_PROFILE_FILE"] = directory
                    .appendingPathComponent("failfast-\(scenario)-%p-%c.profraw").path
            }
            process.environment = childEnvironment
            let output = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = output
            let finished = expectation(description: "\(scenario) terminates")
            process.terminationHandler = { _ in finished.fulfill() }
            try process.run()
            wait(for: [finished], timeout: 15)
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                XCTFail("\(scenario) did not terminate")
            }
            let diagnostic = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let expectedMessage {
                XCTAssertEqual(process.terminationReason, .uncaughtSignal, scenario)
                XCTAssertTrue([SIGILL, SIGTRAP].contains(process.terminationStatus), scenario)
                XCTAssertTrue(diagnostic.contains(expectedMessage), "\(scenario): \(diagnostic)")
            } else {
                XCTAssertEqual(process.terminationReason, .exit, scenario)
                XCTAssertEqual(process.terminationStatus, 0, "\(scenario): \(diagnostic)")
            }
        }
    }

    private func exerciseScenario(_ scenario: String) {
        let binding = ViewModelBinding()
        defer { binding.dispose() }
        switch scenario {
        case "resolution":
            let spec = ViewModelSpec<CounterViewModel>(throwingBuilder: { throw FailFastCoverageError.rejected })
            _ = binding.read(spec)
        case "spec-build":
            let inner = ViewModelSpec<CounterViewModel>(throwingBuilder: { throw FailFastCoverageError.rejected })
            _ = binding.read(ViewModelSpec { inner.build() })
        case "spec-builder":
            let inner = ViewModelSpec<CounterViewModel>(throwingBuilder: { throw FailFastCoverageError.rejected })
            _ = binding.read(ViewModelSpec { inner.builder() })
        case "arg1":
            let inner = ViewModelSpecWithArg<CounterViewModel, Int>(throwingBuilder: { _ in throw FailFastCoverageError.rejected })
            _ = binding.read(ViewModelSpec { inner.builder(1) })
        case "arg2":
            let inner = ViewModelSpecWithArg2<CounterViewModel, Int, Int>(throwingBuilder: { _, _ in throw FailFastCoverageError.rejected })
            _ = binding.read(ViewModelSpec { inner.builder(1, 2) })
        case "arg3":
            let inner = ViewModelSpecWithArg3<CounterViewModel, Int, Int, Int>(throwingBuilder: { _, _, _ in throw FailFastCoverageError.rejected })
            _ = binding.read(ViewModelSpec { inner.builder(1, 2, 3) })
        case "arg4":
            let inner = ViewModelSpecWithArg4<CounterViewModel, Int, Int, Int, Int>(throwingBuilder: { _, _, _, _ in throw FailFastCoverageError.rejected })
            _ = binding.read(ViewModelSpec { inner.builder(1, 2, 3, 4) })
        case "binding-context":
            _ = ViewModelBindingHandler().binding
        case "disposed-dependency":
            let vm = binding.read(ViewModelSpec { CounterViewModel() })
            binding.dispose()
            _ = vm.viewModelBinding
        case "unknown-recycle":
            let vm = binding.read(ViewModelSpec { CounterViewModel() })
            binding.dispose()
            binding.recycle(vm)
        case "startup-logging":
            ViewModel.initialize(config: ViewModelConfig(isLoggingEnabled: true))
            _ = binding.read(ViewModelSpec<CounterViewModel>(key: "first", tag: "log") { CounterViewModel() })
            let latest = binding.read(ViewModelSpec<CounterViewModel>(key: "latest", tag: "log") { CounterViewModel() })
            let found: CounterViewModel? = try? ViewModel.readCached(tag: "log")
            XCTAssertTrue(found === latest)
        default:
            XCTFail("Unknown crash probe: \(scenario)")
        }
    }
}
#endif
