import SwiftUI

/// The App's shared visual vocabulary.
///
/// Every workspace used to derive its own container, section header, chip and
/// key/value idiom: `FlashWorkspaceSurface` (18pt inset, radius 12), `DebugCard`
/// (GroupBox + headline label), `HDCStatusView.section` (headline + divider,
/// gap 10), `DeviceDetailView.deviceSectionHeader` (subheadline + divider,
/// gap 7) and bare `GroupBox` in Trace, Flash's own details tree and Settings.
/// Four idioms with five sets of metrics read as five different products
/// inside one window.
///
/// The numbers below are the metrics table in
/// `docs/design/macos-ux-interaction-spec.md` §2 crossed with the concrete
/// values `docs/design/prototype.html` uses for the same roles. Where they
/// disagree the spec wins, because it is the higher authority; where the spec
/// only gives a range the prototype picks the point inside it.
enum WorkspaceMetrics {
  // MARK: Page

  /// `.page{padding:20px 24px 28px}` — the spec's 20–24 content inset, with the
  /// extra bottom inset that keeps the last row clear of the Job inspector.
  static let pageInsetHorizontal: CGFloat = 24
  static let pageInsetTop: CGFloat = 20
  static let pageInsetBottom: CGFloat = 28

  /// `.page{gap:20}` — the spec's 20–24 "gap between sections".
  static let sectionGap: CGFloat = 20
  /// `.grid2{gap:16}` — between peer blocks inside one section.
  static let blockGap: CGFloat = 16
  /// `.card{gap:10}` — the spec's 8–10 "gap inside a section".
  static let contentGap: CGFloat = 10
  /// Between a control and the label it belongs to.
  static let tightGap: CGFloat = 6
  /// `.kv{gap:4px 14px}` — between rows of one key/value list.
  static let rowGap: CGFloat = 4

  // MARK: Containers

  /// `.card{padding:14px 16px}`.
  static let cardPaddingHorizontal: CGFloat = 16
  static let cardPaddingVertical: CGFloat = 14
  /// Concentric radii, outermost first: a container is 11, a box inset in it is
  /// 9, a control inside that is 7. The spec's "container radius 10, inner
  /// control radius 6–8, obey concentric corners".
  static let cardRadius: CGFloat = 11
  static let insetRadius: CGFloat = 9
  static let controlRadius: CGFloat = 7
  /// `.okbox`/`.impact` and other tinted notices: `padding:8px 12px`–`10px 12px`.
  static let noticePaddingHorizontal: CGFloat = 12
  static let noticePaddingVertical: CGFloat = 9

  /// `.device-section h2{padding-bottom:7px}` — title to its hairline rule.
  static let sectionHeaderGap: CGFloat = 7

  // MARK: Rows and columns

  /// `.kv{gap:4px 14px}` — key column to value column.
  static let keyColumnGap: CGFloat = 14
  /// `.nav button{min-height:32px}`, and the spec's "navigation row 32".
  static let navigationRowHeight: CGFloat = 32
  /// `.drawer .bar{min-height:36px}`, and the spec's collapsed Job inspector 36.
  static let jobInspectorBarHeight: CGFloat = 36

  // MARK: Widths

  /// The width at which a two-column workspace body folds into one column,
  /// measured on the *content* width the columns are given rather than on the
  /// window. The prototype folds `.grid2` at a 1100pt viewport and
  /// `.device-layout` at 980; with a 232–300pt sidebar and a 24pt inset either
  /// side, both land near 720pt of content.
  static let twoColumnBreakpoint: CGFloat = 720
  /// One measure for every workspace body. `.device-layout` in the prototype
  /// caps at 920; Flash, Device and Trace each used to pick their own (760 /
  /// 960 / 1000), which is why the same window felt like three products. At
  /// the 1180pt reference the detail pane is ~926pt, so this fills the pane
  /// instead of leaving a dead column, and still bounds the measure on a
  /// maximised display.
  static let pageMaxWidth: CGFloat = 920
  /// A paragraph's own measure. `.flash-impact{max-width:470px}` and the
  /// prototype's other prose blocks stay short even when the page is wide.
  static let proseMaxWidth: CGFloat = 620
  /// `.device-layout{grid-template-columns:minmax(280px,.82fr) minmax(420px,1.18fr)}` —
  /// the leading column's share of a two-column device detail.
  static let splitLeadingColumnRatio: CGFloat = 0.82 / 2.0
}

/// The type roles from spec §2, resolved onto macOS's semantic sizes so a
/// caller never has to remember which `Font` happens to be 13pt today.
///
/// macOS resolves `.headline` and `.body` to 13pt, `.callout` to 12pt,
/// `.subheadline` to 11pt and `.caption` to 10pt.
enum WorkspaceFont {
  /// Section title — 13/semibold.
  static let sectionTitle = Font.headline
  /// Body and control text — 13/regular.
  static let body = Font.body
  /// Secondary and explanatory text — 12/regular.
  static let secondary = Font.callout
  /// Column headers, chips and other decorations — 11/semibold.
  static let label = Font.subheadline.weight(.semibold)
  /// The smallest supporting label, e.g. a status-strip caption — 11/regular.
  static let caption = Font.subheadline
  /// Paths, hashes, versions, serials, device and Job IDs — 12 mono.
  static let monospacedValue = Font.callout.monospaced()
  /// Log lines and other dense mono blocks — 11 mono.
  static let monospacedDense = Font.subheadline.monospaced()
  /// Durations, byte counts, rounds and PIDs that change in place.
  static let tabularValue = Font.body.monospacedDigit()
  static let tabularSecondary = Font.callout.monospacedDigit()
}

/// A state's tone. Colour is never the only carrier: every surface built from
/// this pairs `color` with `symbol` and the state's own words, which is what
/// spec §2 and §4.4 require.
enum WorkspaceTone: Sendable {
  case neutral
  case ok
  case warning
  case danger
  case accent
  /// Execution mode badges — purple solid / amber dashed outline (spec §4.4).
  case planned
  case simulated

  var color: Color {
    switch self {
    case .neutral: .secondary
    case .ok: .green
    case .warning: .orange
    case .danger: .red
    case .accent: .accentColor
    case .planned: .purple
    case .simulated: .orange
    }
  }

  var symbol: String {
    switch self {
    case .neutral: "questionmark.circle"
    case .ok: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .danger: "xmark.octagon"
    case .accent: "info.circle"
    case .planned: "square.dashed"
    case .simulated: "theatermasks"
    }
  }

  /// The tint behind a notice of this tone. Kept low so the border and the
  /// symbol, not the fill, carry the meaning.
  var wash: Color {
    switch self {
    case .neutral: Color(nsColor: .quaternaryLabelColor).opacity(0.35)
    default: color.opacity(0.08)
    }
  }

  var line: Color {
    switch self {
    case .neutral: Color(nsColor: .separatorColor)
    default: color.opacity(0.38)
    }
  }
}

// MARK: - Page scaffold

/// A scrolling workspace body: one content inset, one gap between sections, and
/// the full width of the detail pane unless the caller asks for a narrower
/// measure.
struct WorkspacePage<Content: View>: View {
  /// The widest the body may grow. `nil` means "use the detail pane", which is
  /// what spec §3 asks for: content must not stay locked in a narrow card while
  /// the window leaves large meaningless empty space beside it.
  var maximumWidth: CGFloat?
  var spacing: CGFloat = WorkspaceMetrics.sectionGap
  @ViewBuilder let content: Content

  init(
    maximumWidth: CGFloat? = nil,
    spacing: CGFloat = WorkspaceMetrics.sectionGap,
    @ViewBuilder content: () -> Content
  ) {
    self.maximumWidth = maximumWidth
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing) {
        content
      }
      .frame(maxWidth: maximumWidth ?? .infinity, alignment: .topLeading)
      .padding(.horizontal, WorkspaceMetrics.pageInsetHorizontal)
      .padding(.top, WorkspaceMetrics.pageInsetTop)
      .padding(.bottom, WorkspaceMetrics.pageInsetBottom)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }
}

/// The strip every workspace opens with.
///
/// The page's own name is in the window toolbar; repeating it in the content
/// would give one detail pane two perceivable main headings, which spec §3 and
/// §6 both forbid. What stays is the one line that explains the page and the
/// page-level controls that do not belong in the toolbar.
struct WorkspaceHeaderBar<Controls: View>: View {
  let summary: Text
  var summaryIdentifier: String?
  @ViewBuilder let controls: Controls

  init(
    summary: Text,
    summaryIdentifier: String? = nil,
    @ViewBuilder controls: () -> Controls
  ) {
    self.summary = summary
    self.summaryIdentifier = summaryIdentifier
    self.controls = controls()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.blockGap) {
        summaryText
        Spacer(minLength: WorkspaceMetrics.contentGap)
        controls
      }
      VStack(alignment: .leading, spacing: WorkspaceMetrics.contentGap) {
        summaryText
        HStack(spacing: WorkspaceMetrics.tightGap) { controls }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var summaryText: some View {
    summary
      .font(WorkspaceFont.secondary)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier(summaryIdentifier ?? "")
  }
}

extension WorkspaceHeaderBar where Controls == EmptyView {
  init(summary: Text, summaryIdentifier: String? = nil) {
    self.init(summary: summary, summaryIdentifier: summaryIdentifier) { EmptyView() }
  }
}

// MARK: - Grouping

/// A section title over its hairline rule, the grouping the design uses instead
/// of a bordered container wherever the content is not an independently
/// selectable object (spec §1.3, "fewer cards, more grouping").
struct WorkspaceSectionHeader<Accessory: View>: View {
  let title: Text
  var identifier: String?
  @ViewBuilder let accessory: Accessory

  init(
    _ title: Text,
    identifier: String? = nil,
    @ViewBuilder accessory: () -> Accessory
  ) {
    self.title = title
    self.identifier = identifier
    self.accessory = accessory()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionHeaderGap) {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.contentGap) {
        title
          .font(WorkspaceFont.sectionTitle)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier(identifier ?? "")
        Spacer(minLength: 0)
        accessory
      }
      Divider()
    }
  }
}

extension WorkspaceSectionHeader where Accessory == EmptyView {
  init(_ title: Text, identifier: String? = nil) {
    self.init(title, identifier: identifier) { EmptyView() }
  }
}

/// A titled group with no border: header, rule, content.
struct WorkspaceSection<Content: View, Accessory: View>: View {
  let title: Text
  var identifier: String?
  var spacing: CGFloat = WorkspaceMetrics.contentGap
  @ViewBuilder let accessory: Accessory
  @ViewBuilder let content: Content

  init(
    _ title: Text,
    identifier: String? = nil,
    spacing: CGFloat = WorkspaceMetrics.contentGap,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.identifier = identifier
    self.spacing = spacing
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      WorkspaceSectionHeader(title, identifier: identifier) { accessory }
      content
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }
}

extension WorkspaceSection where Accessory == EmptyView {
  init(
    _ title: Text,
    identifier: String? = nil,
    spacing: CGFloat = WorkspaceMetrics.contentGap,
    @ViewBuilder content: () -> Content
  ) {
    self.init(title, identifier: identifier, spacing: spacing, accessory: { EmptyView() }, content: content)
  }
}

/// The one bordered container in the App: `.card` from the prototype. Reserved
/// for a block that can be acted on as a unit — a device, an image choice, a
/// running Job — rather than used as generic decoration.
struct WorkspaceCard<Content: View>: View {
  var spacing: CGFloat = WorkspaceMetrics.contentGap
  @ViewBuilder let content: Content

  init(
    spacing: CGFloat = WorkspaceMetrics.contentGap,
    @ViewBuilder content: () -> Content
  ) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      content
    }
    .padding(.horizontal, WorkspaceMetrics.cardPaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.cardPaddingVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color(nsColor: .controlBackgroundColor),
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.cardRadius, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
  }
}

/// A titled card: the card above with the same section header the borderless
/// grouping uses, so a page that mixes both still has one heading rhythm.
struct WorkspaceTitledCard<Content: View, Accessory: View>: View {
  let title: Text
  var symbol: String?
  var identifier: String?
  @ViewBuilder let accessory: Accessory
  @ViewBuilder let content: Content

  init(
    _ title: Text,
    symbol: String? = nil,
    identifier: String? = nil,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.symbol = symbol
    self.identifier = identifier
    self.accessory = accessory()
    self.content = content()
  }

  var body: some View {
    WorkspaceCard {
      HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
        if let symbol {
          Image(systemName: symbol)
            .font(WorkspaceFont.sectionTitle)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        title
          .font(WorkspaceFont.sectionTitle)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier(identifier ?? "")
        Spacer(minLength: 0)
        accessory
      }
      content
    }
  }
}

extension WorkspaceTitledCard where Accessory == EmptyView {
  init(
    _ title: Text,
    symbol: String? = nil,
    identifier: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.init(title, symbol: symbol, identifier: identifier, accessory: { EmptyView() }, content: content)
  }
}

/// A box inset inside a card or section — the prototype's `.okbox` and
/// `warnbox`. The tone's border and symbol carry the state; the wash only
/// separates it from the surface it sits on.
struct WorkspaceNotice<Content: View>: View {
  let tone: WorkspaceTone
  var symbol: String?
  var identifier: String?
  @ViewBuilder let content: Content

  init(
    tone: WorkspaceTone,
    symbol: String? = nil,
    identifier: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.tone = tone
    self.symbol = symbol
    self.identifier = identifier
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: WorkspaceMetrics.tightGap) {
      Image(systemName: symbol ?? tone.symbol)
        .foregroundStyle(tone.color)
        .accessibilityHidden(true)
      content
        .font(WorkspaceFont.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, WorkspaceMetrics.noticePaddingHorizontal)
    .padding(.vertical, WorkspaceMetrics.noticePaddingVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      tone.wash,
      in: RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkspaceMetrics.insetRadius, style: .continuous)
        .stroke(tone.line, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier ?? "")
  }
}

/// An outline capsule: `.chip` in the prototype. Border and text share the
/// tone's colour over a transparent fill, so it stays legible under Increase
/// Contrast and never reads as a filled control the user can press.
struct WorkspaceChip: View {
  let text: Text
  var tone: WorkspaceTone = .neutral
  var symbol: String?
  /// `.chip.sim` is the only dashed variant (spec §4.4, simulated execution).
  var isDashed = false
  var identifier: String?

  var body: some View {
    HStack(spacing: 5) {
      if let symbol {
        Image(systemName: symbol)
          .accessibilityHidden(true)
      }
      text
    }
    .font(WorkspaceFont.label)
    .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .overlay {
      Capsule().stroke(
        tone == .neutral ? Color(nsColor: .separatorColor) : tone.color,
        style: StrokeStyle(lineWidth: 1, dash: isDashed ? [3, 2] : []))
    }
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(identifier ?? "")
  }
}

// MARK: - Key/value lists

/// One row of a key/value list. Values default to mono because the list exists
/// for the things spec §2 says must be comparable character by character.
struct WorkspaceFactRow: View {
  let name: Text
  let value: Text
  var isMonospaced = true
  var identifier: String?

  var body: some View {
    GridRow(alignment: .firstTextBaseline) {
      name
        .font(WorkspaceFont.secondary)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
      value
        .font(isMonospaced ? WorkspaceFont.monospacedValue : WorkspaceFont.body)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(identifier ?? "")
    }
  }
}

/// The `.kv` list: a fixed key column so every value in a page lines up, and a
/// value column that wraps rather than truncating a hash.
struct WorkspaceFactGrid<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: WorkspaceMetrics.keyColumnGap,
      verticalSpacing: WorkspaceMetrics.rowGap
    ) {
      content
    }
  }
}

// MARK: - Responsive layout

/// The prototype's `.grid2`: two columns while the pane is wide enough, one
/// column below the breakpoint.
///
/// The decision reads the container's real width rather than asking
/// `ViewThatFits` to compare ideal sizes. A column whose content is prose has
/// an unbounded ideal width, so `ViewThatFits` would fold to one column even in
/// a wide pane — and a column pinned to a fixed width fills the reference
/// window but nothing else. Reading the width keeps both the fold and the fill
/// correct.
struct WorkspaceColumns<Leading: View, Trailing: View>: View {
  var spacing: CGFloat = WorkspaceMetrics.blockGap
  var breakpoint: CGFloat = WorkspaceMetrics.twoColumnBreakpoint
  /// The share of the width the leading column takes when both fit.
  /// `.device-layout` uses .82fr : 1.18fr; an even split is the default.
  var leadingRatio: CGFloat = 0.5
  @ViewBuilder let leading: Leading
  @ViewBuilder let trailing: Trailing

  @State private var containerWidth: CGFloat = 0

  init(
    spacing: CGFloat = WorkspaceMetrics.blockGap,
    breakpoint: CGFloat = WorkspaceMetrics.twoColumnBreakpoint,
    leadingRatio: CGFloat = 0.5,
    @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.spacing = spacing
    self.breakpoint = breakpoint
    self.leadingRatio = leadingRatio
    self.leading = leading()
    self.trailing = trailing()
  }

  var body: some View {
    let columns = max(0, containerWidth - spacing)
    Group {
      if containerWidth >= breakpoint {
        HStack(alignment: .top, spacing: spacing) {
          leading
            .frame(width: (columns * leadingRatio).rounded(.down), alignment: .topLeading)
          trailing
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      } else {
        VStack(alignment: .leading, spacing: WorkspaceMetrics.sectionGap) {
          leading
          trailing
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      containerWidth = width
    }
  }
}
