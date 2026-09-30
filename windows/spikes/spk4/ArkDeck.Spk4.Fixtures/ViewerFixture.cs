namespace ArkDeck.Spk4.Fixtures;

public sealed class ViewerNode(int id, int depth, string role, string label)
{
    public int Id { get; } = id;
    public int Depth { get; } = depth;
    public string Role { get; } = role;
    public string Label { get; } = label;
    public List<ViewerNode> Children { get; } = [];
    public string Display => $"{Role}  {Label}";
}

/// <summary>Deterministic Viewer UI-dump tree fixture (design §H.3/§I.2: 20k nodes).</summary>
public static class ViewerFixture
{
    public const int DefaultNodes = 20_000;

    static readonly string[] Roles =
    [
        "Column", "Row", "Stack", "Text", "Button", "Image", "List", "ListItem", "Scroll", "Toggle",
    ];

    /// <summary>Breadth-first build: each node gets 1..maxChildren children until
    /// <paramref name="count"/> nodes exist.</summary>
    public static ViewerNode Generate(int count = DefaultNodes, int seed = 20, int maxChildren = 4)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(count, 1);
        var rng = new Random(seed);
        var root = new ViewerNode(0, 0, "Root", "ohos.window");
        var queue = new Queue<ViewerNode>();
        queue.Enqueue(root);
        var next = 1;
        while (next < count && queue.Count > 0)
        {
            var parent = queue.Dequeue();
            var n = rng.Next(1, maxChildren + 1);
            for (var i = 0; i < n && next < count; i++)
            {
                var role = Roles[rng.Next(Roles.Length)];
                var child = new ViewerNode(next, parent.Depth + 1, role, $"#{next} {role.ToLowerInvariant()}");
                parent.Children.Add(child);
                queue.Enqueue(child);
                next++;
            }
        }
        return root;
    }

    public static int Count(ViewerNode root) => Flatten(root).Count;

    public static int MaxDepth(ViewerNode root) => Flatten(root).Max(n => n.Depth);

    /// <summary>Pre-order flattening (the order a fully expanded tree shows rows in).</summary>
    public static List<ViewerNode> Flatten(ViewerNode root)
    {
        var list = new List<ViewerNode>();
        var stack = new Stack<ViewerNode>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var n = stack.Pop();
            list.Add(n);
            for (var i = n.Children.Count - 1; i >= 0; i--) stack.Push(n.Children[i]);
        }
        return list;
    }
}
