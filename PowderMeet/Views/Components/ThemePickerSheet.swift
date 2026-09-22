import SwiftUI
import UIKit

struct ThemePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var manager = ThemeManager.shared
    @State private var editingTheme: CustomAppTheme?
    @State private var editingSavedTheme: CustomAppTheme?

    var body: some View {
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("APP COLOR").hudType(.section).foregroundStyle(HUDTheme.textSecondary)
                            Spacer()
                            Text(manager.customTheme == nil && manager.activeTheme == .original
                                 ? "POWDERMEET" : manager.displayName.uppercased())
                                .hudType(.label).foregroundStyle(HUDTheme.accent)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        pillGrid
                        Text("Choose a color. Your Home Screen icon is separate.")
                            .hudType(.caption).foregroundStyle(HUDTheme.textSecondary)
                    }
                    .padding(14)
                    .powderControl(cornerRadius: 22, interactive: false)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("APP ICON").hudType(.section).foregroundStyle(HUDTheme.textSecondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                                 count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 16) {
                            ForEach(ThemeManager.coreIcons) { theme in iconCell(theme) }
                        }
                        if !ThemeManager.coreIcons.contains(manager.selectedIcon) {
                            Text("CURRENT ICON: \(manager.selectedIcon.label)")
                                .hudType(.caption).foregroundStyle(HUDTheme.textSecondary)
                        }
                    }
                    .padding(14)
                    .powderControl(cornerRadius: 22, interactive: false)
                }.padding(.horizontal, 16).padding(.vertical, 18)
            }
            .background(HUDTheme.mapBackground.ignoresSafeArea())
            .powderSheet(title: "Appearance")
            .sheet(item: $editingTheme) { CustomThemeEditor(draft: $0) }
            .sheet(item: $editingSavedTheme) { CustomThemeEditor(draft: $0) }
            .alert("Couldn't change icon", isPresented: Binding(
                get: { manager.iconError != nil }, set: { if !$0 { manager.iconError = nil } }
            )) { Button("OK") { manager.iconError = nil } } message: { Text(manager.iconError ?? "") }
        }.tint(HUDTheme.accent).preferredColorScheme(.dark)
            .background(SceneAppearanceObserver())
            .sensoryFeedback(.selection, trigger: manager.generation)
    }

    // MARK: - Color pills

    /// Curated colors share the same branded type and layout.
    /// Saved custom palettes follow the presets; the last pill creates one.
    private var pillGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 120 : 78), spacing: 10)],
                  alignment: .leading, spacing: 14) {
            ForEach(ThemeManager.appThemes) { theme in
                themePill(theme == .original ? "POWDERMEET" : theme.label,
                          accent: theme.accentColor, background: theme.backgroundColor,
                          selected: manager.selectedCustomID == nil && manager.activeTheme == theme) {
                    manager.selectTheme(theme)
                }
            }
            ForEach(manager.customThemes) { theme in
                themePill(theme.name.uppercased(), accent: Color(hex: theme.accentHex),
                          background: Color(hex: theme.backgroundHex),
                          selected: manager.selectedCustomID == theme.id, custom: theme) {
                    manager.selectCustom(theme)
                }
            }
            Button { editingTheme = CustomAppTheme() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 64, height: 34)
                        .background(AngularGradient(colors: [.pink, .orange, .yellow, .green, .blue, .purple, .pink],
                                                    center: .center), in: Capsule())
                    Text("CUSTOM").hudType(.label).foregroundStyle(HUDTheme.textSecondary)
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(ThemePressStyle()).accessibilityLabel("Create custom theme")
        }
    }

    private func themePill(_ title: String, accent: Color, background: Color, selected: Bool,
                           custom: CustomAppTheme? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    Rectangle().fill(accent)
                    Rectangle().fill(accent.opacity(0.55))
                    Rectangle().fill(background)
                }
                .frame(width: 64, height: 34)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? accent : HUDTheme.cardBorder, lineWidth: selected ? 2.5 : 1))
                .overlay(alignment: .center) {
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.6), radius: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if custom != nil {
                        Image(systemName: "pencil.circle.fill").font(.system(size: 12))
                            .foregroundStyle(.white, accent).offset(x: 4, y: -4)
                    }
                }
                Text(title).hudType(.label)
                    .foregroundStyle(selected ? HUDTheme.accent : HUDTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(ThemePressStyle())
        .accessibilityLabel("\(title.capitalized) app theme")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(custom == nil ? "" : "Touch and hold to edit")
        .onLongPressGesture(minimumDuration: 0.4) { if let custom { editingSavedTheme = custom } }
    }

    private func iconCell(_ theme: ThemeManager.Theme) -> some View {
        let selected = manager.selectedIcon == theme
        let source = UIImage(named: theme.previewImageName)
        let traits = UITraitCollection(userInterfaceStyle: theme == .original ? .dark : SystemAppearance.shared.colorScheme == .dark ? .dark : .light)
        let image = source?.imageAsset?.image(with: traits) ?? source
        return Button { manager.selectIcon(theme) } label: {
            VStack(spacing: 7) {
                Group {
                    if let image { Image(uiImage: image).resizable().aspectRatio(1, contentMode: .fit) }
                    else { Image(systemName: "mountain.2.fill").resizable().aspectRatio(1, contentMode: .fit) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? HUDTheme.accent : HUDTheme.cardBorder, lineWidth: selected ? 3 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, HUDTheme.accent) }
                }
                Text(theme == .original ? "PowderMeet" : theme.label.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? HUDTheme.accent : HUDTheme.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(manager.isChangingIcon)
            .accessibilityLabel("\(theme.label) app icon").accessibilityValue(selected ? "Selected" : "")
    }

}

private struct ThemePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .offset(y: !reduceMotion && configuration.isPressed ? 2 : 0)
            .shadow(color: configuration.isPressed ? .clear : .black.opacity(0.14), radius: 2, y: 2)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}

private struct CustomThemeEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: CustomAppTheme
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            Form {
                Section("Name") { TextField("Theme name", text: $draft.name) }
                if ThemeManager.shared.customThemes.contains(where: { $0.id == draft.id }) {
                    Section { Button("Delete Theme", role: .destructive) { confirmingDelete = true } }
                }
                Section("Colors") {
                    ColorPicker("Accent", selection: colorBinding(\.accentHex), supportsOpacity: false)
                    ColorPicker("Background", selection: colorBinding(\.backgroundHex), supportsOpacity: false)
                    ColorPicker("Cards", selection: colorBinding(\.surfaceHex), supportsOpacity: false)
                }
                Section("Preview") {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("PowderMeet", systemImage: "mountain.2.fill")
                            .font(.headline).foregroundStyle(Color(hex: draft.accentHex))
                        Text("Meet at the mountain base").foregroundStyle(.white)
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: draft.surfaceHex), in: RoundedRectangle(cornerRadius: 12))
                    }.padding().listRowInsets(EdgeInsets()).listRowBackground(Color(hex: draft.backgroundHex))
                }
                if !draft.hasReadableSurfaces {
                    Text("Choose darker background and card colors so light text stays readable.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HUDTheme.mapBackground)
            .safeAreaInset(edge: .bottom) {
                PrimaryButton(title: "CANCEL", kind: .quiet) { dismiss() }
                    .padding(16)
                    .background(HUDTheme.mapBackground)
            }
            .powderSheet(title: "Custom Theme", doneTitle: "Save",
                         doneDisabled: !draft.isValid || !draft.hasReadableSurfaces) {
                draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
                ThemeManager.shared.saveCustom(draft)
                dismiss()
            }
        }.preferredColorScheme(.dark)
            .confirmationDialog("Delete this custom theme?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete Theme", role: .destructive) {
                    ThemeManager.shared.deleteCustom(draft)
                    dismiss()
                }
            }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<CustomAppTheme, String>) -> Binding<Color> {
        Binding(get: { Color(hex: draft[keyPath: keyPath]) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            draft[keyPath: keyPath] = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        })
    }
}
