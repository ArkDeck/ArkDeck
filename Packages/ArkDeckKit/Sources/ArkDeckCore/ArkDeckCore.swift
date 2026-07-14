public enum ArkDeckCoreModule {
    public static let identifier = "ArkDeckCore"
}

public enum ArkDeckNavigationItem: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overview
    case flash
    case debug
    case uiDump
    case trace
    case history

    public var id: String { rawValue }

    public var localizationKey: String {
        switch self {
        case .overview: "app.navigation.overview"
        case .flash: "app.navigation.flash"
        case .debug: "app.navigation.debug"
        case .uiDump: "app.navigation.uiDump"
        case .trace: "app.navigation.trace"
        case .history: "app.navigation.history"
        }
    }

    public var systemImageName: String {
        switch self {
        case .overview: "rectangle.grid.2x2"
        case .flash: "bolt.fill"
        case .debug: "ladybug"
        case .uiDump: "rectangle.3.group"
        case .trace: "waveform.path.ecg"
        case .history: "clock.arrow.circlepath"
        }
    }
}
