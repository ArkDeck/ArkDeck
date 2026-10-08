using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Controls;

/// <summary>
/// Explicit, stretched columns that become rows when the available width or text size
/// requires it. Reflow keeps the same elements, selection and keyboard focus.
/// </summary>
public sealed partial class AdaptiveColumns : Grid
{
    private readonly IReadOnlyList<double> _weights;
    private readonly double _minimumColumnWidth;
    private readonly double _spacing;
    private bool? _columns;

    public AdaptiveColumns(IReadOnlyList<UIElement> children, IReadOnlyList<double>? weights = null,
        double minimumColumnWidth = 320, double spacing = 16)
    {
        _weights = weights ?? Enumerable.Repeat(1.0, children.Count).ToArray();
        if (_weights.Count != children.Count || _weights.Any(weight => weight <= 0))
            throw new ArgumentException("Each column needs a positive weight.", nameof(weights));
        _minimumColumnWidth = minimumColumnWidth;
        _spacing = spacing;
        foreach (var child in children)
        {
            if (child is not FrameworkElement element)
                throw new ArgumentException("A layout pane must be a framework element.", nameof(children));
            element.VerticalAlignment = VerticalAlignment.Top;
            Children.Add(child);
        }
        Reflow(0);
        SizeChanged += (_, args) => Reflow(args.NewSize.Width);
        Loaded += (_, _) =>
        {
            Ui.AccessibilitySettings.TextScaleFactorChanged += TextScaleChanged;
            Reflow(ActualWidth);
        };
        Unloaded += (_, _) => Ui.AccessibilitySettings.TextScaleFactorChanged -= TextScaleChanged;
    }

    private void TextScaleChanged(Windows.UI.ViewManagement.UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() => Reflow(ActualWidth));

    private void Reflow(double width)
    {
        var narrowestShare = _weights.Count == 0 ? 1 : _weights.Min() / _weights.Sum();
        var columns = (width - _spacing * (Children.Count - 1)) * narrowestShare
            >= _minimumColumnWidth * Ui.LayoutTextScale;
        if (_columns == columns) return;
        _columns = columns;
        ColumnDefinitions.Clear();
        RowDefinitions.Clear();
        ColumnSpacing = columns ? _spacing : 0;
        RowSpacing = columns ? 0 : _spacing;
        if (!columns) ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var index = 0; index < Children.Count; index++)
        {
            if (columns) ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(_weights[index], GridUnitType.Star) });
            else RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            SetColumn((FrameworkElement)Children[index], columns ? index : 0);
            SetRow((FrameworkElement)Children[index], columns ? 0 : index);
        }
    }
}
