import Foundation

enum AppError: LocalizedError {
    case general(String)
    case processTimeout(String)
    case processFailed(exitCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .general(let message):
            return message
        case .processTimeout(let message):
            return message
        case .processFailed(_, let message):
            return message
        }
    }
}
