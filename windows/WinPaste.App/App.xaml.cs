using System.Threading;
using System.Windows;
using WinPaste.App.Services;
using WinPaste.App.Windows;
using WinPaste.Core.Models;
using WinPaste.Core.OCR;
using WinPaste.Core.Storage;
using WinPaste.Core.Translation;

namespace WinPaste.App;

public partial class App : Application
{
    private Mutex? _singleInstanceMutex;
    private AppSettingsStore? _settings;
    private HistoryStore? _historyStore;
    private ClipboardMonitor? _clipboardMonitor;
    private ExternalAppTracker? _appTracker;
    private CtrlVMonitor? _ctrlVMonitor;
    private HotKeyManager? _hotKeyManager;
    private RapidOcrEngine? _ocrEngine;
    private PreviewController? _previewController;
    private PinWindowManager? _pinManager;
    private ScreenshotManager? _screenshotManager;
    private ScrollCaptureManager? _scrollCaptureManager;
    private ClipboardViewModel? _viewModel;
    private MainWindow? _mainWindow;
    private SettingsWindow? _settingsWindow;
    private TrayController? _trayController;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(true, "WinPaste_SingleInstance_Mutex", out bool createdNew);
        if (!createdNew)
        {
            Shutdown();
            return;
        }

        _settings = new AppSettingsStore();
        _historyStore = new HistoryStore(AppPaths.Default, () => _settings.HistoryLimit);
        var ingestor = new ClipboardIngestor(_historyStore, AppPaths.Default);

        _clipboardMonitor = new ClipboardMonitor(ingestor);
        _clipboardMonitor.Start();

        _appTracker = new ExternalAppTracker();
        var injector = new PasteInjector();

        _ctrlVMonitor = new CtrlVMonitor(injector, _appTracker);
        _viewModel = new ClipboardViewModel(_historyStore, _settings, _clipboardMonitor, injector, _appTracker);

        _ocrEngine = new RapidOcrEngine();
        var spellChecker = new WindowsEnglishSpellChecker();
        var translator = TranslationService.Shared;

        _pinManager = new PinWindowManager(
            _clipboardMonitor,
            _historyStore,
            _viewModel,
            _ocrEngine,
            spellChecker,
            translator,
            _settings);

        _scrollCaptureManager = new ScrollCaptureManager(_clipboardMonitor, _historyStore);
        _scrollCaptureManager.PinBitmapRequested += (bmp, rect) => _pinManager.PinImage(bmp, rect);

        _screenshotManager = new ScreenshotManager(
            _clipboardMonitor,
            _historyStore,
            _settings,
            _ocrEngine,
            spellChecker,
            translator);
        _screenshotManager.PinBitmapRequested += (bmp, rect) => _pinManager.PinImage(bmp, rect);
        _screenshotManager.StartScrollCaptureRequested += rect => _scrollCaptureManager.Start(rect);

        _previewController = new PreviewController(_viewModel, _settings);
        _mainWindow = new MainWindow(_viewModel, _settings, _previewController);

        _ctrlVMonitor.IsSearchBoxFocused = () => _mainWindow.IsVisible && _mainWindow.IsSearchBoxFocused;
        _ctrlVMonitor.OnUserCtrlV += inSelf => _viewModel.HandleUserCtrlV(inSelf);
        _ctrlVMonitor.Start();

        _viewModel.PinItemRequested += item => _pinManager.PinClipboardItem(item);
        _viewModel.PinCurrentRequested += () => _pinManager.PinCurrentClipboardOrLatest();
        _viewModel.QuickLookImageRequested += path =>
        {
            var ql = new QuickLookWindow(path, _clipboardMonitor, p => _pinManager.PinImageFile(p));
            ql.Show();
        };

        _mainWindow.SnipRequested += () => _screenshotManager.StartCapture();
        _mainWindow.SettingsRequested += OpenSettings;

        _hotKeyManager = new HotKeyManager();
        _hotKeyManager.OnToggleMain += () => _mainWindow.ToggleMainPanel();
        _hotKeyManager.OnSnip += () => _screenshotManager.StartCapture();
        _hotKeyManager.OnPin += HandleF3HotKey;
        _hotKeyManager.OnToggleAllPins += () => _pinManager.ToggleAllVisibility();
        _hotKeyManager.OnSequentialNext += () => _viewModel.PasteNextSequentialFromHotKey();
        _hotKeyManager.Start();

        _trayController = new TrayController();
        _trayController.ToggleMainRequested += () => _mainWindow.ToggleMainPanel();
        _trayController.SnipRequested += () => _screenshotManager.StartCapture();
        _trayController.PinCurrentRequested += HandleF3HotKey;
        _trayController.ToggleAllPinsRequested += () => _pinManager.ToggleAllVisibility();
        _trayController.CloseAllPinsRequested += () => _pinManager.CloseAll();
        _trayController.SettingsRequested += OpenSettings;
        _trayController.QuitRequested += QuitApplication;
    }

    private void HandleF3HotKey()
    {
        if (_scrollCaptureManager?.FinishAndPin() == true)
            return;
        if (_screenshotManager?.FinishAndPinIfCapturing() == true)
            return;
        _pinManager?.PinCurrentClipboardOrLatest();
    }

    private void OpenSettings()
    {
        if (_viewModel == null) return;
        if (_settingsWindow != null && _settingsWindow.IsVisible)
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_viewModel);
        _settingsWindow.QuitRequested += QuitApplication;
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void QuitApplication()
    {
        _trayController?.Dispose();
        _hotKeyManager?.Dispose();
        _ctrlVMonitor?.Dispose();
        _clipboardMonitor?.Dispose();
        _appTracker?.Dispose();
        _scrollCaptureManager?.Dispose();
        _pinManager?.CloseAll();
        _previewController?.Dispose();
        _mainWindow?.ForceClose();
        _viewModel?.Dispose();
        _ocrEngine?.Dispose();
        _historyStore?.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        Shutdown();
    }
}
