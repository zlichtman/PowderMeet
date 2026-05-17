//
//  OnboardingProfileStep.swift
//  PowderMeet
//
//  Combined first step: photo + skill preset + activity import. The
//  display name is captured at sign-up (or by the Apple credential) so
//  we don't ask twice. Real activity data calibrates the solver more
//  accurately than the preset chips, but the chips are the always-
//  available fallback.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct OnboardingProfileStep: View {
    @Environment(SupabaseManager.self) private var supabase
    @Environment(ActivityImportSession.self) private var importSession

    @Binding var avatarData: Data?
    @Binding var skillLevel: String

    @State private var avatarImage: Image?
    @State private var selectedItem: PhotosPickerItem?
    @State private var showSourceMenu = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var noCameraAlert = false

    @State private var showActivityPicker = false
    @State private var importPickerError: String?
    @State private var showCancelImportConfirm = false
    @State private var showImportedRunsViewer = false

    /// Onboarding ski-pick lives directly under the activity-import
    /// rows so a fresh user picks both their personal calibration
    /// inputs (skill + workouts) and their personal-presentation
    /// input (which ski their friend rows will render) in one pass.
    @State private var showSkiPicker = false
    @State private var preferredSki: SkiCatalogEntry?

    /// Camera hardware is only available on real devices, not the simulator.
    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                Spacer().frame(height: 12)

                Text("YOUR PROFILE")
                    .hudType(.title)
                    .foregroundColor(HUDTheme.primaryText)
                    .tracking(2)

                // ── Avatar ──
                Button { showSourceMenu = true } label: {
                    ZStack {
                        Circle()
                            .fill(HUDTheme.cardBackground)
                            .frame(width: 96, height: 96)
                            .overlay(
                                Circle()
                                    .stroke(HUDTheme.cardBorder, lineWidth: 1.5)
                            )

                        if let avatarImage {
                            avatarImage
                                .resizable()
                                .scaledToFill()
                                .frame(width: 96, height: 96)
                                .clipShape(Circle())
                        } else {
                            VStack(spacing: 4) {
                                Image(systemName: "person.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(HUDTheme.accent.opacity(0.5))
                                Text("ADD PHOTO")
                                    .hudType(.caption)
                                    .foregroundColor(HUDTheme.secondaryText)
                                    .tracking(1)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .confirmationDialog("ADD PROFILE PHOTO", isPresented: $showSourceMenu, titleVisibility: .visible) {
                    Button("Take Photo") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if cameraAvailable {
                                showCamera = true
                            } else {
                                noCameraAlert = true
                            }
                        }
                    }
                    Button("Choose from Library") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showPhotoPicker = true
                        }
                    }
                    Button("Choose File") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            showFileImporter = true
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }

                // ── Calibration ──
                // Single subheader covers everything that calibrates
                // the solver: the preset level bar plus the Apple
                // Health and file-import pulls. Apple Health sits
                // above the file picker because for most users Health
                // is the one-tap option (Apple Watch / Slopes /
                // Strava / Garmin already publish workouts there);
                // the file picker stays as the explicit-backup path.
                // Result feedback is delivered as an iOS system
                // notification — no inline banner.
                VStack(alignment: .leading, spacing: 8) {
                    Text("CALIBRATION")
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText.opacity(0.6))
                        .tracking(1.5)
                    SkillLevelPicker(
                        selection: skillLevel,
                        onSelect: { skillLevel = $0 }
                    )
                    // VIEW LOGS sits above the two import buttons so
                    // upload progress + cancel render on a dedicated
                    // surface — tapping HK can't appear to mutate the
                    // file row (or vice-versa).
                    ViewLogsRow(
                        onTap: { showImportedRunsViewer = true },
                        onCancel: { showCancelImportConfirm = true }
                    )
                    ConnectAppleHealthRow()
                    ImportActivityFileRow(
                        onTap: { showActivityPicker = true }
                    )
                    skiPickerRow
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 8)
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotosPicker(selection: $selectedItem, matching: .images) {
                Text("Select Photo")
            }
            .photosPickerStyle(.inline)
            .frame(maxHeight: .infinity)
            .presentationDetents([.medium, .large])
        }
        .onChange(of: selectedItem) { _, newItem in
            showPhotoPicker = false
            Task { await loadFromPicker(newItem) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPickerView { uiImage in
                processImage(uiImage)
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                loadFromFile(url)
            case .failure:
                break
            }
        }
        .fileImporter(
            isPresented: $showActivityPicker,
            allowedContentTypes: ActivityImportTypes.supported,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                importPickerError = nil
                let importer = ActivityImporter(supabase: supabase)
                importSession.start(urls: urls, importer: importer)
            case .failure(let error):
                withAnimation { importPickerError = error.localizedDescription }
            }
        }
        .alert("Camera Unavailable", isPresented: $noCameraAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Camera is not available on this device. Please choose from your library or import a file instead.")
        }
        .alert("Cancel upload?", isPresented: $showCancelImportConfirm) {
            Button("Keep Uploading", role: .cancel) {}
            Button("Cancel Upload", role: .destructive) { importSession.cancel() }
        } message: {
            Text("Files already processed will stay imported. Files still in the queue will be skipped.")
        }
        .fullScreenCover(isPresented: $showImportedRunsViewer) {
            ImportedRunsView()
        }
        .sheet(isPresented: $showSkiPicker) {
            SkiPickerSheet(currentSelectionId: supabase.currentUserProfile?.preferredSkiId)
                .presentationDetents([.large])
        }
        .task(id: supabase.currentUserProfile?.preferredSkiId) {
            await refreshPreferredSki()
        }
    }

    // MARK: - Ski picker row

    /// Mirrors the DISPLAY-section row in `AccountTabContent` so a user
    /// who scrolls back from the main app to onboarding sees the same
    /// affordance. Once they pick a ski here, the same SkiPickerSheet
    /// updates `profiles.preferred_ski_id`; the binding to
    /// `supabase.currentUserProfile?.preferredSkiId` re-renders the row
    /// label/subtitle on save.
    @ViewBuilder
    private var skiPickerRow: some View {
        Button { showSkiPicker = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "skis.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(HUDTheme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skiRowLabel)
                        .hudType(.label)
                        .foregroundColor(HUDTheme.accent)
                        .tracking(1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(skiRowSubtitle)
                        .hudType(.caption)
                        .foregroundColor(HUDTheme.secondaryText)
                        .tracking(0.5)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(HUDTheme.accent.opacity(0.5))
            }
            .padding(12)
            .background(HUDTheme.accent.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(HUDTheme.accent.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var skiRowLabel: String {
        if let display = preferredSki?.displayName {
            return display.uppercased()
        }
        return "MY SKIS"
    }

    private var skiRowSubtitle: String {
        if let category = preferredSki?.category {
            if let waist = preferredSki?.waistWidthMm {
                return "\(category.uppercased()) · \(waist)mm WAIST"
            }
            return category.uppercased()
        }
        return "TAP TO PICK YOUR SKI"
    }

    private func refreshPreferredSki() async {
        guard let id = supabase.currentUserProfile?.preferredSkiId else {
            preferredSki = nil
            return
        }
        do {
            let all = try await supabase.fetchSkisCatalog()
            preferredSki = all.first { $0.id == id }
        } catch {
            preferredSki = nil
        }
    }

    // MARK: - Image Processing

    private func loadFromPicker(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else { return }
        processImage(uiImage)
    }

    private func loadFromFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let uiImage = UIImage(data: data) else { return }
        processImage(uiImage)
    }

    private func processImage(_ uiImage: UIImage) {
        // STEP 1 — Normalize orientation.
        // EXIF-tagged photos (anything from Camera / Photos) have the pixel
        // data in sensor orientation with `imageOrientation` carrying the
        // rotation hint. Cropping via `cgImage?.cropping(to:)` operates in
        // pixel space and completely ignores the orientation tag, so a
        // portrait photo with `.right` orientation was being cropped as if
        // it were landscape — faces ended up off-center or missing.
        // Redrawing through `UIGraphicsImageRenderer` bakes the orientation
        // into the pixels and gives us `.up`-oriented data to crop.
        let normalized: UIImage
        if uiImage.imageOrientation == .up {
            normalized = uiImage
        } else {
            let renderer = UIGraphicsImageRenderer(size: uiImage.size)
            normalized = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
            }
        }

        // STEP 2 — Center-crop to square.
        let side = min(normalized.size.width, normalized.size.height)
        let cropOrigin = CGPoint(
            x: (normalized.size.width - side) / 2,
            y: (normalized.size.height - side) / 2
        )
        let cropRect = CGRect(origin: cropOrigin, size: CGSize(width: side, height: side))
        guard let cgCropped = normalized.cgImage?.cropping(to: cropRect) else { return }
        let cropped = UIImage(cgImage: cgCropped, scale: normalized.scale, orientation: .up)

        // STEP 3 — Resize to 512×512.
        let targetSize = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = resized.jpegData(compressionQuality: 0.7) else { return }

        avatarData = jpegData
        avatarImage = Image(uiImage: resized)
    }
}

// MARK: - Camera Picker (UIKit wrapper)

struct CameraPickerView: UIViewControllerRepresentable {
    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImagePicked: onImagePicked) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        init(onImagePicked: @escaping (UIImage) -> Void) { self.onImagePicked = onImagePicked }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            if let image { onImagePicked(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
