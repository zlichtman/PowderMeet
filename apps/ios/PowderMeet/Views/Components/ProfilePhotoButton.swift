import AppCore
import PhotosUI
import PowderMeetAPI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The signed-in user's photo with the controls to change it, for the profile
/// card, Account and onboarding's photo step: a tap offers Choose Photo, Choose File (an image from Files), Take
/// Photo (on a device with a camera) and Remove Photo. A picked or taken photo opens the square crop; USE PHOTO hands
/// it to `AppModel.saveProfilePhoto`, which resizes it to 512 px, strips its
/// metadata and uploads it. Draws nothing while signed out. A failed upload
/// says why in the app's message row and leaves the old photo (or the initials).
struct ProfilePhotoButton: View {
    @Environment(AppModel.self) private var model

    var size: CGFloat = 80
    /// The small camera mark on the photo's corner. Off on the profile,
    /// where the photo is still a button but carries nothing on it.
    var showsBadge = true

    @State private var showsMenu = false
    @State private var showsLibrary = false
    @State private var showsFiles = false
    @State private var picked: PhotosPickerItem?
    @State private var isLoadingPick = false
    @State private var step: PhotoStep?

    init(size: CGFloat = 80, showsBadge: Bool = true) {
        self.size = size
        self.showsBadge = showsBadge
    }

    var body: some View {
        if let profile = model.photoOwner {
            Button { showsMenu = true } label: {
                AvatarView(userID: profile.id, path: profile.avatarURL, name: profile.displayName, size: size)
                    .overlay {
                        if model.photo.isSaving || isLoadingPick {
                            Circle()
                                .fill(Color.black.opacity(0.45))
                                .overlay(ProgressView().tint(.white))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if showsBadge {
                        Image(systemName: "camera.fill")
                            .font(.system(size: max(9, size * 0.13), weight: .bold))
                            .foregroundColor(HUDTheme.onAccent)
                            .frame(width: max(20, size * 0.3), height: max(20, size * 0.3))
                            .background(HUDTheme.accent, in: Circle())
                            .overlay(Circle().stroke(HUDTheme.mapBackground, lineWidth: 2))
                        }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(model.photo.isSaving)
            .accessibilityLabel(profile.avatarURL == nil ? "Add a profile photo" : "Change your profile photo")
            .confirmationDialog("Profile photo", isPresented: $showsMenu, titleVisibility: .hidden) {
                Button("Choose Photo") { showsLibrary = true }
                Button("Choose File") { showsFiles = true }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") {
                        step = .camera
                    }
                }
                if profile.avatarURL != nil {
                    Button("Remove Photo", role: .destructive) { model.removeProfilePhoto() }
                }
            }
            // The system picker runs outside the app: no photo library permission.
            .photosPicker(isPresented: $showsLibrary, selection: $picked, matching: .images)
            // Files runs outside the app too; the picked file is read once.
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { loadFile(url) }
            }
            .onChange(of: picked) { _, item in
                guard let item else { return }
                picked = nil
                load(item)
            }
            // Presented by the step itself, so the cover can never come up
            // before the photo it shows (a flag and a value set together can
            // reach the cover in either order and leave it blank).
            .fullScreenCover(item: $step) { step in
                flow(step)
            }
            #if DEBUG
            .task {
                // `-previewData YES -previewCrop YES`: the crop screen over a drawn picture.
                guard DebugLaunch.previewCrop, step == nil else { return }
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 600)).image { context in
                    UIColor.systemTeal.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 900, height: 600))
                    UIColor.white.setFill()
                    context.cgContext.fillEllipse(in: CGRect(x: 330, y: 180, width: 240, height: 240))
                }
                if let data = picture.jpegData(compressionQuality: 0.9) {
                    step = .crop(data)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func flow(_ shown: PhotoStep) -> some View {
        switch shown {
        case .camera:
            CameraPicker { data in
                step = data.map(PhotoStep.crop)
            }
            .ignoresSafeArea()
        case .crop(let data):
            AvatarCropSheet(
                data: data,
                onCancel: { step = nil },
                onUse: { crop in
                    model.saveProfilePhoto(from: data, crop: crop)
                    step = nil
                }
            )
        }
    }

    /// An image file from Files: its bytes, read inside the file's security scope.
    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            step = .crop(data)
        } catch {
            model.photoFailed(.social(.photoUnreadable))
        }
    }

    /// The picked photo's bytes, in whatever format the library holds it.
    private func load(_ item: PhotosPickerItem) {
        isLoadingPick = true
        Task {
            defer { isLoadingPick = false }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    model.photoFailed(.social(.photoUnreadable))
                    return
                }
                step = .crop(data)
            } catch {
                model.photoFailed(.social(.photoUnreadable))
            }
        }
    }
}

private enum PhotoStep: Identifiable, Equatable {
    case camera
    case crop(Data)

    var id: String {
        switch self {
        case .camera: "camera"
        case .crop(let data): "crop-\(data.count)"
        }
    }
}

// MARK: Crop

/// The square crop: the photo fills a square, drag to move it and pinch to
/// zoom; the circle shows what friends will see. The crop is reported in the
/// pixels of `AvatarImageProcessor.workingImage`, which the save decodes again.
private struct AvatarCropSheet: View {
    let data: Data
    let onCancel: () -> Void
    let onUse: (CGRect) -> Void

    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxZoom: CGFloat = 4

    var body: some View {
        // Inside the safe area: the title bubble on top, the actions at the
        // foot within thumb reach, never under the status bar or the home bar.
        VStack(spacing: GlassLayout.sectionGap) {
            Text("Move and scale")
                .textRole(.bodyEmph)
                .foregroundStyle(HUDTheme.primaryText)
                .padding(.horizontal, GlassLayout.cardPadding)
                .frame(height: GlassLayout.chipHeight)
                .glassEffect(HUDGlass.surface, in: Capsule())

            GeometryReader { proxy in
                let side = max(0, min(proxy.size.width, proxy.size.height) - 32)
                ZStack {
                    if let image {
                        cropArea(image, side: side)
                    } else if failed {
                        Text(PowderMeetError.social(.photoUnreadable).userMessage)
                            .textRole(.label)
                            .foregroundStyle(HUDTheme.accentAmber)
                            .multilineTextAlignment(.center)
                            .glassCard()
                            .padding(32)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            HStack(spacing: GlassLayout.gap) {
                SecondaryButton(title: "Cancel", action: onCancel)
                PrimaryButton(title: "Use photo", isEnabled: image != nil) { use() }
            }
            .padding(.horizontal, GlassLayout.pageInset)
        }
        .padding(.vertical, GlassLayout.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            // Decoded once here for the screen; at most 2,048 px, so it is quick.
            if let decoded = AvatarImageProcessor.workingImage(from: data) {
                image = decoded
            } else {
                failed = true
            }
        }
    }

    private func cropArea(_ image: CGImage, side: CGFloat) -> some View {
        let base = baseScale(image, side: side)
        let width = CGFloat(image.width) * base * zoom
        let height = CGFloat(image.height) * base * zoom
        return ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: width, height: height)
                .offset(offset)
            // Everything outside the circle is dimmed; the square edge stays faint.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .mask(
                    Rectangle()
                        .overlay(Circle().frame(width: side, height: side).blendMode(.destinationOut))
                        .compositingGroup()
                )
                .allowsHitTesting(false)
            Rectangle()
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                .frame(width: side, height: side)
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = clamped(
                        CGSize(width: committedOffset.width + value.translation.width,
                               height: committedOffset.height + value.translation.height),
                        image: image, side: side, zoom: zoom)
                }
                .onEnded { _ in committedOffset = offset }
                .simultaneously(with:
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(committedZoom * value.magnification, 1), Self.maxZoom)
                            offset = clamped(offset, image: image, side: side, zoom: zoom)
                        }
                        .onEnded { _ in
                            committedZoom = zoom
                            committedOffset = offset
                        }
                )
        )
        .onChange(of: side, initial: true) { _, new in lastSide = new }
        .accessibilityLabel("Photo crop")
        .accessibilityHint("Use the actions to move, zoom or reset the photo")
        .accessibilityAction(named: "Zoom in") { setZoom(zoom * 1.25, image: image, side: side) }
        .accessibilityAction(named: "Zoom out") { setZoom(zoom / 1.25, image: image, side: side) }
        .accessibilityAction(named: "Move up") { nudge(CGSize(width: 0, height: -side / 8), image: image, side: side) }
        .accessibilityAction(named: "Move down") { nudge(CGSize(width: 0, height: side / 8), image: image, side: side) }
        .accessibilityAction(named: "Move left") { nudge(CGSize(width: -side / 8, height: 0), image: image, side: side) }
        .accessibilityAction(named: "Move right") { nudge(CGSize(width: side / 8, height: 0), image: image, side: side) }
        .accessibilityAction(named: "Reset") {
            zoom = 1
            committedZoom = 1
            offset = .zero
            committedOffset = .zero
        }
    }

    /// The crop's moves for VoiceOver, which has no drag or pinch.
    private func setZoom(_ value: CGFloat, image: CGImage, side: CGFloat) {
        zoom = min(max(value, 1), Self.maxZoom)
        committedZoom = zoom
        offset = clamped(offset, image: image, side: side, zoom: zoom)
        committedOffset = offset
    }

    private func nudge(_ by: CGSize, image: CGImage, side: CGFloat) {
        offset = clamped(
            CGSize(width: committedOffset.width + by.width, height: committedOffset.height + by.height),
            image: image, side: side, zoom: zoom)
        committedOffset = offset
    }

    @State private var lastSide: CGFloat = 0

    /// The scale at which the photo just fills the square.
    private func baseScale(_ image: CGImage, side: CGFloat) -> CGFloat {
        max(side / CGFloat(image.width), side / CGFloat(image.height))
    }

    /// Keeps the photo covering the whole square.
    private func clamped(_ proposed: CGSize, image: CGImage, side: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = baseScale(image, side: side) * zoom
        let maxX = max(0, (CGFloat(image.width) * scale - side) / 2)
        let maxY = max(0, (CGFloat(image.height) * scale - side) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX), height: min(max(proposed.height, -maxY), maxY))
    }

    /// The square on screen, in the working image's pixels (origin top left).
    private func use() {
        guard let image else { return }
        // Before the square has been measured: the centred square, unzoomed.
        guard lastSide > 0 else {
            let side = CGFloat(min(image.width, image.height))
            return onUse(CGRect(
                x: (CGFloat(image.width) - side) / 2, y: (CGFloat(image.height) - side) / 2, width: side, height: side))
        }
        let scale = baseScale(image, side: lastSide) * zoom
        let cropSide = lastSide / scale
        let centreX = CGFloat(image.width) / 2 - offset.width / scale
        let centreY = CGFloat(image.height) / 2 - offset.height / scale
        let x = min(max(centreX - cropSide / 2, 0), CGFloat(image.width) - cropSide)
        let y = min(max(centreY - cropSide / 2, 0), CGFloat(image.height) - cropSide)
        onUse(CGRect(x: x, y: y, width: cropSide, height: cropSide))
    }
}

// MARK: Camera

/// The system camera, still photos only. Shown only where
/// `UIImagePickerController.isSourceTypeAvailable(.camera)` (never in the
/// Simulator). Returns the photo as JPEG bytes, or nil when cancelled.
private struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        if UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void

        init(onFinish: @escaping (Data?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // The orientation travels in the JPEG; the crop applies it.
            let image = info[.originalImage] as? UIImage
            onFinish(image?.jpegData(compressionQuality: 0.95))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}
