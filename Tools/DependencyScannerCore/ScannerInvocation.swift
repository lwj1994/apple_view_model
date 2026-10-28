public struct ScannerInvocation {
    /// Build stamp path; optional only when fixing sources in place.
    public let output: String?
    public let sources: [String]
    public let lint: Bool
    /// Rewrites sources with safe lint fixes instead of only reporting.
    public let fix: Bool
    public let configurationPath: String?

    public init(arguments: [String]) throws {
        var output: String?
        var sources: [String] = []
        var lint = false
        var fix = false
        var configurationPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--lint": lint = true
            case "--fix": fix = true
            case "--output", "--config":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else { throw InvocationError.usage }
                if argument == "--output" { output = arguments[index] }
                else { configurationPath = arguments[index] }
            default:
                guard !argument.hasPrefix("--") else { throw InvocationError.usage }
                sources.append(argument)
            }
            index += 1
        }
        guard output != nil || fix, configurationPath == nil || lint, !fix || lint else {
            throw InvocationError.usage
        }
        self.output = output
        self.sources = sources
        self.lint = lint
        self.fix = fix
        self.configurationPath = configurationPath
    }
}

private enum InvocationError: Error, CustomStringConvertible {
    case usage
    var description: String {
        "usage: AppleViewModelDependencyScanner --output <stamp.swift> [--lint [--config <config.json>]] [source.swift ...]\n"
            + "       AppleViewModelDependencyScanner --lint --fix [--config <config.json>] [source.swift ...]"
    }
}
