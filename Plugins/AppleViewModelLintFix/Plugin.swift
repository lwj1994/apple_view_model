import Foundation
import PackagePlugin

/// `swift package --allow-writing-to-package-directory apple-view-model-fix [--target <name> ...]`
@main
struct AppleViewModelLintFix: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var extractor = ArgumentExtractor(arguments)
        let names = extractor.extractOption(named: "target")
        let targets = names.isEmpty ? context.package.targets : try context.package.targets(named: names)
        let sources = targets.compactMap { $0 as? SourceModuleTarget }
            .flatMap { $0.sourceFiles(withSuffix: "swift").map(\.url) }
        try fix(sources: sources, tool: try context.tool(named: "AppleViewModelDependencyScanner").url,
                root: context.package.directoryURL)
    }

    fileprivate func fix(sources: [URL], tool: URL, root: URL) throws {
        guard !sources.isEmpty else { return }
        let config = root.appendingPathComponent(".apple-view-model-lint.json")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--lint", "--fix"]
            + (FileManager.default.fileExists(atPath: config.path) ? ["--config", config.path] : [])
            + sources.map(\.path).sorted()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixError(description: "AppleViewModelDependencyScanner exited with \(process.terminationStatus)")
        }
    }
}

private struct FixError: Error, CustomStringConvertible {
    let description: String
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension AppleViewModelLintFix: XcodeCommandPlugin {
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
        var extractor = ArgumentExtractor(arguments)
        let names = Set(extractor.extractOption(named: "target"))
        let targets = context.xcodeProject.targets.filter { names.isEmpty || names.contains($0.displayName) }
        try fix(sources: targets.flatMap { $0.inputFiles.filter { $0.url.pathExtension == "swift" }.map(\.url) },
                tool: try context.tool(named: "AppleViewModelDependencyScanner").url,
                root: context.xcodeProject.directoryURL)
    }
}
#endif
