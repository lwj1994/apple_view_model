public struct ScannerInvocation {
    public let output: String
    public let sources: [String]
    public let lint: Bool
    public let configurationPath: String?

    public init(arguments: [String]) throws {
        var output: String?
        var sources: [String] = []
        var lint = false
        var configurationPath: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--lint": lint = true
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
        guard let output, configurationPath == nil || lint else { throw InvocationError.usage }
        self.output = output
        self.sources = sources
        self.lint = lint
        self.configurationPath = configurationPath
    }
}

private enum InvocationError: Error, CustomStringConvertible {
    case usage
    var description: String {
        "usage: AppleViewModelDependencyScanner --output <stamp.swift> [--lint [--config <config.json>]] [source.swift ...]"
    }
}
