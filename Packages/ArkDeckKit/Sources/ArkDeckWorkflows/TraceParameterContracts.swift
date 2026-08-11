import Foundation

public struct TraceDebugParameterDefinition: Equatable, Sendable {
  public let name: String
  public let profileValue: String

  public init(name: String, profileValue: String) {
    self.name = name
    self.profileValue = profileValue
  }
}

public enum TraceDebugParameterCatalog {
  public static let definitions: [TraceDebugParameterDefinition] = [
    .init(name: "persist.ace.trace.syntax.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.layout.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.build.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.measure.debug.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.sync.debug.enabled", profileValue: "true"),
    .init(name: "persist.ace.debug.enabled", profileValue: "1"),
    .init(name: "persist.ace.performance.monitor.enabled", profileValue: "true"),
    .init(name: "persist.sys.graphic.openDebugTrace", profileValue: "1"),
    .init(name: "persist.rosen.animationtrace.enabled", profileValue: "1"),
  ]

  public static func definition(named name: String) -> TraceDebugParameterDefinition? {
    definitions.first { $0.name == name }
  }

  public static func index(of name: String) -> Int? {
    definitions.firstIndex { $0.name == name }
  }
}
