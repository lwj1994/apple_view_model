import Foundation
import PackagePlugin

@main
struct AppleViewModelLint: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        return [command(
            sources: target.sourceFiles(withSuffix: "swift").map(\.url),
            tool: try context.tool(named: "AppleViewModelDependencyScanner").url,
            directory: context.pluginWorkDirectoryURL,
            root: context.package.directoryURL
        )]
    }

    fileprivate func command(sources: [URL], tool: URL, directory: URL, root: URL) -> Command {
        let sources = sources.sorted { $0.path < $1.path }
        let output = directory.appendingPathComponent("AppleViewModelLint.generated.swift")
        let config = root.appendingPathComponent(".apple-view-model-lint.json")
        let hasConfig = FileManager.default.fileExists(atPath: config.path)
        return .buildCommand(
            displayName: "Checking AppleViewModel usage and dependency cycles",
            executable: tool,
            arguments: ["--output", output.path, "--lint"]
                + (hasConfig ? ["--config", config.path] : []) + sources.map(\.path),
            inputFiles: sources + (hasConfig ? [config] : []),
            outputFiles: [output]
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension AppleViewModelLint: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        [command(
            sources: target.inputFiles.filter { $0.url.pathExtension == "swift" }.map(\.url),
            tool: try context.tool(named: "AppleViewModelDependencyScanner").url,
            directory: context.pluginWorkDirectoryURL,
            root: context.xcodeProject.directoryURL
        )]
    }
}
#endif
