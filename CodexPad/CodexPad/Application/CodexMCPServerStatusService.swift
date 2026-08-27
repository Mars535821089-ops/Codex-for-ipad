#if SWIFT_PACKAGE
import CodexPadDomain
#endif
import Foundation
public enum CodexMCPAuthStatus: String, Codable, Equatable, Sendable { case unsupported, notLoggedIn, bearerToken, oauth }
public enum CodexMCPStartupState: String, Codable, Equatable, Sendable { case starting, ready, failed, cancelled }
public struct CodexMCPServerStatus: Codable, Equatable, Sendable {
 public let name: String; public let serverInfo: CodexJSONValue?; public let tools: [String: CodexJSONValue]; public let resources: [CodexMCPResource]; public let resourceTemplates: [CodexMCPResourceTemplate]; public let authStatus: CodexMCPAuthStatus; public let startupState: CodexMCPStartupState?; public let error: String?; public let failureReason: String?
 public init(name: String, serverInfo: CodexJSONValue? = nil, tools: [String: CodexJSONValue] = [:], resources: [CodexMCPResource] = [], resourceTemplates: [CodexMCPResourceTemplate] = [], authStatus: CodexMCPAuthStatus, startupState: CodexMCPStartupState? = nil, error: String? = nil, failureReason: String? = nil) { self.name=name; self.serverInfo=serverInfo; self.tools=tools; self.resources=resources; self.resourceTemplates=resourceTemplates; self.authStatus=authStatus; self.startupState=startupState; self.error=error; self.failureReason=failureReason }
}
public enum CodexMCPServerStatusDetail: String, Equatable, Sendable { case full, toolsAndAuthOnly }
public struct CodexMCPServerStatusPage: Equatable, Sendable { public let data:[CodexMCPServerStatus]; public let nextCursor:String?; public init(data:[CodexMCPServerStatus],nextCursor:String?){self.data=data;self.nextCursor=nextCursor} }
public final class CodexMCPServerStatusService: @unchecked Sendable {
 private struct Cursor: Codable { let version:Int; let offset:Int }; private let statuses:[CodexMCPServerStatus]; private let pageSize:Int
 public init(statuses:[CodexMCPServerStatus],pageSize:Int=100) throws { guard pageSize>0,statuses.map(\.name).allSatisfy({!$0.isEmpty}),Set(statuses.map(\.name)).count==statuses.count else { throw CodexMCPResourceError.invalidCatalog }; self.statuses=statuses.sorted{$0.name<$1.name};self.pageSize=pageSize }
 public func list(cursor:String?=nil,limit:Int?=nil,detail:CodexMCPServerStatusDetail = .full)throws->CodexMCPServerStatusPage { let offset:Int; if let cursor { guard let d=Data(base64Encoded:cursor),let c=try?JSONDecoder().decode(Cursor.self,from:d),c.version==1,c.offset>=0,c.offset<=statuses.count else {throw CodexMCPResourceError.invalidCursor};offset=c.offset } else {offset=0};let size=limit ?? pageSize;guard size>0 else {throw CodexMCPResourceError.invalidPageSize};let end=min(offset+size,statuses.count);let page=statuses[offset..<end].map{ s in detail == .full ? s : CodexMCPServerStatus(name:s.name,tools:s.tools,authStatus:s.authStatus,startupState:s.startupState,error:s.error,failureReason:s.failureReason)};let next=end<statuses.count ? (try?JSONEncoder().encode(Cursor(version:1,offset:end)).base64EncodedString()) : nil;return CodexMCPServerStatusPage(data:Array(page),nextCursor:next) }
}
