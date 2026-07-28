import Foundation

enum LoadPhase: Equatable {
    case idle
    case loading
    case ready
    case failure
}

enum InstagramDemoError: LocalizedError {
    case missingEntity(String)
    case startupOrder

    var errorDescription: String? {
        switch self {
        case .missingEntity(let identifier):
            return "No demo entity exists for \(identifier)."
        case .startupOrder:
            return "InitViewModel must load the current user before comments are submitted."
        }
    }
}
