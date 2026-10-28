import DependencyScannerCore
import Foundation

// A cycle is a warning and always succeeds. Invocation/I/O failures are errors:
// silently skipping a requested scan would hide a broken build integration.
do {
    let invocation = try ScannerInvocation(arguments: Array(CommandLine.arguments.dropFirst()))
    var sources = try invocation.sources.map { path in
        ScannerSource(path: URL(fileURLWithPath: path).standardizedFileURL.path,
                      text: try String(contentsOfFile: path, encoding: .utf8))
    }
    let configuration = try invocation.configurationPath.map {
        try JSONDecoder().decode(ViewModelLintConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
    } ?? ViewModelLintConfiguration()
    if invocation.fix {
        // Write each changed file, then report what still needs a person.
        let fixed = ViewModelLint.fix(sources, configuration: configuration)
        for source in fixed {
            try source.text.write(toFile: source.path, atomically: true, encoding: .utf8)
            print("AppleViewModelLint: fixed \(source.path)")
        }
        let changed = Dictionary(uniqueKeysWithValues: fixed.map { ($0.path, $0) })
        sources = sources.map { changed[$0.path] ?? $0 }
    }
    let cycles: [DependencyCycle]
    let warnings: [ViewModelLintWarning]
    if invocation.lint {
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
    if let path = invocation.output {
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let usageSummary = invocation.lint ? " Usage warnings: \(warnings.count)." : ""
        try "// AppleViewModel dependency scan completed. Potential cycles: \(cycles.count).\(usageSummary)\n"
            .write(to: output, atomically: true, encoding: .utf8)
    }
} catch {
    FileHandle.standardError.write(Data("error: AppleViewModel dependency scanner: \(error)\n".utf8))
    exit(1)
}
