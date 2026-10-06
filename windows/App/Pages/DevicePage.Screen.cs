using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Text;
using ArkDeck.App.Controls;
using ArkDeck.App.Core.Presentation;
using ArkDeck.App.Core.Strings;
using ArkDeck.ClientKit.Json;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Microsoft.Windows.Storage.Pickers;
using Windows.System;
using Windows.UI.Core;
using Path = System.IO.Path;

namespace ArkDeck.App.Pages;

public sealed partial class DevicePage
{
    private readonly DeviceScreenSession _screen = new();
    private StackPanel _screenContent = new() { Spacing = 8 };
    private TextBlock _screenStatus = Ui.Status("device.screen.status");
    private BitmapImage? _screenBitmap;
    private long _gateRead;
    private string? _screenRefusal;
    private readonly List<(string Text, string? JobId)> _screenLog = [];
    private int _recordFrameCount = 20;
    private DeviceRecording? _recording;
    private DeviceMovie? _movie;
    private string? _recordStage;
    private DevicePoint? _press;
    private long _pressGeneration;
    private long _pressTime;
    private double _travel;
    private DevicePoint? _marker;
    private DeviceInputVerdict? _markerVerdict;
    private DevicePoint? _keyboardPoint;
    private (int X, int Y)? _swipeStart;

    private Border ScreenWorkspace()
    {
        var text = _screenStatus.Text;
        _screenStatus = Ui.Status("device.screen.status");
        Ui.SetText(_screenStatus, text);
        _screenContent = new StackPanel { Spacing = 8 };
        RenderScreen();
        return Ui.Card(_screenContent, "device.screen.workspace");
    }

    private async Task RefreshScreenGateAsync(string? selected)
    {
        var read = ++_gateRead;
        var gate = await Task.Run(() => App.Loader.DeviceScreenGateAsync(selected));
        if (read != _gateRead || _selected != selected || _history is not null) return;
        MainWindow.Instance.Report(gate);
        var before = _screen.Generation;
        _screen.Select(gate.Target);
        _screenRefusal = gate.Refusal;
        if (_screen.Generation != before) { _screenBitmap = null; _keyboardPoint = null; _swipeStart = null; _marker = null; _recording = null; _movie = null; }
        RenderScreen();
    }

    private void RenderScreen()
    {
        _screenContent.Children.Clear();
        _screenContent.Children.Add(Ui.Heading("device.screen.title", S.Text(UiStrings.WindowsDeviceScreenScreenTitle)));
        _screenContent.Children.Add(Ui.Text("device.screen.boundary", S.Text(UiStrings.WindowsDeviceScreenBoundary), "ArkDeckCaptionStyle"));
        if (_screen.Busy)
            _screenContent.Children.Add(Ui.Row(Ui.Progress("device.screen.busy", _recordStage ?? S.Text(UiStrings.DeviceScreenCapturing)),
                Ui.Text("device.screen.stage", _recordStage ?? S.Text(UiStrings.DeviceScreenCapturing))));
        else
            _screenContent.Children.Add(Ui.Row(Ui.Button("device.screen.capture", S.Text(UiStrings.DeviceScreenCapture), async (_, _) => await CaptureScreenAsync(), accent: true),
                Ui.CopyCli("device.screen.cli", DeviceOperations.CaptureCli)));
        if (_screen.Frame is { } frame && _screenBitmap is not null)
        {
            _screenContent.Children.Add(Ui.Text("device.screen.liveness", S.Text(frame.Historical ? UiStrings.WindowsDeviceScreenHistorical
                : _screen.Current ? UiStrings.WindowsDeviceScreenCurrent : UiStrings.DeviceStaleBadge)));
            _screenContent.Children.Add(Picture(frame));
            _screenContent.Children.Add(Ui.Text("device.screen.frame", S.Format(UiStrings.WindowsDeviceScreenFrameSummary,
                frame.Width.ToString(CultureInfo.InvariantCulture), frame.Height.ToString(CultureInfo.InvariantCulture), frame.JobId, frame.ArtifactId), "ArkDeckCaptionStyle"));
            _screenContent.Children.Add(Ui.Fact("device.screen.age", S.Text(UiStrings.DeviceFrameAge), frame.CapturedAtUtc));
            _screenContent.Children.Add(Ui.Text("device.screen.pointer.help", S.Text(UiStrings.WindowsDeviceScreenPointerHelp), "ArkDeckCaptionStyle"));
        }
        else
        {
            _screenContent.Children.Add(Ui.Text("device.screen.empty", S.Text(UiStrings.DeviceFrameNone)));
            _screenContent.Children.Add(Ui.Text("device.screen.reason", _screenRefusal ?? S.Text(UiStrings.DeviceScreenEmptyReady), "ArkDeckCaptionStyle"));
        }
        _screenContent.Children.Add(_screenStatus);
        if (!_screen.Busy)
        {
            _screenContent.Children.Add(KeyboardControls());
            _screenContent.Children.Add(RecordingControls());
        }
        if (_screenLog.Count > 0)
        {
            _screenContent.Children.Add(Ui.Heading("device.screen.log.title", S.Text(UiStrings.DeviceLogTitle)));
            for (var i = 0; i < _screenLog.Count; i++)
            {
                var entry = _screenLog[i];
                _screenContent.Children.Add(entry.JobId is { } jobId
                    ? Ui.Row(Ui.Text("device.screen.log." + i, entry.Text + " · " + jobId, "ArkDeckCaptionStyle"),
                        Ui.Button("device.screen.log.open." + i, S.Text(UiStrings.JobInspectorActionOpenHistory), async (_, _) => await MainWindow.Instance.OpenJobAsync(jobId)))
                    : Ui.Text("device.screen.log." + i, entry.Text, "ArkDeckCaptionStyle"));
            }
        }
        if (!_screen.Busy && _screen.HistoryPending && _history is { } pending)
            DispatcherQueue.TryEnqueue(async () =>
            {
                if (_screen.HistoryPending && ReferenceEquals(_history, pending)) await ReadHistoryScreenAsync(pending);
            });
    }

    private bool CanSend()
    {
        if (_screen.Busy) { Ui.Say(_screenStatus, S.Text(UiStrings.WindowsDeviceScreenBusy)); return false; }
        if (!_screen.CanInput) { Ui.Say(_screenStatus, S.Text(UiStrings.DeviceStaleRefused) + " · " + S.Text(UiStrings.DeviceStaleRefusedDetail)); return false; }
        return true;
    }

    private async Task CaptureScreenAsync()
    {
        if (_screen.Busy) return;
        _history = null;
        _screen.ClearHistory();
        await RefreshScreenGateAsync(_selected);
        if (_history is not null) return;
        if (_screen.Begin() is not { } generation || _screen.Target is not { } target)
        { Ui.Say(_screenStatus, _screenRefusal ?? S.Text(UiStrings.DeviceTargetNoneDetail)); return; }
        _history = null;
        _marker = null;
        RenderScreen();
        try
        {
            var result = await Task.Run(() => App.Loader.CaptureDeviceScreenAsync(target));
            MainWindow.Instance.Report(result);
            var bitmap = result.Frame is { } frame ? Decode(frame) : null;
            if (_screen.Captured(generation, bitmap is null ? null : result.Frame))
            {
                _screenBitmap = bitmap;
                _keyboardPoint = new(result.Frame!.Width / 2.0, result.Frame.Height / 2.0);
                _swipeStart = null;
                Log(S.Text(UiStrings.DeviceLogCaptured), result.Frame.JobId);
                Ui.Say(_screenStatus, S.Text(UiStrings.DeviceLogCaptured));
            }
            else if (generation == _screen.Generation) Ui.Say(_screenStatus, result.Failure ?? S.Text(UiStrings.WindowsDeviceScreenDecodeFailed));
        }
        finally { _screen.End(); RenderScreen(); }
    }

    private async Task ReadHistoryScreenAsync(HistoryWorkspaceContext context)
    {
        if (_screen.BeginHistory() is not { } generation) return;
        RenderScreen();
        try
        {
            var result = await Task.Run(() => App.Loader.LoadDeviceHistoryAsync(context));
            MainWindow.Instance.Report(result);
            if (!ReferenceEquals(_history, context)) return;
            var bitmap = result.Frame is { } frame ? Decode(frame) : null;
            if (_screen.Captured(generation, bitmap is null ? null : result.Frame)) _screenBitmap = bitmap;
            Ui.Say(_screenStatus, result.Failure ?? (bitmap is null ? S.Text(UiStrings.WindowsDeviceScreenDecodeFailed) : S.Text(UiStrings.WindowsDeviceScreenHistorical)));
        }
        finally { _screen.End(); RenderScreen(); }
    }

    private static BitmapImage? Decode(DeviceScreenFrame frame)
    {
        try
        {
            var bitmap = new BitmapImage();
            using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
            { writer.WriteBytes(frame.Bytes); writer.StoreAsync().AsTask().GetAwaiter().GetResult(); writer.FlushAsync().AsTask().GetAwaiter().GetResult(); }
            stream.Seek(0);
            bitmap.SetSource(stream);
            return bitmap.PixelWidth == frame.Width && bitmap.PixelHeight == frame.Height ? bitmap : null;
        }
        catch (Exception error) when (error is ArgumentException or System.Runtime.InteropServices.COMException) { return null; }
    }

    private StackPanel Picture(DeviceScreenFrame frame)
    {
        var grid = new Grid { Height = 420, MinWidth = 120 };
        var image = new Image { Source = _screenBitmap, Stretch = Stretch.Uniform };
        AutomationProperties.SetAutomationId(image, "device.screen.picture");
        AutomationProperties.SetName(image, S.Text(UiStrings.DeviceScreenPicture));
        grid.Children.Add(image);
        var markers = new Canvas { IsHitTestVisible = false };
        grid.Children.Add(markers);
        var hit = new Border { Background = new SolidColorBrush(Colors.Transparent), IsTabStop = true };
        AutomationProperties.SetAutomationId(hit, "device.screen.pointer");
        AutomationProperties.SetName(hit, S.Text(UiStrings.DeviceScreenPicture));
        grid.Children.Add(hit);
        var position = Ui.Live(Ui.Text("device.screen.pointer.position", "", "ArkDeckCaptionStyle"), AutomationLiveSetting.Polite);
        DeviceViewport? Viewport() => DeviceViewport.Fit(grid.ActualWidth, grid.ActualHeight, frame.Width, frame.Height);
        void Draw()
        {
            markers.Children.Clear();
            if (Viewport() is not { } viewport) return;
            if ((_marker ?? _keyboardPoint) is not { } devicePoint) return;
            var point = new DevicePoint(viewport.X + devicePoint.X / frame.Width * viewport.Width, viewport.Y + devicePoint.Y / frame.Height * viewport.Height);
            var ellipse = new Ellipse { Width = 20, Height = 20, StrokeThickness = 3, Stroke = (Brush)Application.Current.Resources["ArkDeckInkBrush"],
                Fill = _markerVerdict is null ? new SolidColorBrush(Colors.Transparent)
                    : (Brush)Application.Current.Resources[_markerVerdict == DeviceInputVerdict.Confirmed ? "ArkDeckOkBrush" : _markerVerdict == DeviceInputVerdict.Failed ? "ArkDeckDangerBrush" : "ArkDeckWarnBrush"] };
            Canvas.SetLeft(ellipse, point.X - 10); Canvas.SetTop(ellipse, point.Y - 10); markers.Children.Add(ellipse);
        }
        grid.SizeChanged += (_, _) => Draw();
        hit.PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(hit).Properties.IsLeftButtonPressed || !CanSend() || Viewport() is not { } viewport) return;
            var p = e.GetCurrentPoint(hit).Position;
            var point = new DevicePoint(p.X, p.Y);
            if (!viewport.Contains(point) || !hit.CapturePointer(e.Pointer)) return;
            _press = point; _pressTime = Stopwatch.GetTimestamp(); _pressGeneration = _screen.Generation; _travel = 0;
            var mapped = viewport.Map(point);
            _marker = new(mapped.X, mapped.Y); _markerVerdict = null; Draw(); e.Handled = true;
        };
        hit.PointerMoved += (_, e) =>
        {
            if (_press is not { } start) return;
            var p = e.GetCurrentPoint(hit).Position;
            _travel = Math.Max(_travel, Math.Sqrt(Math.Pow(p.X - start.X, 2) + Math.Pow(p.Y - start.Y, 2)));
        };
        hit.PointerReleased += async (_, e) =>
        {
            if (_press is not { } start) return;
            var p = e.GetCurrentPoint(hit).Position;
            _press = null;
            hit.ReleasePointerCapture(e.Pointer);
            if (_pressGeneration != _screen.Generation || Viewport() is not { } viewport || !CanSend()) return;
            var end = new DevicePoint(p.X, p.Y);
            var travel = Math.Max(_travel, Math.Sqrt(Math.Pow(end.X - start.X, 2) + Math.Pow(end.Y - start.Y, 2)));
            if (DeviceGestureRequest.Classify(start, end, travel, Stopwatch.GetElapsedTime(_pressTime).TotalSeconds, viewport) is { } gesture)
                await SendGestureAsync(gesture);
            e.Handled = true;
        };
        hit.PointerCanceled += (_, _) => { _press = null; _marker = null; Draw(); };
        hit.PointerCaptureLost += (_, _) => { _press = null; };
        hit.KeyDown += async (_, e) =>
        {
            var shift = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
            var alt = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Menu) & CoreVirtualKeyStates.Down) != 0;
            var pointer = _keyboardPoint ?? new(frame.Width / 2.0, frame.Height / 2.0);
            var step = shift ? 20 : 5;
            if (e.Key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down)
            {
                _keyboardPoint = new(Math.Clamp(pointer.X + (e.Key == VirtualKey.Left ? -step : e.Key == VirtualKey.Right ? step : 0), 0, frame.Width - 1),
                    Math.Clamp(pointer.Y + (e.Key == VirtualKey.Up ? -step : e.Key == VirtualKey.Down ? step : 0), 0, frame.Height - 1));
                _marker = null; _markerVerdict = null; Draw();
                Ui.Say(position, S.Format(UiStrings.WindowsDeviceScreenPointerPosition, ((int)_keyboardPoint.X).ToString(CultureInfo.InvariantCulture), ((int)_keyboardPoint.Y).ToString(CultureInfo.InvariantCulture)));
                e.Handled = true;
            }
            else if (e.Key == VirtualKey.Escape) { _swipeStart = null; e.Handled = true; }
            else if (e.Key is VirtualKey.Enter or VirtualKey.Space)
            {
                e.Handled = true;
                if (e.KeyStatus.WasKeyDown || !CanSend()) return;
                var x = (int)pointer.X; var y = (int)pointer.Y;
                _marker = new(x, y); _markerVerdict = null;
                if (shift)
                {
                    if (_swipeStart is not { } from) { _swipeStart = (x, y); return; }
                    _swipeStart = null;
                    await SendGestureAsync(new(DeviceGesture.Swipe, from.X, from.Y, frame.Width, frame.Height, x, y, 500));
                }
                else await SendGestureAsync(new(alt ? DeviceGesture.LongPress : DeviceGesture.Tap, x, y, frame.Width, frame.Height, DurationMs: alt ? 500 : null));
            }
        };
        return Ui.Stack(4, grid, position);
    }

    private async Task SendGestureAsync(DeviceGestureRequest gesture)
    {
        if (!CanSend() || _screen.Begin(input: true) is not { } generation || _screen.Target is not { } target) return;
        RenderScreen();
        DeviceInputOutcome result;
        try { result = await Task.Run(() => App.Loader.SendDeviceGestureAsync(target, gesture)); }
        catch { result = new(DeviceInputVerdict.Unknown, null, "Invalid or lost input outcome"); }
        FinishInput(generation, result, S.Text(gesture.Gesture switch { DeviceGesture.Tap => UiStrings.DeviceGestureTap, DeviceGesture.LongPress => UiStrings.DeviceGestureLongPress, _ => UiStrings.DeviceGestureSwipe }));
    }

    private StackPanel KeyboardControls()
    {
        var keys = new ComboBox { Header = S.Text(UiStrings.DeviceInputKey), SelectedIndex = 0, MinWidth = 160 };
        AutomationProperties.SetAutomationId(keys, "device.keyboard.key");
        foreach (var key in DeviceKeyboardCommand.Keys) keys.Items.Add(new ComboBoxItem { Content = S.Text("device.input.key." + key), Tag = key });
        keys.SelectedIndex = 0;
        var text = new PasswordBox { Header = S.Text(UiStrings.DeviceInputText), MinWidth = 240, MaxWidth = 420 };
        AutomationProperties.SetAutomationId(text, "device.keyboard.text");
        var consent = new CheckBox { Content = S.Text(UiStrings.DeviceInputClipboardConsent) };
        AutomationProperties.SetAutomationId(consent, "device.keyboard.consent");
        return Ui.Stack(6, Ui.Heading("device.keyboard.title", S.Text(UiStrings.DeviceInputTitle)),
            Ui.Text("device.keyboard.help", S.Text(UiStrings.DeviceInputFocusHelp), "ArkDeckCaptionStyle"),
            Ui.Row(keys, Ui.Button("device.keyboard.sendKey", S.Text(UiStrings.DeviceInputSendKey), async (_, _) =>
            {
                if (keys.SelectedItem is ComboBoxItem { Tag: string key }) await SendKeyboardAsync(new(Key: key));
            })), text, consent,
            Ui.Button("device.keyboard.sendText", S.Text(UiStrings.DeviceInputSendText), async (_, _) =>
            {
                var command = new DeviceKeyboardCommand(Text: text.Password, ClipboardConsent: consent.IsChecked == true);
                text.Password = "";
                await SendKeyboardAsync(command);
            }), Ui.Text("device.keyboard.privacy", S.Text(UiStrings.DeviceInputPrivacyHelp), "ArkDeckCaptionStyle"));
    }

    private async Task SendKeyboardAsync(DeviceKeyboardCommand command)
    {
        if (!CanSend() || _screen.Begin(input: true) is not { } generation || _screen.Target is not { } target) return;
        RenderScreen();
        DeviceInputOutcome result;
        try { result = await Task.Run(() => App.Loader.SendDeviceKeyboardAsync(target, command)); }
        catch { result = new(DeviceInputVerdict.Unknown, null, "Invalid or lost keyboard outcome"); }
        FinishInput(generation, result, S.Text(UiStrings.DeviceInputTitle));
    }

    private void FinishInput(long generation, DeviceInputOutcome outcome, string operation)
    {
        MainWindow.Instance.Report(outcome);
        if (!_screen.Settled(generation, outcome.Verdict, failedMayHaveEffect: outcome.JobId is not null)) { RenderScreen(); return; }
        _markerVerdict = outcome.Verdict;
        var key = outcome.Verdict switch { DeviceInputVerdict.Confirmed => UiStrings.WindowsDeviceScreenInputConfirmed,
            DeviceInputVerdict.Unknown => UiStrings.WindowsDeviceScreenInputUnknown, _ => UiStrings.WindowsDeviceScreenInputFailed };
        Ui.Say(_screenStatus, S.Text(key) + (outcome.JobId is null ? "" : " · " + outcome.JobId));
        Log(operation + " · " + S.Text(outcome.Verdict switch { DeviceInputVerdict.Confirmed => UiStrings.DeviceLogConfirmed,
            DeviceInputVerdict.Unknown => UiStrings.DeviceLogUnknown, _ => UiStrings.DeviceLogFailed }), outcome.JobId);
        RenderScreen();
    }
    private void Log(string text, string? jobId)
    {
        _screenLog.Insert(0, (text, jobId));
        if (_screenLog.Count > 40) _screenLog.RemoveAt(40);
    }

    private StackPanel RecordingControls()
    {
        var count = new NumberBox { Header = S.Text(UiStrings.DeviceRecordFrames), Minimum = 2, Maximum = 300, Value = _recordFrameCount,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact, SmallChange = 1, Width = 180 };
        AutomationProperties.SetAutomationId(count, "device.record.frames");
        count.ValueChanged += (_, e) => { if (double.IsFinite(e.NewValue) && e.NewValue == Math.Truncate(e.NewValue) && e.NewValue is >= 2 and <= 300) _recordFrameCount = (int)e.NewValue; };
        var panel = Ui.Stack(6, Ui.Heading("device.record.title", S.Text(UiStrings.DeviceRecordTitle)),
            Ui.Row(count, Ui.Button("device.record.start", S.Text(UiStrings.DeviceRecordStart), async (_, _) =>
            {
                if (!double.IsFinite(count.Value) || count.Value != Math.Truncate(count.Value) || count.Value is < 2 or > 300) return;
                await RecordScreenAsync((int)count.Value);
            })), Ui.Text("device.record.timeline", S.Text(UiStrings.DeviceRecordTimeline), "ArkDeckCaptionStyle"));
        if (_recording is { } recording)
        {
            panel.Children.Add(Ui.Text("device.record.summary", S.Format(UiStrings.WindowsDeviceScreenRecordSummary,
                recording.Frames.Count.ToString(CultureInfo.InvariantCulture), recording.DurationSeconds.ToString("0.###", CultureInfo.InvariantCulture),
                recording.ObservedFramesPerSecond.ToString("0.###", CultureInfo.InvariantCulture), recording.MissingFrames.ToString(CultureInfo.InvariantCulture))));
            if (_movie is { } movie)
            {
                panel.Children.Add(Ui.Text("device.record.movie", S.Format(UiStrings.WindowsDeviceScreenMovieSummary, movie.ByteCount.ToString(CultureInfo.InvariantCulture),
                    movie.Width.ToString(CultureInfo.InvariantCulture), movie.Height.ToString(CultureInfo.InvariantCulture), movie.Sha256), "ArkDeckCaptionStyle"));
                panel.Children.Add(Ui.Row(Ui.Button("device.record.save", S.Text(UiStrings.DeviceRecordSaveAs), async (_, _) => await SaveRecordingAsync(frames: false)),
                    Ui.Button("device.record.reveal", S.Text(UiStrings.WindowsDeviceScreenMovieReveal), async (_, _) =>
                        await Launcher.LaunchFolderPathAsync(Path.GetDirectoryName(movie.Path)!))));
            }
            else panel.Children.Add(Ui.Text("device.record.nativeUnavailable", S.Text(UiStrings.WindowsDeviceScreenMovieUnavailable)));
            panel.Children.Add(Ui.Button("device.record.saveFrames", S.Text(UiStrings.WindowsDeviceScreenSaveFrames), async (_, _) => await SaveRecordingAsync(frames: true)));
            panel.Children.Add(Ui.Text("device.record.local", S.Text(UiStrings.WindowsDeviceScreenMovieLocal), "ArkDeckCaptionStyle"));
        }
        return panel;
    }

    private async Task RecordScreenAsync(int frameCount)
    {
        if (_screen.Busy) return;
        _history = null;
        _screen.ClearHistory();
        await RefreshScreenGateAsync(_selected);
        if (_history is not null) return;
        if (_screen.Target is not { } target) { Ui.Say(_screenStatus, _screenRefusal ?? S.Text(UiStrings.DeviceTargetNoneDetail)); return; }
        _screen.Invalidate(); _screenBitmap = null;
        if (_screen.Begin() is not { } generation) return;
        _history = null; _recordStage = S.Text(UiStrings.DeviceRecordPreflighting); RenderScreen();
        try
        {
            var storage = await Task.Run(() => App.Loader.DeviceRecordingStorageAsync(frameCount));
            if (_screen.Generation != generation) return;
            if (storage.Refusal is not null)
            {
                Ui.Say(_screenStatus, S.Text(UiStrings.DeviceRecordNoRoom) + $" · {storage.RequiredBytes} / {storage.RemainingBytes} · "
                    + S.Text(UiStrings.DeviceRecordWouldFit) + " " + storage.FramesThatFit); return;
            }
            if (!storage.Checked) Ui.Say(_screenStatus, S.Text(UiStrings.DeviceRecordHeadroomUnknown));
            _recordStage = S.Text(UiStrings.DeviceRecordCapturing); RenderScreen();
            var result = await Task.Run(() => App.Loader.RecordDeviceScreenAsync(target, frameCount));
            MainWindow.Instance.Report(result);
            if (_screen.Generation != generation) return;
            if (result.Recording is not { } recording) { Ui.Say(_screenStatus, S.Text(UiStrings.DeviceRecordFailed) + " · " + result.Failure); return; }
            _recording = recording; _movie = null;
            var composed = await DeviceMovieComposer.ComposeAsync(recording, App.Options.CacheRoot, stage =>
            {
                _recordStage = S.Text(stage == DeviceMovieStage.Composing ? UiStrings.DeviceRecordAssembling : UiStrings.DeviceRecordValidating); RenderScreen();
            });
            if (_screen.Generation != generation) return;
            _movie = composed.Movie;
            Ui.Say(_screenStatus, S.Text(_movie is null ? UiStrings.WindowsDeviceScreenMovieUnavailable : UiStrings.DeviceRecordReady));
            Log(S.Text(UiStrings.DeviceRecordReady), recording.JobId);
        }
        finally { _screen.End(); _recordStage = null; RenderScreen(); }
    }

    private async Task SaveRecordingAsync(bool frames)
    {
        var recording = _recording;
        var movie = _movie;
        if (recording is null || recording.Source is not { } sourceReceipt || (!frames && movie is null)) return;
        var confirm = Ui.Dialog(XamlRoot, "device.record.exportPreview", S.Text(UiStrings.HistoryArtifactsExportPreviewTitle),
            Ui.Text("device.record.exportPreview.message", S.Text(UiStrings.DeviceInputPrivacyHelp)),
            S.Text(UiStrings.HistoryArtifactsExportSensitive), S.Text(UiStrings.HistoryArtifactsExportCancel));
        if (await confirm.ShowAsync() != ContentDialogResult.Primary) return;
        var picker = new FileSavePicker(MainWindow.Instance.AppWindow.Id) { SuggestedFileName = frames ? "device-frames.zip" : "device-recording.mp4" };
        picker.FileTypeChoices.Add(frames ? ".zip" : ".mp4", [frames ? ".zip" : ".mp4"]);
        var picked = await picker.PickSaveFileAsync();
        if (picked is null || string.IsNullOrEmpty(picked.Path)) return;
        try
        {
            if (!frames)
            {
                await DeviceMovieExport.ExportAsync(movie!.Path, picked.Path, movie.ByteCount, movie.Sha256);
            }
            else
            {
                await using var output = new FileStream(picked.Path, FileMode.Create, FileAccess.Write, FileShare.None);
                using var archive = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);
                foreach (var frame in recording.Frames)
                {
                    await using var member = archive.CreateEntry(frame.Name, CompressionLevel.Fastest).Open();
                    await member.WriteAsync(frame.Bytes);
                }
                await using var timings = archive.CreateEntry("observed-timings.json", CompressionLevel.Fastest).Open();
                var document = new JsonObject([
                    new("schemaVersion", new JsonString("arkdeck.device.local-recording/1")), new("sourceJobId", new JsonString(recording.JobId)),
                    new("sourceArchiveArtifactId", new JsonString(sourceReceipt.ArchiveArtifactId)), new("sourceArchiveSha256", new JsonString(sourceReceipt.ArchiveSha256)),
                    new("sourceArchiveBytes", JsonNumber.FromInt64(sourceReceipt.ArchiveBytes)), new("sourceSequenceArtifactId", new JsonString(sourceReceipt.SequenceArtifactId)),
                    new("sourceSequenceSha256", new JsonString(sourceReceipt.SequenceSha256)), new("sourceSequenceBytes", JsonNumber.FromInt64(sourceReceipt.SequenceBytes)),
                    new("frames", new JsonArray(recording.Frames.Select(f => (JsonValue)new JsonObject([
                        new("name", new JsonString(f.Name)), new("durationSeconds", JsonNumber.FromDouble(f.DurationSeconds)),
                        new("byteCount", JsonNumber.FromInt64(f.Bytes.Length)), new("sha256", new JsonString(Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(f.Bytes))))])))),
                ]);
                await timings.WriteAsync(Encoding.UTF8.GetBytes(document.ToString()));
            }
            Ui.Say(_screenStatus, S.Format(UiStrings.WindowsDeviceScreenSaved, picked.Path));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Ui.Say(_screenStatus, S.Text(UiStrings.DeviceRecordSaveFailed)); }
    }
}
