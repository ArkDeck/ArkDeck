using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace ArkDeck.Spk4.Pages;

/// <summary>Load timing of a large virtualised surface: fixture generation, and bind until the
/// first frame that shows realised rows.</summary>
public sealed record LoadTiming(int Items, double GenerateMs, double BindToFirstFrameMs);

/// <summary>A page whose data load the benchmark can await and whose list it can scroll.</summary>
public interface IMeasuredPage
{
    Task<LoadTiming> Ready { get; }

    /// <summary>The ScrollViewer that virtualises the rows.</summary>
    ScrollViewer? FindScroller();
}

internal sealed class LoadClock
{
    private readonly Stopwatch _sw = Stopwatch.StartNew();
    private readonly TaskCompletionSource<LoadTiming> _tcs = new();
    private double _generateMs;
    private int _items;
    private Func<bool>? _hasRows;

    public Task<LoadTiming> Ready => _tcs.Task;

    /// <summary>Marks the end of fixture generation and starts the bind clock.</summary>
    public void Generated(int items)
    {
        _items = items;
        _generateMs = _sw.Elapsed.TotalMilliseconds;
        _sw.Restart();
    }

    /// <summary>Completes on the first frame at which <paramref name="hasRows"/> is true.</summary>
    public void CompleteWhen(Func<bool> hasRows)
    {
        _hasRows = hasRows;
        CompositionTarget.Rendering += OnRendering;
    }

    private void OnRendering(object? sender, object e)
    {
        if (_hasRows is null || !_hasRows()) return;
        CompositionTarget.Rendering -= OnRendering;
        _tcs.TrySetResult(new LoadTiming(_items, _generateMs, _sw.Elapsed.TotalMilliseconds));
    }

    public static bool HasRealisedRows(DependencyObject? root) =>
        root is not null && FindDescendant<ListViewBase>(root) is { ItemsPanelRoot: { } panel } && panel.Children.Count > 0;

    public static T? FindDescendant<T>(DependencyObject root) where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T hit) return hit;
            if (FindDescendant<T>(child) is { } deeper) return deeper;
        }
        return null;
    }
}
