using System.Collections.Generic;
using System.Linq;
using System.Windows.Controls;

namespace PCMigration.Controls
{
    /// <summary>Grouped tick list used by "What to take" and "What to restore".</summary>
    public partial class SelectionList : UserControl
    {
        private List<GroupView> _views = new List<GroupView>();
        public SelectionList() { InitializeComponent(); }
        public void SetGroups(IEnumerable<SelectionGroup> groups, System.Func<SelectionGroup, object> footer = null)
        {
            _views = groups.Where(g => g.Items.Count > 0 || g.Key == "custom").Select(g => new GroupView(g, footer != null ? footer(g) : null)).ToList();
            Groups.ItemsSource = _views;
        }
        public IEnumerable<SelectionGroup> GroupsShown { get { return _views.Select(v => v.Group); } }
        public void Filter(string text)
        {
            var q = (text ?? "").Trim();
            foreach (var v in _views)
            {
                int shown = 0;
                foreach (var i in v.Group.Items)
                {
                    bool match = q.Length == 0 || (i.Name ?? "").IndexOf(q, System.StringComparison.OrdinalIgnoreCase) >= 0 || (i.Summary ?? "").IndexOf(q, System.StringComparison.OrdinalIgnoreCase) >= 0 || (i.Id ?? "").IndexOf(q, System.StringComparison.OrdinalIgnoreCase) >= 0;
                    i.IsVisible = match; if (match) shown++;
                }
                v.Group.IsVisible = shown > 0 || (q.Length == 0 && v.Group.Key == "custom");
            }
        }
        public void SetAll(bool on) { foreach (var v in _views) v.Group.IsChecked = on; }
    }
    /// <summary>A group plus the optional footer element shown under its rows (password boxes, an Add folder button).</summary>
    public class GroupView : Observable
    {
        public SelectionGroup Group { get; private set; }
        public object Footer { get; private set; }
        public GroupView(SelectionGroup g, object footer) { Group = g; Footer = footer; Group.PropertyChanged += (s, e) => Raise(e.PropertyName); }
        public string Title { get { return Group.Title; } }
        public string Subtitle { get { return Group.Subtitle ?? ""; } }
        public string Glyph { get { return Group.Glyph; } }
        public string Summary { get { return Group.Summary; } }
        public bool? IsChecked { get { return Group.IsChecked; } set { Group.IsChecked = value; } }
        public bool IsVisible { get { return Group.IsVisible; } }
        public bool HasItems { get { return Group.Items.Count > 0; } }
        public bool HasNoItems { get { return Group.Items.Count == 0; } }
        public System.Collections.ObjectModel.ObservableCollection<SelectionItem> Items { get { return Group.Items; } }
    }
}
