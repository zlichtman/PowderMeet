import SwiftUI

/// "Pick one from a list", floating over the map: no sheet;
/// the map dimmed behind; the list's glass rows scrolling, the search bar
/// under them, and at the foot the current choice in a bubble with × beside
/// it as a button of its own, like a back arrow; nothing under the status
/// bar or off the edges. A tap on the map, ×, or a pull down past the top
/// closes it.
struct FloatingPicker<Content: View>: View {
    let title: String
    var subtitle: String?
    /// An asset drawn in place of the title's letters (the PowderMeet theme's
    /// wordmark); the title is still what VoiceOver reads.
    var titleImage: String?
    /// The current choice drawn small (a swatch, an icon, the skis).
    var leading: AnyView?
    /// A second current choice, shown after a divider (the map list's line
    /// colouring beside its map style): two names, no marks, so both fit.
    var secondTitle: String?
    @Binding var query: String
    let prompt: String
    /// The list's sort button (`FloatingSortButton`), for a list long enough
    /// to want one. Without it the search bar still stops short, in line with
    /// the current choice under it.
    var sort: AnyView?
    /// False for a list short enough to see whole (map styles): no search
    /// bar, just the rows and the foot.
    var showsSearch = true
    let onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)

                VStack(spacing: GlassLayout.gap) {
                    ScrollView {
                        LazyVStack(spacing: GlassLayout.gap) { content }
                            .padding(.vertical, 8)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top
                    } action: { _, offset in
                        if offset < -80 { onClose() }
                    }
                    // Rows fade at the area's edges instead of being cut.
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 12)
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 12)
                        }
                    }

                    // The search bar ends where the current choice under it
                    // does, and the sort button sits above the close button.
                    if showsSearch {
                        HStack(spacing: GlassLayout.gap) {
                            BottomSearchBar(text: $query, prompt: prompt)
                            Group {
                                if let sort { sort } else { Color.clear }
                            }
                            .frame(width: GlassLayout.barHeight, height: GlassLayout.barHeight)
                        }
                    }
                    // Under the search: what is chosen now, and beside it, as a
                    // button of its own, the way out, both within a thumb's reach.
                    HStack(spacing: GlassLayout.gap) {
                        HStack(spacing: 12) {
                            if let leading { leading }
                            VStack(alignment: .leading, spacing: 1) {
                                if let titleImage {
                                    Image(titleImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 13)
                                        .foregroundStyle(HUDTheme.primaryText)
                                        .accessibilityLabel(title)
                                } else {
                                    Text(title)
                                        .textRole(.bodyEmph)
                                        .foregroundStyle(HUDTheme.primaryText)
                                        .lineLimit(1)
                                        .minimumScaleFactor(secondTitle == nil ? 1 : 0.8)
                                }
                                if let subtitle {
                                    Text(subtitle)
                                        .textRole(.caption)
                                        .foregroundStyle(HUDTheme.secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            .layoutPriority(1)
                            if secondTitle == nil { Spacer(minLength: 0) }
                            if let secondTitle {
                                Rectangle()
                                    .fill(HUDTheme.secondaryText.opacity(0.22))
                                    .frame(width: 1, height: 26)
                                    .accessibilityHidden(true)
                                Text(secondTitle)
                                    .textRole(.bodyEmph)
                                    .foregroundStyle(HUDTheme.primaryText)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, GlassLayout.cardPadding)
                        .frame(minHeight: GlassLayout.barHeight)
                        .glassEffect(HUDGlass.surface, in: Capsule())
                        .environment(\.isOnGlass, true)
                        .accessibilityElement(children: .combine)
                        CloseButton(action: onClose)
                            .frame(width: GlassLayout.barHeight, height: GlassLayout.barHeight)
                    }
                }
                // From a small gap under the status bar down to the bottom: the
                // list has the whole screen's height, and nothing runs under the
                // status bar or off the edges. A message shows over its top for
                // its few seconds.
                .padding(.top, GlassLayout.gap)
                .padding(.horizontal, GlassLayout.inset)
                .padding(.bottom, GlassLayout.gap)
            }
        }
        .accessibilityAction(.escape, onClose)
        .transition(.opacity)
    }
}

/// A small floating label between groups of a floating list.
struct FloatingLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .textRole(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(HUDTheme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(HUDGlass.surface, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The one search bar of a floating list, at its foot: a glass capsule with
/// the field, above the keyboard when it opens.
struct BottomSearchBar: View {
    @Binding var text: String
    let prompt: String
    /// Where the page asks for the keyboard ("+ Add friend").
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(HUDTheme.secondaryText)
                .accessibilityHidden(true)
            field
                .textRole(.body)
                .foregroundStyle(HUDTheme.primaryText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(HUDTheme.secondaryText)
                        .minimumInteractiveTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, GlassLayout.cardPadding)
        .frame(height: GlassLayout.barHeight)
        .glassEffect(HUDGlass.field, in: Capsule())
    }

    @ViewBuilder
    private var field: some View {
        let input = TextField("", text: $text, prompt: Text(prompt))
        if let focus {
            input.focused(focus)
        } else {
            input
        }
    }
}

/// The round button beside a floating list's search bar: a menu of the orders
/// the list can take, the current one ticked.
struct FloatingSortButton<Sort: Hashable>: View {
    @Binding var selection: Sort
    /// Each order with the words and mark the menu shows.
    let options: [(value: Sort, title: String, systemImage: String)]

    var body: some View {
        Menu {
            Picker("Sort by", selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option.value)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(HUDTheme.primaryText)
                .frame(width: GlassLayout.iconButton, height: GlassLayout.iconButton)
                .glassEffect(HUDGlass.control, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Sort")
        .accessibilityValue(options.first { $0.value == selection }?.title ?? "")
    }
}
