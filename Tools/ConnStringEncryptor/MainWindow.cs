using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using EMR.Shared.Security;

namespace ConnStringEncryptor;

public class MainWindow : Window
{
    private static readonly IBrush Ok   = new SolidColorBrush(Color.Parse("#107C41"));
    private static readonly IBrush Err  = new SolidColorBrush(Color.Parse("#C42B1C"));
    private static readonly IBrush Warn = new SolidColorBrush(Color.Parse("#9A6700"));
    private static readonly FontFamily Mono = new("Consolas, Menlo, Courier New, monospace");

    private readonly TextBox _server   = new() { Watermark = "e.g. 103.178.113.61,1232" };
    private readonly TextBox _database = new() { Watermark = "e.g. Dev_EMR" };
    private readonly TextBox _userId   = new() { Watermark = "e.g. sa" };
    private readonly TextBox _password = new() { PasswordChar = '•', Watermark = "SQL Server password" };
    private readonly TextBox _result   = new() { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, Height = 80, FontFamily = Mono, Watermark = "ENC:... appears here (or paste one to verify)" };
    private readonly TextBlock _decrypted = new() { TextWrapping = TextWrapping.Wrap, FontFamily = Mono, IsVisible = false };
    private readonly TextBlock _status    = new() { TextWrapping = TextWrapping.Wrap };

    public MainWindow()
    {
        Title = "EMR Connection String Encryptor";
        Width = 680;
        Height = 520;
        MinWidth = 560;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        Content = new ScrollViewer { Content = BuildLayout() };
    }

    private Control BuildLayout()
    {
        var showPwd = new Button { Content = "Show", Width = 64 };
        showPwd.Click += (_, _) =>
        {
            var hidden = _password.PasswordChar != '\0';
            _password.PasswordChar = hidden ? '\0' : '•';
            showPwd.Content = hidden ? "Hide" : "Show";
        };

        var encrypt = new Button { Content = "Encrypt →", Classes = { "accent" }, Padding = new Thickness(20, 6) };
        encrypt.Click += (_, _) => OnEncrypt();

        var decrypt = new Button { Content = "Decrypt / Verify" };
        decrypt.Click += (_, _) => OnDecrypt();

        var copy = new Button { Content = "Copy", VerticalAlignment = VerticalAlignment.Top };
        copy.Click += async (_, _) => await CopyToClipboard(_result.Text, "Copied to clipboard.");

        var fields = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("90,*,Auto"),
            RowDefinitions = new RowDefinitions("Auto,Auto,Auto,Auto")
        };
        AddField(fields, 0, "Server:", _server);
        AddField(fields, 1, "Database:", _database);
        AddField(fields, 2, "User ID:", _userId);
        AddField(fields, 3, "Password:", _password);
        showPwd.Margin = new Thickness(8, 4, 0, 4);
        Grid.SetRow(showPwd, 3); Grid.SetColumn(showPwd, 2);
        fields.Children.Add(showPwd);

        var resultRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        resultRow.Children.Add(_result);
        copy.Margin = new Thickness(8, 0, 0, 0);
        Grid.SetColumn(copy, 1);
        resultRow.Children.Add(copy);

        return new StackPanel
        {
            Margin = new Thickness(18, 14),
            Spacing = 10,
            Children =
            {
                new TextBlock { Text = "EMR API · Connection String Encryptor", FontSize = 17, FontWeight = FontWeight.SemiBold },
                new TextBlock { Text = "Encrypts the DefaultConnection value in appsettings.json (AES-256-GCM). No key setup is needed on the server.", Opacity = 0.65, TextWrapping = TextWrapping.Wrap },
                new Separator(),
                fields,
                new Separator(),
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { encrypt, decrypt } },
                new TextBlock { Text = "Result — paste into appsettings.json:", Opacity = 0.65 },
                resultRow,
                _status,
                _decrypted
            }
        };
    }

    private static void AddField(Grid grid, int row, string label, TextBox box)
    {
        var lbl = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right };
        box.Margin = new Thickness(8, 4, 0, 4);
        Grid.SetRow(lbl, row);
        Grid.SetRow(box, row); Grid.SetColumn(box, 1);
        if (row < 3) Grid.SetColumnSpan(box, 2);
        grid.Children.Add(lbl);
        grid.Children.Add(box);
    }

    private void OnEncrypt()
    {
        _decrypted.IsVisible = false;
        if (!TryBuildConnectionString(out var cs)) return;
        try
        {
            _result.Text = ConnectionStringCrypto.Encrypt(cs);
            SetStatus("Encrypted. Copy the value above into ConnectionStrings:DefaultConnection in appsettings.json.", Ok);
        }
        catch (Exception ex) { SetStatus($"Encryption failed: {ex.Message}", Err); }
    }

    private void OnDecrypt()
    {
        var value = _result.Text?.Trim();
        if (string.IsNullOrEmpty(value)) { SetStatus("Paste an ENC:... value into the result box to verify it.", Warn); return; }
        try
        {
            _decrypted.Text = ConnectionStringCrypto.Decrypt(value);
            _decrypted.IsVisible = true;
            SetStatus("Decryption OK. This is the connection string the API will use:", Ok);
        }
        catch (Exception ex)
        {
            _decrypted.IsVisible = false;
            SetStatus($"Decryption failed: the value is incomplete or was changed ({ex.Message})", Err);
        }
    }

    private async Task CopyToClipboard(string? text, string message)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        var clipboard = GetTopLevel(this)?.Clipboard;
        if (clipboard is null) { SetStatus("Clipboard unavailable; select the text and copy it manually.", Warn); return; }
        await clipboard.SetTextAsync(text.Trim());
        SetStatus(message, Ok);
    }

    private bool TryBuildConnectionString(out string cs)
    {
        cs = "";
        if (!Require(_server, "Server") || !Require(_database, "Database") ||
            !Require(_userId, "User ID") || !Require(_password, "Password")) return false;

        // SqlConnectionStringBuilder quotes values containing ; = or quotes (e.g. passwords)
        var b = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder
        {
            DataSource = _server.Text!.Trim(),
            InitialCatalog = _database.Text!.Trim(),
            UserID = _userId.Text!.Trim(),
            Password = _password.Text!,
            TrustServerCertificate = true,
            MultipleActiveResultSets = true
        };
        cs = b.ConnectionString;
        return true;
    }

    private bool Require(TextBox box, string name)
    {
        if (!string.IsNullOrWhiteSpace(box.Text)) return true;
        SetStatus($"{name} is required.", Err);
        box.Focus();
        return false;
    }

    private void SetStatus(string message, IBrush color)
    {
        _status.Text = message;
        _status.Foreground = color;
    }
}
