using System.Runtime.InteropServices;
using WinPaste.Core.OCR;

namespace WinPaste.App.Services;

/// <summary>
/// Windows 系统原生 ISpellChecker COM 英文拼写校验器，失败或缺失语言包时自动回退 Built-in 词典引擎
/// </summary>
public sealed class WindowsEnglishSpellChecker : IEnglishSpellChecker
{
    private readonly EnglishSpellChecker _fallback = new();
    private readonly ISpellChecker? _comChecker;

    [ComImport]
    [Guid("7AB36653-1796-484B-BDFA-E74F1DB7C1DC")]
    private class SpellCheckerFactoryCom { }

    [ComImport]
    [Guid("8E018A9D-2415-4677-BF08-794EA61F94BB")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellCheckerFactory
    {
        int get_SupportedLanguages([MarshalAs(UnmanagedType.IUnknown)] out object value);
        int IsSupported([MarshalAs(UnmanagedType.LPWStr)] string languageTag, [MarshalAs(UnmanagedType.Bool)] out bool value);
        int CreateSpellChecker([MarshalAs(UnmanagedType.LPWStr)] string languageTag, out ISpellChecker value);
    }

    [ComImport]
    [Guid("B6FD0B71-E2BC-4653-8D05-F197E412770B")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISpellChecker
    {
        int get_LanguageTag([MarshalAs(UnmanagedType.LPWStr)] out string value);
        int Check([MarshalAs(UnmanagedType.LPWStr)] string text, out IEnumSpellingError value);
    }

    [ComImport]
    [Guid("803E3BD4-2828-4410-8290-418D1D73C762")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IEnumSpellingError
    {
        [PreserveSig]
        int Next(out nint value);
    }

    public WindowsEnglishSpellChecker()
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var factory = (ISpellCheckerFactory)new SpellCheckerFactoryCom();
                if (factory.IsSupported("en-US", out bool supported) == 0 && supported)
                {
                    if (factory.CreateSpellChecker("en-US", out var checker) == 0)
                        _comChecker = checker;
                }
            }
        }
        catch
        {
            _comChecker = null;
        }
    }

    public bool IsValidEnglishWord(string word)
    {
        if (string.IsNullOrWhiteSpace(word) || word.Length < 3)
            return false;

        if (_fallback.IsValidEnglishWord(word))
            return true;

        if (_comChecker != null)
        {
            try
            {
                if (_comChecker.Check(word, out var enumErr) == 0 && enumErr != null)
                {
                    int hr = enumErr.Next(out nint errPtr);
                    if (errPtr != nint.Zero)
                        Marshal.Release(errPtr);
                    Marshal.ReleaseComObject(enumErr);
                    // S_FALSE (1) means zero spelling errors
                    if (hr == 1)
                        return true;
                    if (hr == 0)
                        return false;
                }
            }
            catch
            {
                // Fall back safely
            }
        }

        return false;
    }
}
