using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace PCMigration.Controls
{
    public enum Severity { Informational, Success, Warning, Error }

    /// <summary>WinUI-style InfoBar: an icon, a title, a message and an optional action button on a tinted strip.</summary>
    public partial class InfoBar : UserControl
    {
        public static readonly DependencyProperty TitleProperty = DependencyProperty.Register("Title", typeof(string), typeof(InfoBar), new PropertyMetadata("", (d, e) => ((InfoBar)d).Apply()));
        public static readonly DependencyProperty MessageProperty = DependencyProperty.Register("Message", typeof(string), typeof(InfoBar), new PropertyMetadata("", (d, e) => ((InfoBar)d).Apply()));
        public static readonly DependencyProperty SeverityProperty = DependencyProperty.Register("Severity", typeof(Severity), typeof(InfoBar), new PropertyMetadata(Severity.Informational, (d, e) => ((InfoBar)d).Apply()));
        public static readonly DependencyProperty ActionTextProperty = DependencyProperty.Register("ActionText", typeof(string), typeof(InfoBar), new PropertyMetadata("", (d, e) => ((InfoBar)d).Apply()));
        public static readonly DependencyProperty ExtraContentProperty = DependencyProperty.Register("ExtraContent", typeof(object), typeof(InfoBar), new PropertyMetadata(null, (d, e) => ((InfoBar)d).Apply()));
        public string Title { get { return (string)GetValue(TitleProperty); } set { SetValue(TitleProperty, value); } }
        public string Message { get { return (string)GetValue(MessageProperty); } set { SetValue(MessageProperty, value); } }
        public Severity Severity { get { return (Severity)GetValue(SeverityProperty); } set { SetValue(SeverityProperty, value); } }
        public string ActionText { get { return (string)GetValue(ActionTextProperty); } set { SetValue(ActionTextProperty, value); } }
        public object ExtraContent { get { return GetValue(ExtraContentProperty); } set { SetValue(ExtraContentProperty, value); } }
        public event EventHandler ActionClick;

        public InfoBar() { InitializeComponent(); Loaded += (s, e) => Apply(); Theme.Changed += Apply; }
        private void Apply()
        {
            if (TitleText == null) return;
            TitleText.Text = Title; TitleText.Visibility = string.IsNullOrEmpty(Title) ? Visibility.Collapsed : Visibility.Visible;
            MessageText.Text = Message; MessageText.Visibility = string.IsNullOrEmpty(Message) ? Visibility.Collapsed : Visibility.Visible;
            Extra.Visibility = ExtraContent == null ? Visibility.Collapsed : Visibility.Visible;
            ActionBtn.Content = ActionText; ActionBtn.Visibility = string.IsNullOrEmpty(ActionText) ? Visibility.Collapsed : Visibility.Visible;
            string bg, fg, glyph;
            switch (Severity)
            {
                case Severity.Success: bg = "StatusSuccessBg"; fg = "StatusSuccessFg"; glyph = ""; break;
                case Severity.Warning: bg = "StatusCautionBg"; fg = "StatusCautionFg"; glyph = ""; break;
                case Severity.Error: bg = "StatusCriticalBg"; fg = "StatusCriticalFg"; glyph = ""; break;
                default: bg = "StatusInfoBg"; fg = "AccentText"; glyph = ""; break;
            }
            Bd.Background = Theme.Brush(bg); Glyph.Foreground = Theme.Brush(fg); Glyph.Text = glyph;
        }
        private void ActionBtn_Click(object sender, RoutedEventArgs e) { var h = ActionClick; if (h != null) h(this, EventArgs.Empty); }
    }
}
