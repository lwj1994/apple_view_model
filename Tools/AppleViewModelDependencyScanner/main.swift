import DependencyScannerCore
import Foundation

// A cycle is a warning and always succeeds. Invocation/I/O failures are errors:
// silently skipping a requested scan would hide a broken build integration.
do {
    let invocation = try ScannerInvocation(arguments: Array(CommandLine.arguments.dropFirst()))
    let output = URL(fileURLWithPath: invocation.output)
    let sources = try invocation.sources.map { path in
        ScannerSource(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                      text: try String(contentsOfFile: path, encoding: .utf8))
    }
    let cycles: [DependencyCycle]
    let warnings: [ViewModelLintWarning]
    if invocation.lint {
        let configuration = try invocation.configurationPath.map {
            try JSONDecoder().decode(ViewModelLintConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        } ?? ViewModelLintConfiguration()
        let report = ViewModelLint.scan(sources, configuration: configuration)
        cycles = report.cycles
        warnings = report.warnings
    } else {
        cycles = DependencyScanner.scan(sources)
        warnings = []
    }
    for cycle in cycles {
        for diagnostic in cycle.diagnostics { print(diagnostic) }
    }
    for warning in warnings { print(warning.diagnostic) }
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let usageSummary = invocation.lint ? " Usage warnings: \(warnings.count)." : ""
    try "// AppleViewModel dependency scan completed. Potential cycles: \(cycles.count).\(usageSummary)\n"
        .write(to: output, atomically: true, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("error: AppleViewModel dependency scanner: \(error)\n".utf8))
    exit(1)
}
