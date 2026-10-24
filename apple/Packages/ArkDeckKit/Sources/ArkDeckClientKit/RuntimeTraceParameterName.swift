// Display vocabulary shared with the remaining Swift trace adapter. Values
// used to configure a Provider stay outside ClientKit. Keep declaration order
// identical to the published trace observation projection.
package enum RuntimeTraceParameterName: String, CaseIterable {
  case syntax = "persist.ace.trace.syntax.enabled"
  case layout = "persist.ace.trace.layout.enabled"
  case build = "persist.ace.trace.build.enabled"
  case measure = "persist.ace.trace.measure.debug.enabled"
  case sync = "persist.ace.trace.sync.debug.enabled"
  case debug = "persist.ace.debug.enabled"
  case performanceMonitor = "persist.ace.performance.monitor.enabled"
  case graphic = "persist.sys.graphic.openDebugTrace"
  case animation = "persist.rosen.animationtrace.enabled"
}
