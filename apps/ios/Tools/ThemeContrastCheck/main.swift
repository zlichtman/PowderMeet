// Checks every bundled theme's contrast: text tiers, accent and status
// colours against every surface, and a white label on the accent. It
// compiles the app's own theme model, so it checks what ships. Run from
// the repository root after changing AppTheme.swift or the theme data:
//
//   swiftc -O -o /tmp/pm-theme-check apps/ios/PowderMeet/Theme/AppTheme.swift \
//     apps/ios/PowderMeet/Theme/ThemeLibrary.swift apps/ios/Tools/ThemeContrastCheck/main.swift \
//     && /tmp/pm-theme-check apps/ios/PowderMeet/Resources/Themes
//
// Exits 1 if any theme fails.

import Foundation
let dir = CommandLine.arguments[1]
let lib = try ThemeLibrary.parse(
    ghostty: Data(contentsOf: URL(fileURLWithPath: dir + "/ghostty-themes.json")),
    packs: Data(contentsOf: URL(fileURLWithPath: dir + "/theme-packs.json")))
var all = AppTheme.powdermeet + AppTheme.editorial + AppTheme.editor
for f in [ThemeFamily.ghostty, .base16, .gogh] { all += lib[f] ?? []; print(f, lib[f]?.count ?? 0) }
print("built-in", AppTheme.powdermeet.count, AppTheme.editorial.count, AppTheme.editor.count)
var bad = 0
for t in all {
    let surfaces = [t.background, t.header, t.input, t.card]
    func low(_ c: ThemeRGB, _ min: Double) -> Bool { surfaces.contains { c.contrast(with: $0) < min - 0.01 } }
    var why: [String] = []
    if low(t.textPrimary, 7) { why.append("primary") }
    if low(t.textSecondary, 4.5) { why.append("secondary \(t.textSecondary.contrast(with: t.card))") }
    if low(t.textTertiary, 3) { why.append("tertiary") }
    if low(t.accent, 3) { why.append("accent \(t.accent.contrast(with: t.card))") }
    if ThemeRGB.white.contrast(with: t.accent) < 2.99 { why.append("white on accent \(ThemeRGB.white.contrast(with: t.accent))") }
    for s in [t.success, t.warning, t.danger, t.info] where low(s, 3) { why.append("status") }
    if !why.isEmpty { bad += 1; print("FAIL", t.id, why) }
}
print("checked", all.count, "failing", bad)
exit(bad == 0 ? 0 : 1)
