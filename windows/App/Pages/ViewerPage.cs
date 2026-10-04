using System.Globalization;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;

namespace ArkDeck.App.Pages;

/// <summary>
/// Viewer, as the macOS UI dump Viewer (<c>UIDumpWorkspaceView</c>): capture the current view of
/// a Connected adopted device as one typed Runtime Job, then inspect only its verified same-Job
/// Artifacts — the screenshot with the components' bounds, the complete component tree (arrow
/// keys move, Left and Right collapse and expand), a search over it, and the selected
/// component's properties, layout, accessibility, raw fields and Advanced Dump. Capture never
/// shows disabled: while it cannot run, choosing it says why.
/// </summary>
public sealed partial class ViewerPage() : SurfacePage<ViewerState>(
    "viewer", "viewer.title", UiStrings.AppNavigationUiDump,
    "viewer.refresh", UiStrings.ViewerToolbarRefresh, "viewer.loading", UiStrings.SettingsCommonLoading)
{
    private static readonly string[] Tabs = ["properties", "layout", "accessibility", "rawDump", "advancedDump"];

    private StackPanel _content = new() { Spacing = 12 };
    private TextBlock _status = Ui.Status("viewer.status");
    private ViewerState? _state;
    private string _targetId = "";
    private ViewerCaptureOutcome? _captured;
    private string? _captureFailure;
    private bool _capturing;
    private string? _root;
    private string? _selected;
    private readonly HashSet<string> _expanded = new(StringComparer.Ordinal);
    private string _query = "";
    private bool _showBounds;
    private string _tab = "properties";
    private double _treePercent = 60;
    private ViewerAdvancedDumpOutcome? _dump;
    private string? _dumpFor;
    private bool _dumpLoading;
    private string _dumpQuery = "";

    protected override Task<ViewerState> LoadAsync() => App.Loader.ViewerAsync();

    private ViewerCapture? Capture => _captured?.Capture;

    private ViewerTarget? Target => _state?.JoinedTargets.FirstOrDefault(t => t.TargetId == _targetId);

    protected override void Render(ViewerState state, StackPanel body)
    {
        _state = state;
        if (_targetId.Length > 0 && state.JoinedTargets.All(t => t.TargetId != _targetId)) _targetId = "";
        if (_targetId.Length == 0 && state.JoinedTargets.FirstOrDefault(t => t.Connected) is { } connected) _targetId = connected.TargetId;
        var said = _status.Text;
        _status = Ui.Status("viewer.status");
        Ui.SetText(_status, said);
        _content = new StackPanel { Spacing = 12 };
        body.Children.Add(_content);
        body.Children.Add(_status);
        RenderContent();
    }

    private void RenderContent()
    {
        if (_state is null) return;
        _content.Children.Clear();
        _content.Children.Add(Toolbar(_state));
        if (Capture is { } capture)
        {
            _content.Children.Add(Ui.Card(Screenshot(capture), "viewer.pane.screenshot.card"));
            _content.Children.Add(Ui.Card(Tree(capture), "viewer.pane.tree.card"));
            _content.Children.Add(Separator());
            _content.Children.Add(Ui.Card(Properties(capture), "viewer.properties"));
            _content.Children.Add(Footer(capture));
        }
        else
        {
            _content.Children.Add(Ui.Card(Empty(_state), "viewer.empty"));
        }
    }

    // ---- toolbar ----

    private FlowPanel Toolbar(ViewerState state)
    {
        var device = new ComboBox { Header = S.Text(UiStrings.ViewerToolbarDevice), MinWidth = 200, MaxWidth = 280 };
        AutomationProperties.SetAutomationId(device, "viewer.target");
        AutomationProperties.SetName(device, S.Text(UiStrings.ViewerToolbarDevice));
        var none = new ComboBoxItem { Content = S.Text(UiStrings.ViewerToolbarNoDevice), Tag = "" };
        AutomationProperties.SetAutomationId(none, "viewer.target.none");
        device.Items.Add(none);
        device.SelectedItem = none;
        foreach (var target in state.JoinedTargets)
        {
            var item = new ComboBoxItem { Content = target.Connected ? target.Title : $"{target.Title} · {target.BlockedReason}", Tag = target.TargetId };
            AutomationProperties.SetAutomationId(item, "viewer.target." + target.TargetId);
            device.Items.Add(item);
            if (target.TargetId == _targetId) device.SelectedItem = item;
        }
        device.SelectionChanged += (_, _) =>
        {
            if (device.SelectedItem is not ComboBoxItem { Tag: string id } || id == _targetId) return;
            // A target change clears the failure and in-flight results; it never starts a capture.
            _targetId = id;
            _captureFailure = null;
            RenderContent();
        };
        var row = Ui.Row(device);
        if (Capture is { } capture)
        {
            var roots = new ComboBox { Header = S.Text(UiStrings.ViewerToolbarCurrentScreen), MinWidth = 160, MaxWidth = 240 };
            AutomationProperties.SetAutomationId(roots, "viewer.root");
            AutomationProperties.SetName(roots, S.Text(UiStrings.ViewerToolbarCurrentScreen));
            foreach (var id in capture.Roots)
            {
                var node = capture.NodeById(id)!;
                var item = new ComboBoxItem { Content = $"#{node.DeviceId ?? node.Identity} {node.Type}", Tag = id };
                roots.Items.Add(item);
                if (id == _root) roots.SelectedItem = item;
            }
            roots.SelectionChanged += (_, _) =>
            {
                if (roots.SelectedItem is not ComboBoxItem { Tag: string id } || id == _root) return;
                _root = id;
                _selected = id;
                _expanded.Add(id);
                RenderContent();
            };
            row.Children.Add(roots);
            if (capture.CapturedAtUtc is { Length: > 0 } at) row.Children.Add(Ui.Text("viewer.capturedAt", at, "ArkDeckMonoStyle"));
            var search = new TextBox { Header = S.Text(UiStrings.ViewerToolbarSearch), PlaceholderText = S.Text(UiStrings.ViewerToolbarSearch), Text = _query, MinWidth = 150, MaxWidth = 250 };
            AutomationProperties.SetAutomationId(search, "viewer.search");
            AutomationProperties.SetName(search, S.Text(UiStrings.ViewerToolbarSearch));
            search.TextChanged += (_, _) =>
            {
                if (search.Text == _query) return;
                _query = search.Text;
                // Typing selects the first match.
                if (UIDumpCapture.Search(capture, _root, _query) is [var first, ..]) _selected = first;
                RenderSearchAndTree(capture);
            };
            row.Children.Add(search);
            row.Children.Add(_matches = new FlowPanel());
            RenderMatches(capture);
        }
        var label = _capturing ? UiStrings.ViewerToolbarCapturing : Capture is null ? UiStrings.ViewerToolbarCapture : UiStrings.ViewerToolbarRecapture;
        if (!_capturing) row.Children.Add(Ui.Button("viewer.recapture", S.Text(label), async (_, _) => await CaptureAsync(), accent: true));
        else row.Children.Add(Ui.Row(Ui.Progress("viewer.recapture.progress", S.Text(label)), Ui.Text("viewer.recapture", S.Text(label))));
        return row;
    }

    private FlowPanel _matches = new();

    private void RenderMatches(ViewerCapture capture)
    {
        _matches.Children.Clear();
        if (_query.Length == 0) return;
        var matches = UIDumpCapture.Search(capture, _root, _query);
        var index = _selected is null ? -1 : matches.ToList().IndexOf(_selected);
        var count = Ui.Text("viewer.search.matchCount", matches.Count == 0 ? "0 / 0" : $"{index + 1} / {matches.Count}", "ArkDeckMonoStyle");
        AutomationProperties.SetName(count, $"{S.Text(UiStrings.ViewerSearchMatchCount)}: {(matches.Count == 0 ? 0 : index + 1)} / {matches.Count}");
        _matches.Children.Add(count);
        // The steppers are offered only when there is somewhere to step to.
        if (matches.Count > 1)
        {
            _matches.Children.Add(Ui.Button("viewer.search.previous", "↑", (_, _) => Step(capture, -1)));
            _matches.Children.Add(Ui.Button("viewer.search.next", "↓", (_, _) => Step(capture, 1)));
            AutomationProperties.SetName(_matches.Children[^2], S.Text(UiStrings.ViewerSearchPrevious));
            AutomationProperties.SetName(_matches.Children[^1], S.Text(UiStrings.ViewerSearchNext));
        }
    }

    private void Step(ViewerCapture capture, int direction)
    {
        var matches = UIDumpCapture.Search(capture, _root, _query);
        if (matches.Count == 0) return;
        var index = _selected is null ? -1 : matches.ToList().IndexOf(_selected);
        _selected = matches[((index + direction) % matches.Count + matches.Count) % matches.Count];
        RenderSearchAndTree(capture);
    }

    private void RenderSearchAndTree(ViewerCapture capture)
    {
        RenderMatches(capture);
        if (_treeHost is { } host)
        {
            host.Child = TreeList(capture);
        }
        RenderSelectionDependents(capture);
    }

    // ---- empty state ----

    private StackPanel Empty(ViewerState state)
    {
        var message = state.Targets.Unavailable is { } load ? load.ReasonText(S)
            : Target is not { } target ? S.Text(UiStrings.ViewerEmptySelectTarget)
            : !target.Connected ? S.Format(UiStrings.ViewerEmptyTargetBlocked, target.TargetId, target.BlockedReason!)
            : !state.Operation.IsAvailable ? string.Join(Environment.NewLine, state.Operation.Availability.Reasons)
            : S.Text(UiStrings.ViewerEmptyExplain);
        var panel = Ui.Stack(8,
            Ui.Heading("viewer.empty.title", S.Text(UiStrings.ViewerEmptyTitle), AutomationHeadingLevel.Level2),
            Ui.Text("viewer.empty.message", message));
        if (_captureFailure is { } failure)
        {
            var text = Ui.Text("viewer.captureFailure", failure);
            text.Foreground = (Brush)Application.Current.Resources["SystemFillColorCautionBrush"];
            panel.Children.Add(text);
        }
        return panel;
    }

    // ---- screenshot ----

    private UIElement Screenshot(ViewerCapture capture)
    {
        var header = Ui.Row(Ui.Heading("viewer.pane.screenshot", S.Text(UiStrings.ViewerPaneScreenshot), AutomationHeadingLevel.Level2));
        if (!capture.CoordinatesAreVerified) header.Children.Add(Ui.Text("viewer.pane.coordinatesUnverified", S.Text(UiStrings.ViewerPaneCoordinatesUnverified), "ArkDeckCaptionStyle"));
        var bounds = new CheckBox { Content = S.Text(UiStrings.ViewerPaneShowBounds), IsChecked = _showBounds };
        AutomationProperties.SetAutomationId(bounds, "viewer.showBounds");
        bounds.Click += (_, _) =>
        {
            _showBounds = bounds.IsChecked == true;
            RenderSelectionDependents(capture);
        };
        header.Children.Add(bounds);
        var pane = Ui.Stack(8, header);
        var surface = new Grid { Width = capture.ScreenshotWidth, Height = capture.ScreenshotHeight };
        var image = new Image { Stretch = Stretch.Fill, Width = capture.ScreenshotWidth, Height = capture.ScreenshotHeight };
        var decoded = true;
        try
        {
            var bitmap = new BitmapImage();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(capture.ScreenshotPng);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.FlushAsync().AsTask().GetAwaiter().GetResult();
            }
            bitmap.SetSource(stream);
            image.Source = bitmap;
        }
        catch (Exception error) when (error is ArgumentException or System.Runtime.InteropServices.COMException)
        {
            decoded = false;
        }
        AutomationProperties.SetAccessibilityView(image, AccessibilityView.Raw);
        surface.Children.Add(image);
        if (!decoded) surface.Children.Add(Ui.Text("viewer.screenshot.unavailable", S.Text(UiStrings.ViewerScreenshotUnavailable)));
        _outlines = new Canvas { Width = capture.ScreenshotWidth, Height = capture.ScreenshotHeight };
        surface.Children.Add(_outlines);
        if (capture.CoordinatesAreVerified)
        {
            // One click surface: the front-most component under the point is selected.
            var hit = new Border { Background = new SolidColorBrush(Colors.Transparent) };
            AutomationProperties.SetAutomationId(hit, "viewer.screenshot.hitTest");
            AutomationProperties.SetName(hit, S.Text(UiStrings.ViewerScreenshotSelectLabel));
            AutomationProperties.SetHelpText(hit, S.Text(UiStrings.ViewerScreenshotSelectHint));
            hit.PointerPressed += (_, e) =>
            {
                var point = e.GetCurrentPoint(surface).Position;
                if (UIDumpCapture.HitTest(capture, _root, point.X, point.Y) is { } identity) Select(capture, identity);
            };
            surface.Children.Insert(2, hit);
        }
        else
        {
            var note = Ui.Text("viewer.screenshot.unverifiedDetail", S.Text(UiStrings.ViewerScreenshotUnverifiedDetail), "ArkDeckCaptionStyle");
            note.Foreground = (Brush)Application.Current.Resources["SystemFillColorCautionBrush"];
            pane.Children.Add(note);
        }
        pane.Children.Add(new Viewbox { Child = surface, MaxHeight = 520, MaxWidth = 420, HorizontalAlignment = HorizontalAlignment.Left, Stretch = Stretch.Uniform });
        return pane;
    }

    private Canvas _outlines = new();

    private void RenderOutlines(ViewerCapture capture)
    {
        _outlines.Children.Clear();
        if (!capture.CoordinatesAreVerified) return;
        var accent = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"];
        var faint = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        foreach (var node in capture.SubtreeNodes(_root).Where(n => n.Visible).OrderBy(n => n.Depth))
        {
            if (UIDumpCapture.VisibleBounds(node, capture) is not { } box) continue;
            var selected = node.Identity == _selected;
            // Outlines are for screen readers (invoking one selects it), not Tab stops: the tree is the keyboard path.
            var outline = new Button
            {
                Width = Math.Max(1, box.Width),
                Height = Math.Max(1, box.Height),
                Padding = new Thickness(0),
                IsTabStop = false,
                Background = selected ? new SolidColorBrush(Microsoft.UI.ColorHelper.FromArgb(26, 0, 120, 212)) : new SolidColorBrush(Colors.Transparent),
                BorderBrush = selected ? accent : _showBounds ? faint : new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(selected ? 2 : 1),
                Opacity = selected || !_showBounds ? 1 : 0.35,
                IsHitTestVisible = false,
            };
            AutomationProperties.SetAutomationId(outline, "viewer.screenshot.node." + node.Identity);
            AutomationProperties.SetName(outline, $"#{node.DeviceId ?? node.Identity} {node.Type}");
            var identity = node.Identity;
            outline.Click += (_, _) => Select(capture, identity);
            Canvas.SetLeft(outline, box.X);
            Canvas.SetTop(outline, box.Y);
            _outlines.Children.Add(outline);
        }
        if (_selected is { } chosen && capture.NodeById(chosen) is { } picked && UIDumpCapture.VisibleBounds(picked, capture) is { } at)
        {
            var chip = new Border { Background = accent, Padding = new Thickness(4, 1, 4, 1), IsHitTestVisible = false,
                Child = new TextBlock { Text = $"#{picked.DeviceId ?? picked.Identity} {picked.Type}", Foreground = new SolidColorBrush(Colors.White), FontSize = 12 } };
            AutomationProperties.SetAccessibilityView(chip, AccessibilityView.Raw);
            Canvas.SetLeft(chip, at.X);
            Canvas.SetTop(chip, Math.Max(0, at.Y - 18));
            _outlines.Children.Add(chip);
        }
    }

    // ---- the tree ----

    private Border? _treeHost;
    private TextBlock _treeCount = new();

    private StackPanel Tree(ViewerCapture capture)
    {
        _treeCount = Ui.Text("viewer.tree.count", "", "ArkDeckCaptionStyle");
        var header = Ui.Row(Ui.Heading("viewer.pane.tree", S.Text(UiStrings.ViewerPaneTree), AutomationHeadingLevel.Level2), _treeCount);
        _treeHost = new Border { Height = Math.Max(150, 520 * _treePercent / 100) };
        _treeHost.Child = TreeList(capture);
        return Ui.Stack(6, header, _treeHost);
    }

    private UIElement TreeList(ViewerCapture capture)
    {
        var rows = UIDumpCapture.VisibleRows(capture, _root, _expanded, _query);
        Ui.SetText(_treeCount, $"{rows.Count} / {capture.SubtreeNodes(_root).Count}");
        if (_query.Length > 0 && rows.Count == 0)
        {
            return Ui.Text("viewer.tree.noMatches", S.Text(UiStrings.ViewerTreeNoMatches), "ArkDeckCaptionStyle");
        }
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single };
        AutomationProperties.SetAutomationId(list, "viewer.tree.scroll");
        AutomationProperties.SetName(list, S.Text(UiStrings.ViewerTreeLabel));
        var baseDepth = _root is { } r && capture.NodeById(r) is { } rootNode ? rootNode.Depth : 0;
        ListViewItem? selected = null;
        foreach (var node in rows)
        {
            var identity = node.Identity;
            var content = new Grid { ColumnSpacing = 4, Padding = new Thickness(6 + 12 * Math.Max(0, node.Depth - baseDepth), 0, 0, 0) };
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            if (node.Children.Count > 0)
            {
                var open = _expanded.Contains(identity) || _query.Length > 0;
                var disclosure = new Button { Content = new FontIcon { Glyph = open ? "" : "", FontSize = 10 }, IsTabStop = false, Padding = new Thickness(2), Width = 24, Height = 24 };
                AutomationProperties.SetAutomationId(disclosure, "viewer.tree.disclosure." + identity);
                AutomationProperties.SetName(disclosure, S.Text(open ? UiStrings.ViewerTreeCollapse : UiStrings.ViewerTreeExpand));
                disclosure.Click += (_, _) => Toggle(capture, identity);
                content.Children.Add(disclosure);
            }
            var label = new TextBlock { Text = RowText(node), TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(label, 1);
            content.Children.Add(label);
            var item = Ui.Item("viewer.tree.node." + identity, RowText(node), content);
            item.MinHeight = 26;
            item.Tag = identity;
            AutomationProperties.SetItemStatus(item, S.Text(identity == _selected ? UiStrings.ViewerTreeSelected : UiStrings.ViewerTreeNotSelected));
            list.Items.Add(item);
            if (identity == _selected) selected = item;
        }
        list.SelectedItem = selected;
        list.SelectionChanged += (_, _) =>
        {
            if (list.SelectedItem is ListViewItem { Tag: string id } && id != _selected)
            {
                _selected = id;
                RenderMatches(capture);
                RenderSelectionDependents(capture);
            }
        };
        // Left collapses (or goes to the parent), Right expands (or goes to the first child).
        list.KeyDown += (_, e) =>
        {
            if (_selected is not { } current || capture.NodeById(current) is not { } node) return;
            if (e.Key == Windows.System.VirtualKey.Left)
            {
                if (node.Children.Count > 0 && _expanded.Contains(current)) Toggle(capture, current);
                else if (node.ParentIdentity is { } parent && capture.SubtreeNodes(_root).Any(n => n.Identity == parent)) Select(capture, parent);
                e.Handled = true;
            }
            else if (e.Key == Windows.System.VirtualKey.Right && node.Children.Count > 0)
            {
                if (!_expanded.Contains(current)) Toggle(capture, current);
                else Select(capture, node.Children[0]);
                e.Handled = true;
            }
        };
        if (selected is not null) list.Loaded += (_, _) => list.ScrollIntoView(selected, ScrollIntoViewAlignment.Default);
        return list;
    }

    private static string RowText(ViewerNode node) =>
        string.Join(" ", new[] { node.Type, node.Text, node.DeviceId is null ? null : "#" + node.DeviceId }.Where(s => !string.IsNullOrEmpty(s)));

    private void Toggle(ViewerCapture capture, string identity)
    {
        if (!_expanded.Remove(identity)) _expanded.Add(identity);
        if (_treeHost is { } host) host.Child = TreeList(capture);
        FocusTreeRow(identity);
    }

    private void Select(ViewerCapture capture, string identity)
    {
        _selected = identity;
        foreach (var ancestor in capture.Ancestors(identity)) _expanded.Add(ancestor);
        if (_treeHost is { } host) host.Child = TreeList(capture);
        RenderMatches(capture);
        RenderSelectionDependents(capture);
        FocusTreeRow(identity);
    }

    private void FocusTreeRow(string identity)
    {
        if (_treeHost?.Child is ListView list && list.Items.OfType<ListViewItem>().FirstOrDefault(i => (string)i.Tag == identity) is { } item)
        {
            list.DispatcherQueue.TryEnqueue(() => item.Focus(FocusState.Keyboard));
        }
    }

    // ---- separator ----

    private UIElement Separator()
    {
        var slider = new Slider { Minimum = 35, Maximum = 68, StepFrequency = 4, SmallChange = 4, Value = _treePercent, Width = 200, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(slider, "viewer.inspector.separator");
        AutomationProperties.SetName(slider, S.Text(UiStrings.ViewerSeparatorLabel));
        AutomationProperties.SetItemStatus(slider, S.Format(UiStrings.ViewerSeparatorValue, (long)_treePercent));
        slider.ValueChanged += (_, e) =>
        {
            _treePercent = Math.Clamp(e.NewValue, 35, 68);
            if (_treeHost is { } host) host.Height = Math.Max(150, 520 * _treePercent / 100);
            AutomationProperties.SetItemStatus(slider, S.Format(UiStrings.ViewerSeparatorValue, (long)_treePercent));
        };
        return slider;
    }

    // ---- properties ----

    private StackPanel _properties = new();

    private StackPanel Properties(ViewerCapture capture)
    {
        _properties = new StackPanel { Spacing = 8 };
        RenderSelectionDependents(capture);
        return _properties;
    }

    private void RenderSelectionDependents(ViewerCapture capture)
    {
        RenderOutlines(capture);
        _properties.Children.Clear();
        if (_selected is not { } identity || capture.NodeById(identity) is not { } node)
        {
            _properties.Children.Add(Ui.Text("viewer.properties.selectPrompt", S.Text(UiStrings.ViewerPropertiesSelectPrompt), "ArkDeckCaptionStyle"));
            return;
        }
        var chips = Ui.Row(Ui.Heading("viewer.properties.type", node.Type, AutomationHeadingLevel.Level2), Ui.Text("viewer.properties.id", "#" + (node.DeviceId ?? node.Identity), "ArkDeckMonoStyle"));
        if (node.Clickable == true) chips.Children.Add(Ui.Text("viewer.chip.interactive", S.Text(UiStrings.ViewerChipInteractive), "ArkDeckCaptionStyle"));
        if (node.Visible) chips.Children.Add(Ui.Text("viewer.chip.visible", S.Text(UiStrings.ViewerChipVisible), "ArkDeckCaptionStyle"));
        _properties.Children.Add(chips);
        var crumbs = capture.Ancestors(identity).Append(identity).Select(capture.NodeById).OfType<ViewerNode>().Select(n => $"#{n.DeviceId ?? n.Identity} {n.Type}");
        _properties.Children.Add(Ui.Text("viewer.properties.breadcrumb", string.Join(" › ", crumbs), "ArkDeckCaptionStyle"));
        var tabs = new FlowPanel();
        foreach (var tab in Tabs)
        {
            var title = S.Text(tab == "advancedDump" ? UiStrings.WindowsViewerTabAdvancedDump : "viewer.tab." + tab);
            var button = new ToggleButton { Content = title, IsChecked = tab == _tab };
            AutomationProperties.SetAutomationId(button, "viewer.inspector.tab." + tab);
            AutomationProperties.SetName(button, S.Format(UiStrings.ViewerActionShow, title));
            var chosen = tab;
            button.Click += async (_, _) =>
            {
                _tab = chosen;
                RenderSelectionDependents(capture);
                if (chosen == "advancedDump") await LoadAdvancedDumpAsync(capture, node);
            };
            tabs.Children.Add(button);
        }
        _properties.Children.Add(tabs);
        _properties.Children.Add(_tab switch
        {
            "layout" => Group(UiStrings.ViewerGroupGeometry,
                    ("bounds", node.Bounds is { } b ? $"x {Number(b.X)}, y {Number(b.Y)}, {Number(b.Width)} × {Number(b.Height)}" : null),
                    (S.Text(UiStrings.ViewerFieldScreenshotMapping), capture.CoordinatesAreVerified && UIDumpCapture.VisibleBounds(node, capture) is not null ? S.Text(UiStrings.ViewerValueVerified) : null),
                    (S.Text(UiStrings.ViewerFieldHitTest), capture.CoordinatesAreVerified && UIDumpCapture.VisibleBounds(node, capture) is not null ? S.Text(UiStrings.ViewerValueAvailable) : null))
                .Also(Group(UiStrings.ViewerGroupPaint, ("zIndex", node.ZIndex is { } z ? Number(z) : null))),
            "accessibility" => Group(UiStrings.ViewerGroupSemantics,
                    (S.Text(UiStrings.ViewerFieldAccessibleLabel), node.Text), (S.Text(UiStrings.ViewerFieldDescription), node.InspectorId))
                .Also(Group(UiStrings.ViewerGroupFocus, ("visible", YesNo(node.Visible)), ("focusable", YesNo(node.Focusable)), ("focused", YesNo(node.Focused)))),
            "rawDump" => RawDump(node),
            "advancedDump" => AdvancedDump(capture, node),
            _ => Group(UiStrings.ViewerGroupIdentity, ("id", node.DeviceId), ("type", node.Type), ("inspectorId", node.InspectorId), ("text", node.Text))
                .Also(Group(UiStrings.ViewerGroupState, ("enabled", YesNo(node.Enabled)), ("visible", YesNo(node.Visible)), ("clickable", YesNo(node.Clickable)),
                    ("focusable", YesNo(node.Focusable)), ("focused", YesNo(node.Focused)))),
        });
    }

    private static string Number(double value) => value.ToString("0.##", CultureInfo.InvariantCulture);

    private string? YesNo(bool? value) => value is null ? null : S.Text(value.Value ? UiStrings.ViewerValueYes : UiStrings.ViewerValueNo);

    private StackPanel Group(string titleKey, params (string Label, string? Value)[] rows)
    {
        var group = Ui.Stack(4, Ui.Heading("viewer.group." + titleKey.Split('.')[^1], S.Text(titleKey), AutomationHeadingLevel.Level3));
        foreach (var (label, value) in rows.Where(r => !string.IsNullOrEmpty(r.Value)))
        {
            group.Children.Add(Ui.Fact("viewer.field." + label.Replace(' ', '.'), label, value!));
        }
        return group;
    }

    private UIElement RawDump(ViewerNode node)
    {
        var raw = UIDumpCapture.RawDump(node);
        var text = Ui.Text("viewer.rawDump", string.IsNullOrEmpty(raw) ? S.Text(UiStrings.ViewerPropertiesRawUnavailable) : raw, "ArkDeckMonoStyle");
        text.IsTextSelectionEnabled = true;
        return text;
    }

    // ---- Advanced Dump ----

    private async Task LoadAdvancedDumpAsync(ViewerCapture capture, ViewerNode node)
    {
        if (_dumpLoading || (_dumpFor == node.Identity && _dump?.Fields is not null)) return;
        if (UIDumpCapture.AdvancedDumpSelectionFor(capture, node.Identity) is not { } selection || Target is not { } target)
        {
            return;
        }
        _dumpLoading = true;
        _dumpFor = node.Identity;
        _dump = null;
        RenderSelectionDependents(capture);
        try
        {
            _dump = await Task.Run(() => App.Loader.AdvancedDumpAsync(target.Target, selection));
            MainWindow.Instance.Report(_dump);
        }
        finally
        {
            _dumpLoading = false;
            if (_selected == node.Identity) RenderSelectionDependents(capture);
            Ui.Say(_status, _dump?.Failure ?? S.Text(UiStrings.ViewerAdvancedDumpSearchResults));
        }
    }

    private UIElement AdvancedDump(ViewerCapture capture, ViewerNode node)
    {
        if (UIDumpCapture.AdvancedDumpSelectionFor(capture, node.Identity) is null)
        {
            return Ui.Text("viewer.advancedDump", S.Text(UiStrings.WindowsViewerAdvancedDumpNoIds), "ArkDeckCaptionStyle");
        }
        if (_dumpLoading && _dumpFor == node.Identity) return Ui.Text("viewer.advancedDump.loading", S.Text(UiStrings.WindowsViewerAdvancedDumpLoading));
        if (_dumpFor != node.Identity || _dump is null)
        {
            return Ui.Text("viewer.advancedDump", S.Text(UiStrings.ViewerAdvancedDumpUnavailable), "ArkDeckCaptionStyle");
        }
        if (_dump.Fields is not { } fields)
        {
            var failure = Ui.Text("viewer.advancedDump", _dump.Failure ?? "");
            failure.Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
            return Ui.Stack(6, failure, Ui.Row(Ui.Button("viewer.advancedDump.retry", S.Text(UiStrings.WindowsTraceViewerRetry), async (_, _) =>
            {
                _dump = null;
                await LoadAdvancedDumpAsync(capture, node);
            })));
        }
        var panel = new StackPanel { Spacing = 4 };
        var rows = new StackPanel { Spacing = 2 };
        var search = new TextBox { PlaceholderText = S.Text(UiStrings.ViewerAdvancedDumpSearchPlaceholder), Text = _dumpQuery, MinWidth = 200, MaxWidth = 320, HorizontalAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetAutomationId(search, "viewer.advancedDump.search");
        AutomationProperties.SetName(search, S.Text(UiStrings.ViewerAdvancedDumpSearch));
        ToolTipService.SetToolTip(search, S.Text(UiStrings.WindowsViewerAdvancedDumpSearchShortcut));
        var count = Ui.Text("viewer.advancedDump.search.matchCount", "", "ArkDeckMonoStyle");
        AutomationProperties.SetName(count, S.Text(UiStrings.ViewerAdvancedDumpSearchResults));
        void Fill()
        {
            rows.Children.Clear();
            var shown = fields.Where(f => _dumpQuery.Length == 0 || f.Key.Contains(_dumpQuery, StringComparison.OrdinalIgnoreCase) || f.Value.Contains(_dumpQuery, StringComparison.OrdinalIgnoreCase)).ToArray();
            Ui.SetText(count, $"{shown.Length} / {fields.Count}");
            if (shown.Length == 0)
            {
                rows.Children.Add(Ui.Row(Ui.Text("viewer.advancedDump.search.noResults", S.Text(UiStrings.ViewerAdvancedDumpSearchNoResults), "ArkDeckCaptionStyle"),
                    Ui.Button("viewer.advancedDump.search.noResults.clear", S.Text(UiStrings.ViewerAdvancedDumpSearchClear), (_, _) => search.Text = "")));
            }
            foreach (var field in shown) rows.Children.Add(Ui.Fact("viewer.advancedDump.field." + field.Key, field.Key, field.Value));
        }
        search.TextChanged += (_, _) =>
        {
            _dumpQuery = search.Text;
            Fill();
        };
        search.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape) search.Text = "";
        };
        var bar = Ui.Row(search, count);
        if (_dumpQuery.Length > 0) bar.Children.Add(Ui.Button("viewer.advancedDump.search.clear", S.Text(UiStrings.ViewerAdvancedDumpSearchClear), (_, _) => search.Text = ""));
        panel.Children.Add(bar);
        panel.Children.Add(rows);
        Fill();
        return panel;
    }

    // ---- footer ----

    private TextBlock Footer(ViewerCapture capture)
    {
        var text = S.Format(UiStrings.ViewerFooterNodes, (long)capture.Nodes.Count);
        if (_captured?.Metrics is { } m)
        {
            static string Ms(long? ms) => ms is null ? "—" : ms >= 1000 ? (ms.Value / 1000.0).ToString("0.00", CultureInfo.InvariantCulture) + "s" : ms + "ms";
            var size = m.ReadBytes >= 1024 * 1024 ? (m.ReadBytes / 1048576.0).ToString("0.0", CultureInfo.InvariantCulture) + " MB"
                : (m.ReadBytes / 1024.0).ToString("0.0", CultureInfo.InvariantCulture) + " KB";
            var rate = m.ReadMilliseconds > 0 ? (m.ReadBytes / 1048576.0 / (m.ReadMilliseconds / 1000.0)).ToString("0.0", CultureInfo.InvariantCulture) + " MB/s" : "—";
            var total = (m.SubmitMilliseconds ?? 0) + (m.RunMilliseconds ?? 0) + m.ListMilliseconds + m.ReadMilliseconds + m.ParseMilliseconds;
            text += $" · submit {Ms(m.SubmitMilliseconds)} · run {Ms(m.RunMilliseconds)} · list {Ms(m.ListMilliseconds)} · read {size}/{Ms(m.ReadMilliseconds)} ({rate}) · parse {Ms(m.ParseMilliseconds)} · Σ {Ms(total)}";
        }
        else
        {
            text += " · " + S.Text(UiStrings.ViewerFooterNotMeasured);
        }
        return Ui.Text("viewer.footer", text, "ArkDeckMonoStyle");
    }

    // ---- capture ----

    private async Task CaptureAsync()
    {
        if (_capturing || _state is null) return;
        var reason = Target is not { } target ? S.Text(UiStrings.ViewerEmptySelectTarget)
            : !target.Connected ? S.Format(UiStrings.ViewerEmptyTargetBlocked, target.TargetId, target.BlockedReason!)
            : !_state.Operation.IsAvailable ? string.Join(Environment.NewLine, _state.Operation.Availability.Reasons)
            : null;
        if (reason is not null)
        {
            _captureFailure = reason;
            RenderContent();
            Ui.Say(_status, reason);
            return;
        }
        _capturing = true;
        _captureFailure = null;
        RenderContent();
        Ui.Say(_status, S.Text(UiStrings.ViewerToolbarCapturing));
        try
        {
            var outcome = await Task.Run(() => App.Loader.CaptureViewAsync(Target!.Target));
            MainWindow.Instance.Report(outcome);
            if (outcome.Capture is { } capture)
            {
                _captured = outcome;
                // The unique focused root, else the first; the search cleared, the root expanded.
                var focusedRoots = capture.Roots.Where(r => capture.SubtreeNodes(r).Any(n => n.Focused == true)).ToArray();
                _root = focusedRoots.Length == 1 ? focusedRoots[0] : capture.PrimaryRootIdentity ?? capture.Roots.FirstOrDefault();
                _selected = _root;
                _query = "";
                _expanded.Clear();
                if (_root is not null) _expanded.Add(_root);
                _dump = null;
                _dumpFor = null;
                Ui.Say(_status, S.Format(UiStrings.ViewerFooterNodes, (long)capture.Nodes.Count));
            }
            else
            {
                _captureFailure = outcome.Failure;
                Ui.Say(_status, outcome.Failure ?? "");
            }
        }
        finally
        {
            _capturing = false;
            RenderContent();
        }
    }
}

internal static class PanelExtensions
{
    /// <summary>Two groups one after the other.</summary>
    public static StackPanel Also(this StackPanel first, StackPanel second) => Ui.Stack(12, first, second);
}
