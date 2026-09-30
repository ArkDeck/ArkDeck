using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace ArkDeck.App.Controls;

/// <summary>
/// Lays its children out left to right and starts a new line when the next one does not fit,
/// so a row of actions or of a label and a value never runs past the page when the text is
/// large (Windows text size up to 225 %). Each child is measured against the panel's width,
/// so a long text wraps inside it instead of being clipped.
/// </summary>
public sealed partial class FlowPanel : Panel
{
    public double Spacing { get; set; } = 8;

    protected override Size MeasureOverride(Size availableSize)
    {
        var width = double.IsInfinity(availableSize.Width) ? double.PositiveInfinity : availableSize.Width;
        double x = 0, y = 0, line = 0, widest = 0;
        foreach (var child in Children)
        {
            child.Measure(new Size(width, double.PositiveInfinity));
            var size = child.DesiredSize;
            if (x > 0 && x + Spacing + size.Width > width)
            {
                y += line + Spacing / 2;
                x = 0;
                line = 0;
            }
            x += (x > 0 ? Spacing : 0) + size.Width;
            line = Math.Max(line, size.Height);
            widest = Math.Max(widest, x);
        }
        return new Size(double.IsInfinity(width) ? widest : Math.Min(widest, width), y + line);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double x = 0, y = 0, line = 0;
        foreach (var child in Children)
        {
            var size = child.DesiredSize;
            if (x > 0 && x + Spacing + size.Width > finalSize.Width)
            {
                y += line + Spacing / 2;
                x = 0;
                line = 0;
            }
            if (x > 0) x += Spacing;
            child.Arrange(new Rect(x, y, Math.Min(size.Width, finalSize.Width), size.Height));
            x += size.Width;
            line = Math.Max(line, size.Height);
        }
        return finalSize;
    }
}
