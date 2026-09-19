import ArkDeckClientKit
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
    .init(name: RuntimeTraceParameterName.syntax.rawValue, profileValue: "true"),
    .init(name: RuntimeTraceParameterName.layout.rawValue, profileValue: "true"),
    .init(name: RuntimeTraceParameterName.build.rawValue, profileValue: "true"),
    .init(name: RuntimeTraceParameterName.measure.rawValue, profileValue: "true"),
    .init(name: RuntimeTraceParameterName.sync.rawValue, profileValue: "true"),
    .init(name: RuntimeTraceParameterName.debug.rawValue, profileValue: "1"),
    .init(name: RuntimeTraceParameterName.performanceMonitor.rawValue, profileValue: "true"),
    .init(name: RuntimeTraceParameterName.graphic.rawValue, profileValue: "1"),
    .init(name: RuntimeTraceParameterName.animation.rawValue, profileValue: "1"),
  ]

  public static func definition(named name: String) -> TraceDebugParameterDefinition? {
    definitions.first { $0.name == name }
  }

  public static func index(of name: String) -> Int? {
    definitions.firstIndex { $0.name == name }
  }
}
