import Foundation

public enum CodexCoreTransportError: Error, Equatable, Sendable {
    case unsupportedModelConfiguration
    case unsupportedModelRequest
    case unsupportedTurnRequest
    case unsupportedRawHistoryRequest
    case unsupportedRawHistoryCommit
}

@MainActor
public protocol CodexModelCatalogClient: AnyObject {
    func submit(_ command: CodexModelCatalogCommand) throws
    func request(_ request: CodexAppServerModelRequest) throws -> Data
}

@MainActor
public protocol CodexCoreTransport: CodexModelCatalogClient {
    func submit(_ command: CodexCoreCommand) throws
    func submit(_ command: CodexRawHistoryCommit) throws
    func submit(_ command: CodexCompactHistoryCommit) throws
    func request(_ request: CodexAppServerThreadRequest) throws -> Data
    func request(_ request: CodexAppServerTurnRequest) throws -> Data
    func request(_ request: CodexRawHistoryRequest) throws -> Data
    func nextEvent() throws -> CodexCoreEvent?
}

public extension CodexCoreTransport {
    func request(_ request: CodexAppServerModelRequest) throws -> Data {
        throw CodexCoreTransportError.unsupportedModelRequest
    }

    func submit(_ command: CodexRawHistoryCommit) throws {
        throw CodexCoreTransportError.unsupportedRawHistoryCommit
    }

    func submit(_ command: CodexCompactHistoryCommit) throws {
        throw CodexCoreTransportError.unsupportedRawHistoryCommit
    }

    func request(_ request: CodexAppServerTurnRequest) throws -> Data {
        throw CodexCoreTransportError.unsupportedTurnRequest
    }

    func request(_ request: CodexRawHistoryRequest) throws -> Data {
        throw CodexCoreTransportError.unsupportedRawHistoryRequest
    }
}

public extension CodexModelCatalogClient {
    func submit(_ command: CodexModelCatalogCommand) throws {
        throw CodexCoreTransportError.unsupportedModelConfiguration
    }
}
