using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace ArkDeck.App.Controls;

/// <summary>
/// A list of rows that carry their own buttons, laid out as plain panels so Tab walks every
/// row's buttons in order (a ListView is one Tab stop and needs the arrow keys to reach the
/// next row; with local Tab navigation it traps focus at its last row, both found by the
/// keyboard walk), while a screen reader still finds a List of ListItems.
/// </summary>
public sealed partial class SemanticList : ContentControl
{
    private readonly StackPanel _rows = new() { Spacing = 8 };

    public SemanticList()
    {
        IsTabStop = false;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Content = _rows;
    }

    public UIElementCollection Rows => _rows.Children;

    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this, AutomationControlType.List);

    internal sealed partial class Peer(FrameworkElement owner, AutomationControlType type) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => type;

        protected override string GetClassNameCore() => type == AutomationControlType.List ? nameof(SemanticList) : nameof(SemanticRow);
    }
}

/// <summary>One row of a <see cref="SemanticList"/> (a ListItem to a screen reader, never a
/// Tab stop itself).</summary>
public sealed partial class SemanticRow : ContentControl
{
    public SemanticRow(UIElement content)
    {
        IsTabStop = false;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Content = content;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new SemanticList.Peer(this, AutomationControlType.ListItem);
}
