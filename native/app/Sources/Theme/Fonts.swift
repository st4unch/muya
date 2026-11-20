// Registers the bundled IBM Plex Sans / JetBrains Mono (SIL OFL 1.1, Contents/Resources/Fonts) for this process only.
// CoreText registration is process-scoped (.process): nothing is installed system-wide and the user's font
// library is untouched. Call once at launch, before any ThemeFont lookup.
import AppKit
import CoreText

public enum ThemeFonts {
    /// Registers every .ttf/.otf in `directory`; returns the PostScript names that registered (and are now
    /// resolvable with NSFont(name:)).
    @discardableResult
    public static func register(directory: URL? = nil) -> [String] {
        let dir = directory ?? Bundle.main.resourceURL?.appendingPathComponent("Fonts")
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            var err: Unmanaged<CFError>?
            // Already registered (a second call, or a user-installed copy) is fine: the lookup below decides.
            _ = CTFontManagerRegisterFontsForURL(f as CFURL, .process, &err)
            if let ds = CTFontManagerCreateFontDescriptorsFromURL(f as CFURL) as? [CTFontDescriptor],
               let ps = ds.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }),
               NSFont(name: ps, size: 12) != nil { names.append(ps) }
        }
        return names
    }
}
