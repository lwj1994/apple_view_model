import Foundation
import PackagePlugin

@main
struct AppleViewModelDependencyCheck: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        return [command(
            sources: target.sourceFiles(withSuffix: "swift").map(\.url),
            tool: try context.tool(named: "AppleViewModelDependencyScanner").url,
            directory: context.pluginWorkDirectoryURL
        )]
    }

    fileprivate func command(sources: [URL], tool: URL, directory: URL) -> Command {
        let sources = sources.sorted { $0.path < $1.path }
        // A comment-only Swift output records completion without adding a bundled
        // resource. Declared inputs make edits and source-list changes incremental.
        let output = directory.appendingPathComponent("AppleViewModelDependencyCheck.generated.swift")
        return .buildCommand(
            displayName: "Checking AppleViewModel dependency cycles",
            executable: tool,
            arguments: ["--output", output.path] + sources.map(\.path),
            inputFiles: sources,
            outputFiles: [output]
        )
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension AppleViewModelDependencyCheck: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        [command(
            sources: target.inputFiles.filter { $0.url.pathExtension == "swift" }.map(\.url),
            tool: try context.tool(named: "AppleViewModelDependencyScanner").url,
            directory: context.pluginWorkDirectoryURL
        )]
    }
}
#endif
