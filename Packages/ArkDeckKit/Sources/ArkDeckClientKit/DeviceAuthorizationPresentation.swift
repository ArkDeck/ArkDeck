/// Display-only outcome of the bounded candidate authorization read.
/// These values never authorize an operation, adopt a Target, or manage HDC keys.
/// Provider authorization and retry policy remain in the Runtime/Provider layer.
public enum DeviceAuthorizationPresentation: Sendable, Equatable {
  case unauthorizedWaitingForTrust
  case ready
  case denied(reason: String)
  case timedOut
  case cancelled
  case keyAccessDenied(reason: String)
  case unavailable(reason: String)
}
