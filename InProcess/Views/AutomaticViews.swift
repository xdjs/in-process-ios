import SwiftUI
import PhotosUI

/// Two-step setup for publishing from an album: Photos access first, then the choice to upload automatically.
/// Nothing is created or enabled until the second step is finished.
struct AutomaticSetupView: View {
    let model: AppModel
    @Bindable var uploads: UploadCoordinator
    @Environment(\.scenePhase) private var scenePhase
    /// An existing "In Process" album that already holds photos. It is connected only with automatic uploading
    /// off, so its photos wait for approval: the app keeps no record of what was published before this setup.
    @State private var occupied: AlbumChoice?
    @State private var showDetails = false
    /// False on the Photos access step, true on the automatic-upload step.
    @State private var accessGranted = false
    /// The empty album to reuse, found on the access step; nil means create one.
    @State private var album: String?
    /// Off until the user opts in: with it off, nothing is uploaded without their approval.
    @State private var automatic = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Step \(accessGranted ? 2 : 1) of 2").themeSectionLabel().accessibilityIdentifier("setupStep")
                // Two-part progress line; the second part fills on the final step.
                HStack(spacing: 6) {
                    Capsule().fill(Theme.ink).frame(width: 28, height: 2)
                    Capsule().fill(accessGranted ? Theme.ink : Theme.line).frame(width: 28, height: 2)
                }.accessibilityHidden(true)
            }
            if accessGranted {
                VStack(alignment: .leading, spacing: 20) { uploadStep }.transition(.opacity.combined(with: .offset(x: 24)))
            } else {
                VStack(alignment: .leading, spacing: 20) { accessStep }.transition(.opacity.combined(with: .offset(x: -24)))
            }
            if uploads.busy { ProgressView("Creating your album…").accessibilityIdentifier("connectingAlbum") }
            else if uploads.preparingSetup { ProgressView("Checking Photos…").accessibilityIdentifier("loadingAlbums") }
        }
        .animation(.easeInOut(duration: 0.3), value: accessGranted)
        .task { DevelopmentLog.shared.emit(.setup, .setup); await refreshSetup() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { DevelopmentLog.shared.emit(.setup, .setup, [.stage: .tag(.settingsReturn)]); Task { await refreshSetup() } }
        }
    }
    /// Step 1: say why Photos access is needed and what will be created, then ask for it.
    @ViewBuilder private var accessStep: some View {
        DisplayTitle(lines: ["Allow access to", "your photos."])
        if uploads.error != nil {
            // Blocked: lead with the problem and its fix instead of repeating the introduction.
            setupError
            // A Photos access problem is fixed in Settings and rechecked on return, so it offers no retry here.
            if uploads.library.authorizationStatus == .full {
                Button("Try again") { Task { await requestAccess() } }
                    .buttonStyle(SecondaryButtonStyle()).disabled(working).accessibilityIdentifier("retrySetup")
            }
        } else {
            Text("In Process needs full access to your photo library so it can read the album you publish from and upload its photos in the background.")
                .accessibilityIdentifier("setupIntro")
            Text(occupied == nil
                 ? "We’ll create an album called In Process in Apple Photos. Only photos you put in that album are ever uploaded."
                 : "We’ll use your existing In Process album in Apple Photos. Only photos in that album are ever uploaded.")
                .foregroundStyle(Theme.secondaryText)
            Button("OK") { Task { await requestAccess() } }
                .buttonStyle(PrimaryButtonStyle()).disabled(working).accessibilityIdentifier("allowPhotos")
        }
    }
    /// Step 2: choose whether album photos upload unprompted, then finish. Finishing is what creates the album.
    @ViewBuilder private var uploadStep: some View {
        DisplayTitle(lines: ["Upload", "automatically?"])
        if let occupied {
            Label("Your In Process album already has \(occupied.count) \(occupied.count == 1 ? "photo" : "photos"). \(occupied.count == 1 ? "It" : "They") will wait for your approval, because the app can’t tell whether \(occupied.count == 1 ? "it was" : "they were") published before.", systemImage: "exclamationmark.triangle")
                .font(Theme.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.line.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .accessibilityIdentifier("existingPhotosWarning")
        }
        Toggle(isOn: $automatic) {
            Text("Automatic background uploading").font(Theme.headline)
        }
        .tint(Theme.ink).disabled(working || occupied != nil).accessibilityIdentifier("automaticUploads")
        .padding().frame(maxWidth: .infinity, alignment: .leading).themeCard()
        Text(occupied != nil
             ? "Off for now: nothing is uploaded until you approve it. You can turn this on from the home screen."
             : automatic
             ? "On: every photo you add to the In Process album is uploaded and published publicly, with no further step."
             : "Off: you can add photos to the In Process album, but nothing is uploaded until you approve it.")
            .foregroundStyle(Theme.secondaryText).contentTransition(.opacity).animation(.easeInOut(duration: 0.2), value: automatic)
            .accessibilityIdentifier("automaticUploadsNote")
        if occupied == nil { Text("You can change this later.").font(Theme.footnote).foregroundStyle(Theme.secondaryText) }
        if uploads.error != nil { setupError }
        Button(uploads.error == nil ? "Finish setup" : "Try again") { Task { await finish() } }
            .buttonStyle(PrimaryButtonStyle()).disabled(working).accessibilityIdentifier(uploads.error == nil ? "enableAutomatic" : "retrySetup")
        // Fine print stays one tap away so the screen reads as a single decision.
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showDetails.toggle() } } label: {
                HStack {
                    Text("Good to know").themeSectionLabel()
                    Spacer()
                    Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("setupDetails")
                .accessibilityLabel("Good to know").accessibilityValue(showDetails ? "Expanded" : "Collapsed")
            if showDetails {
                Text("Blank title and description · 1 USDC collect price · open edition. In Process covers uploading. Cellular uploads start on; you can change that later.")
                Text("Photos edits and embedded metadata, including location, are preserved. Photos decides when background uploads run. Your sign-in is shared securely with the upload extension; sign in again when it expires.")
            }
        }.themeNoteCard()
    }
    private var working: Bool { uploads.busy || uploads.preparingSetup }
    /// Reads Photos access and the existing albums without prompting; a permission prompt needs the OK button.
    /// Losing access while on step 2 (a change made in Settings) returns to step 1.
    private func refreshSetup() async {
        guard !working else { return }
        uploads.photosAccess = uploads.library.authorizationStatus
        if uploads.photosAccess == .notRequested { uploads.error = nil; occupied = nil; accessGranted = false; return }
        if accessGranted && uploads.photosAccess == .full { return } // Keep a step-2 error from finishing on screen.
        let (ready, found) = await loadAlbum()
        if ready { album = found } else { accessGranted = false }
    }
    /// Returns false when setup cannot continue. On success `album` is the existing album to reuse, or nil to
    /// create one. An empty album is preferred; a filled one sets `occupied`, which keeps automatic uploading off.
    private func loadAlbum() async -> (ready: Bool, album: String?) {
        guard await uploads.prepareSetup() else { occupied = nil; return (false, nil) }
        if let empty = uploads.choices.first(where: { $0.count == 0 }) { occupied = nil; return (true, empty.id) }
        occupied = uploads.choices.first
        if occupied != nil { automatic = false }
        return (true, occupied?.id)
    }
    /// Step 1's action: shows the system prompt if Photos access has not been decided, then moves on when it is full.
    private func requestAccess() async {
        guard !working else { return }
        let (ready, found) = await loadAlbum()
        guard ready else { return }
        album = found; accessGranted = true
    }
    /// The one consent action: creates or reuses the album and saves the configuration with the chosen mode.
    private func finish() async {
        guard !working else { return }
        guard model.isAuthenticated, let person = model.identity, let destination = model.destination,
              let session = model.session else { model.expireSessionIfNeeded(); return }
        let (ready, found) = await loadAlbum()
        guard ready else { accessGranted = false; return }
        album = found
        DevelopmentLog.shared.emit(.consent, .setup, [.consent: .flag(true), .automatic: .flag(automatic)])
        await uploads.configure(owner: person.artistAddress, destination: destination, albumID: album, session: session, autoUpload: automatic)
        if uploads.configured && uploads.error == nil { model.route = .home }
    }
    @ViewBuilder private var setupError: some View {
        if let error = uploads.error {
            Text(error).foregroundStyle(Theme.error).accessibilityIdentifier("setupError")
            if uploads.library.authorizationStatus != .full {
                Link("Open Photos access settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .accessibilityIdentifier("photosSettings")
            }
        }
    }
}
struct UploadStatusView: View {
    let model: AppModel
    @Bindable var uploads: UploadCoordinator
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var adding = false
    @State private var detail: LibraryPhoto?
    @State private var confirmRemoveAll = false
    @State private var confirmApproveAll = false
    @State private var startSingle = false
    @State private var confirmAutomatic = false
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if uploads.configured || uploads.state.blocker != nil { status } else { welcome }
        }
        // Runs each time this screen appears, so the album view is current without a manual check.
        .task { await uploads.refreshConfiguration(); if uploads.configured { await uploads.scan() } }
    }
    /// First screen after sign-in: say what the app does and lead with connecting an album.
    @ViewBuilder private var welcome: some View {
        DisplayTitle(lines: ["Publish as", "you work."]).accessibilityIdentifier("uploadStatus").padding(.top, 12).appear(0)
        // Two equal choices; neither is the default.
        HomeChoice(title: "Publish from an album", detail: "We’ll create an In Process album in Photos. You choose whether its photos upload automatically.", symbol: "rectangle.stack") { model.route = .setup }
            .accessibilityIdentifier("automaticSetup").appear(1)
        HomeChoice(title: "Upload a single photo", detail: "Choose one photo and publish it now.", symbol: "photo") { startSingle = true }
            .accessibilityIdentifier("manualEntry")
            .disabled(model.loadingPhoto)
            .modifier(SinglePhotoFlow(model: model, start: $startSingle)).appear(2)
        SinglePhotoLoading(model: model)
        if let error = uploads.error ?? uploads.state.lastWorkerError { Text(error).foregroundStyle(Theme.error) }
    }
    /// Connected: the automatic-upload switch, the add button, then the album itself. Settings live behind the gear.
    @ViewBuilder private var status: some View {
        problems
        if uploads.configured {
            summary
            // One switch, two modes. Off doubles as pause: nothing uploads without an approval.
            // Turning it on publishes everything waiting, so that is confirmed first.
            let waiting = uploads.albumPhotos.filter { uploads.itemState($0.id) == .unapproved }.count
            Toggle(isOn: Binding(get: { uploads.state.configuration?.uploadsAutomatically ?? true }, set: { on in
                if on && waiting > 0 { confirmAutomatic = true } else { Task { await uploads.setAutoUpload(on) } }
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatic uploading").font(Theme.headline)
                    Text(uploads.state.configuration?.uploadsAutomatically == false
                         ? "Off. Photos wait for your approval. Turning this on uploads everything waiting."
                         : "On. Every photo in the album is uploaded and published.")
                        .font(Theme.footnote).foregroundStyle(Theme.secondaryText).accessibilityIdentifier("automaticUploadsNote")
                }
            }
            .tint(Theme.ink).accessibilityIdentifier("automaticUploads")
            .padding().frame(maxWidth: .infinity, alignment: .leading).themeCard()
            .sensoryFeedback(.selection, trigger: uploads.state.configuration?.uploadsAutomatically)
            .confirmationDialog("Upload and publish \(waiting) \(waiting == 1 ? "photo" : "photos")?", isPresented: $confirmAutomatic, titleVisibility: .visible) {
                Button("Turn on and publish \(waiting) \(waiting == 1 ? "photo" : "photos")") { Task { await uploads.setAutoUpload(true) } }
                    .accessibilityIdentifier("confirmAutomatic")
            } message: {
                Text("Photos waiting in the album will be published publicly. Any that were published before this album was connected will be published again.")
            }
        }
        album
    }
    /// The album at a glance, set like the web app's Moments counter: how many are published, and what is still to come.
    @ViewBuilder private var summary: some View {
        let states = uploads.albumPhotos.map { uploads.itemState($0.id) }
        let uploaded = states.filter { $0 == .uploaded }.count, problems = states.filter { $0 == .problem }.count
        let unapproved = states.filter { $0 == .unapproved }.count, queued = states.count - uploaded - problems - unapproved
        if !states.isEmpty {
            let pending = [queued == 0 ? nil : "\(queued) queued", unapproved == 0 ? nil : "\(unapproved) waiting for approval",
                           problems == 0 ? nil : "\(problems) \(problems == 1 ? "needs" : "need") attention"].compactMap { $0 }
            HStack(alignment: .center, spacing: 10) {
                Text("\(uploaded)").font(Theme.stat).tracking(-0.8).contentTransition(.numericText(value: Double(uploaded)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uploaded").themeSectionLabel()
                    Text(pending.isEmpty ? "All caught up" : pending.joined(separator: " · "))
                        .font(Theme.note).foregroundStyle(problems > 0 ? Theme.error : (pending.isEmpty ? Theme.secondaryText : Theme.gold))
                }
                Spacer(minLength: 0)
            }
            .animation(.snappy(duration: 0.35), value: states)
            .sensoryFeedback(.success, trigger: uploaded) { old, new in new > old }
            // One element for VoiceOver and tests, worded as a sentence of counts.
            .accessibilityElement(children: .ignore).accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("\(uploaded) uploaded · \(queued) queued" + (unapproved == 0 ? "" : " · \(unapproved) waiting for approval") + (problems == 0 ? "" : " · \(problems) \(problems == 1 ? "needs" : "need") attention"))
            .accessibilityIdentifier("albumSummary")
        }
    }
    /// Shown only when something needs the user; a healthy album has no status line.
    @ViewBuilder private var problems: some View {
        if uploads.backgroundTransfersUnavailable && uploads.configured {
            Text("Running in the Simulator: background transfers need a physical iPhone, so photos upload only while the app is open.")
                .font(Theme.footnote).foregroundStyle(Theme.secondaryText).accessibilityIdentifier("simulatorNote")
        }
        // Photos needing attention are counted in the summary line, so that heading is not repeated here.
        if uploads.heading != "Active" && uploads.heading != "Needs attention" {
            Label(uploads.heading, systemImage: "exclamationmark.circle").font(Theme.headline).accessibilityIdentifier("overallStatus")
        }
        // Uploads are paused only after a problem (or by a developer tool); there is no pause switch, so offer the way back.
        if uploads.state.configuration?.paused == true {
            Text("Uploads were paused after a problem. Approved and automatic uploads wait until they are resumed.")
                .font(Theme.callout).foregroundStyle(Theme.secondaryText)
            Button("Resume uploads") { Task { await uploads.setPaused(false) } }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("resumeUploads")
        }
        if let blocker = uploads.state.blocker {
            Text(blocker).accessibilityIdentifier("uploadBlocker")
            Button("Reconnect album") { model.route = .setup }.accessibilityIdentifier("reconnectAlbum")
            Link("Photos access settings", destination: URL(string: UIApplication.openSettingsURLString)!)
        }
        if !uploads.configured {
            Button("Connect an album") { model.route = .setup }
                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("automaticSetup")
        }
        if let error = uploads.error ?? uploads.state.lastWorkerError { Text(error).foregroundStyle(Theme.error).accessibilityIdentifier("uploadError") }
    }
    /// Every still in the album, newest first, marked by whether it has been uploaded.
    @ViewBuilder private var album: some View {
        let photos = Array(uploads.albumPhotos.reversed())
        let states = photos.map { uploads.itemState($0.id) }
        let uploaded = states.filter { $0 == .uploaded }.count, problems = states.filter { $0 == .problem }.count
        let unapproved = states.filter { $0 == .unapproved }.count
        let waiting = zip(photos, states).filter { $0.1 == .unapproved }.map(\.0.id)
        // Same rule as each thumbnail's X: only waiting and failed photos can be taken out.
        let removable = zip(photos, states).filter { $0.1 != .uploading && uploads.removable($0.0.id) }.map(\.0.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("In Process album").themeSectionLabel().accessibilityIdentifier("uploadStatus")
                Spacer()
                if !waiting.isEmpty {
                    // Approval publishes publicly and cannot be recalled once an upload starts, so the batch is confirmed.
                    Button("Approve all") { confirmApproveAll = true }.buttonStyle(BracketButtonStyle()).accessibilityIdentifier("approveAll")
                        .confirmationDialog("Upload and publish \(waiting.count) \(waiting.count == 1 ? "photo" : "photos")?", isPresented: $confirmApproveAll, titleVisibility: .visible) {
                            Button("Publish \(waiting.count) \(waiting.count == 1 ? "photo" : "photos")") { Task { await uploads.approve(waiting) } }
                                .accessibilityIdentifier("confirmApproveAll")
                        } message: {
                            Text(waiting.count == 1 ? "It will be published publicly on In Process." : "They will be published publicly on In Process.")
                        }
                }
                if !removable.isEmpty {
                    Button("Remove all", role: .destructive) { confirmRemoveAll = true }.buttonStyle(BracketButtonStyle()).accessibilityIdentifier("removeAll")
                        .confirmationDialog("Remove \(removable.count) pending \(removable.count == 1 ? "photo" : "photos") from the In Process album?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
                            Button("Remove \(removable.count) \(removable.count == 1 ? "photo" : "photos")", role: .destructive) { Task { await uploads.removeFromAlbum(removable) } }
                                .accessibilityIdentifier("confirmRemoveAll")
                        } message: {
                            Text((removable.count == 1 ? "It stays in your library and won’t be published." : "They stay in your library and won’t be published.") + (uploaded == 0 ? "" : " Uploaded photos are not removed."))
                        }
                }
            }
        }
        // The empty-state button opens the same picker as the floating add button.
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images, photoLibrary: .shared())
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            add(items.compactMap(\.itemIdentifier))
        }
        if photos.isEmpty && uploads.configured {
            VStack(spacing: 12) {
                Image("Squiggle").resizable().scaledToFit().frame(width: 44, height: 44).foregroundStyle(Theme.ink).accessibilityHidden(true)
                Text("Your album is empty").font(Theme.display).tracking(-0.8)
                Text(uploads.state.configuration?.uploadsAutomatically == false ? "Add photos here or in Apple Photos. Nothing is uploaded until you approve it." : "Add photos here or in Apple Photos. Each one is published as soon as it’s added.")
                    .font(Theme.callout).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
                Button("Add photos") { add() }.buttonStyle(SecondaryButtonStyle()).disabled(adding).accessibilityIdentifier("addFirstPhotos")
            }
            .padding(.vertical, 36).padding(.horizontal).frame(maxWidth: .infinity).themeCard().appear(1) // No identifier on the card: it would replace the button’s.
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    let state = uploads.itemState(photo.id)
                    Button { detail = photo } label: { AlbumTile(assetID: photo.id, state: state, library: uploads.library) }
                        .buttonStyle(.plain).accessibilityIdentifier("albumItem-\(index)")
                        .accessibilityLabel("Photo \(index + 1)").accessibilityValue(state.label)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        // Waiting and failed photos can be taken out here; anything uploading, uploaded or uncertain has no remove control.
                        .overlay(alignment: .topTrailing) {
                            if state != .uploading && uploads.removable(photo.id) {
                                Button { Task { await uploads.removeFromAlbum([photo.id]) } } label: {
                                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink)
                                        .frame(width: 20, height: 20).background(Theme.surface.opacity(0.92), in: Circle())
                                        .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                                        .padding(5).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).accessibilityIdentifier("removeItem-\(index)")
                                .accessibilityLabel("Remove photo \(index + 1) from album")
                            }
                        }
                }
            }
            .animation(.snappy(duration: 0.35), value: photos.map(\.id))
            .sheet(item: $detail) { AlbumItemDetail(photo: $0, uploads: uploads) }
            // Leaves room to scroll the last row clear of the floating add button.
            Color.clear.frame(height: 72).accessibilityHidden(true)
        }
    }
    /// Opens the system picker, or takes the fixture's generated selection in UI tests.
    private func add() {
        if let selection = uploads.library.fixtureSelection { add(selection()) } else { picking = true }
    }
    private func add(_ assetIDs: [String]) {
        guard !assetIDs.isEmpty, !adding else { return }
        adding = true
        Task { await uploads.addToAlbum(assetIDs); adding = false }
    }
}

/// Floating add button, as the web app's create button: opens the system picker and adds the chosen photos to the album.
struct AddToAlbumButton: View {
    let uploads: UploadCoordinator
    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var adding = false
    var body: some View {
        Button { if let selection = uploads.library.fixtureSelection { add(selection()) } else { picking = true } } label: {
            ZStack {
                if adding { ProgressView().tint(Theme.onInk) } else { Image(systemName: "plus").font(.system(size: 24, weight: .regular)) }
            }
            .foregroundStyle(Theme.onInk).frame(width: 64, height: 64)
            .background(Theme.ink, in: Circle())
            .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 4))
            .shadow(color: Theme.ink.opacity(0.22), radius: 12, y: 6)
        }
        .buttonStyle(PressScaleStyle()).disabled(adding)
        .accessibilityLabel(adding ? "Adding…" : "Add to In Process album").accessibilityIdentifier("addToAlbum")
        .sensoryFeedback(.impact(weight: .light), trigger: adding)
        .photosPicker(isPresented: $picking, selection: $picked, matching: .images, photoLibrary: .shared())
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            add(items.compactMap(\.itemIdentifier))
        }
    }
    private func add(_ assetIDs: [String]) {
        guard !assetIDs.isEmpty, !adding else { return }
        adding = true
        Task { await uploads.addToAlbum(assetIDs); adding = false }
    }
}
private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// The only way into New Moment: the photo picker opens over the current screen, the chosen photo is loaded
/// there, and New Moment opens once it is ready. Cancelling the picker or the load leaves the screen as it was.
struct SinglePhotoFlow: ViewModifier {
    let model: AppModel
    @Binding var start: Bool
    @State private var picking = false
    @State private var item: PhotosPickerItem?
    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $picking, selection: $item, matching: .images, preferredItemEncoding: .current)
            .onChange(of: start) { _, requested in
                guard requested else { return }
                start = false; begin()
            }
            // Loading happens here, before navigating: leaving this screen first cancels the picker item's load.
            .task(id: item) {
                guard let item else { return }
                await model.loadPhoto(item)
                self.item = nil
                if model.photo != nil { model.route = .manual }
            }
    }
    private func begin() {
        guard let draft = model.draft, !model.loadingPhoto else { return }
        // A draft that already has a photo, is mid-publish or published, or belongs to another account resumes as it is.
        if draft.stage != .draft || !model.ownsDraft || model.photo != nil { model.route = .manual; return }
        #if DEBUG
        // Isolated UI-test launches cannot drive the system picker, so they take a generated photo instead.
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--ui-test-") }) {
            let data = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            try? model.acceptPhoto(data)
            if model.photo != nil { model.route = .manual }
            return
        }
        #endif
        model.log.emit(.photoPicker, .library); picking = true
    }
}

/// Shown beside a single-photo button while its chosen photo is still loading.
struct SinglePhotoLoading: View {
    let model: AppModel
    var body: some View {
        if model.loadingPhoto {
            HStack(spacing: 12) { ProgressView(); Text("Loading your photo, including from iCloud…").font(Theme.callout) }
                .accessibilityIdentifier("loadingSinglePhoto")
            Button("Cancel") { model.cancelPhotoLoad() }.accessibilityIdentifier("cancelSinglePhoto")
        }
    }
}

extension UploadCoordinator {
    func itemState(_ assetID: String) -> AlbumItemState {
        AlbumItemState(record(for: assetID), automatic: state.configuration?.uploadsAutomatically ?? true)
    }
}

/// How an album photo is shown. Anything not yet published counts as queued.
enum AlbumItemState: Equatable {
    case unapproved, queued, uploading, uploaded, problem
    /// A photo with no upload record is queued by the next scan when uploads are automatic; otherwise it waits for approval.
    init(_ record: UploadRecord?, automatic: Bool) {
        switch record?.status {
        case .published: self = .uploaded
        case .uploading: self = .uploading
        case .failed, .uncertain: self = .problem
        case .none: self = automatic ? .queued : .unapproved
        default: self = .queued
        }
    }
    var label: String {
        switch self {
        case .unapproved: "Waiting for approval"
        case .queued: "Queued"
        case .uploading: "Uploading"
        case .uploaded: "Uploaded"
        case .problem: "Needs attention"
        }
    }
    var symbol: String {
        switch self {
        case .unapproved: "circle.dashed"
        case .queued: "clock"
        case .uploading: "arrow.up"
        case .uploaded: "checkmark"
        case .problem: "exclamationmark"
        }
    }
}

/// Square album thumbnail. Uploaded photos are full strength with a check; everything else is dimmed with its own badge.
private struct AlbumTile: View {
    let assetID: String
    let state: AlbumItemState
    let library: any AlbumAccess
    @State private var image: UIImage?
    var body: some View {
        let pending = [.unapproved, .queued, .uploading].contains(state)
        Theme.line.aspectRatio(1, contentMode: .fit)
            .overlay {
                // Unpublished photos are grey and faint; a photo comes into colour as it is published.
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .saturation(state == .uploaded ? 1 : 0).opacity(state == .uploaded ? 1 : 0.55).transition(.opacity)
                } else { Image(systemName: "photo").foregroundStyle(Theme.secondaryText) }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            // A transfer in progress shows on the photo itself, not only in its corner badge.
            .overlay {
                if state == .uploading {
                    ProgressView().controlSize(.regular).tint(Theme.ink)
                        .padding(12).background(Theme.surface.opacity(0.9), in: Circle())
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .accessibilityIdentifier("uploadProgress")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: state.symbol).font(.system(size: 10, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(pending ? Theme.ink : Theme.onInk)
                    .frame(width: 20, height: 20)
                    .background(state == .problem ? Theme.error : (state == .uploaded ? Theme.ink : Theme.surface), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.line, lineWidth: pending ? 1 : 0))
                    .padding(5)
            }
            .animation(.easeInOut(duration: 0.6), value: state)
            .animation(.easeOut(duration: 0.3), value: image == nil)
            .contentShape(Rectangle())
            .task(id: assetID) { image = await library.thumbnail(for: assetID, side: 360) }
    }
}

/// One album photo: its state, why it is waiting, and the actions that apply.
private struct AlbumItemDetail: View {
    let photo: LibraryPhoto
    let uploads: UploadCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let record = uploads.record(for: photo.id)
        let state = uploads.itemState(photo.id)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    AlbumTile(assetID: photo.id, state: state, library: uploads.library)
                        .shadow(color: Theme.ink.opacity(0.12), radius: 12, y: 6).padding(.bottom, 6)
                    Text(record?.status == .uncertain ? "Checking publication" : state.label).font(Theme.display).tracking(-0.8)
                        .contentTransition(.opacity).animation(.easeInOut(duration: 0.3), value: state).accessibilityIdentifier("albumItemState")
                    if let record {
                        Text("Added \(record.draft.createdAt.formatted(date: .abbreviated, time: .shortened))").font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                        if let reason = record.reason { Text(reason).foregroundStyle(Theme.secondaryText).accessibilityIdentifier("albumItemReason") }
                        ForEach(record.draft.alterations ?? [], id: \.self) { Text($0).font(Theme.footnote) }
                        if record.status == .failed {
                            Button("Retry when possible") { Task { await uploads.retry(record.id) } }.buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("retryUpload")
                        }
                        if record.status == .uncertain {
                            Text("Status will be checked before any further publication. A missing timeline result does not permit another create.").font(Theme.footnote)
                            Button("Check publication status") { Task { await uploads.checkPublication(record.id) } }.buttonStyle(SecondaryButtonStyle())
                        }
                        if let result = record.draft.result { Link("View on In Process", destination: result.websiteURL).buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("viewMoment") }
                    } else if state == .queued {
                        Text(uploads.state.configuration?.paused == true ? "Waiting because uploads are paused." : "Waiting for Photos to start the upload.").foregroundStyle(Theme.secondaryText)
                    } else if state == .unapproved {
                        Text("Automatic uploading is off, so this photo waits for your approval.").foregroundStyle(Theme.secondaryText)
                        Button("Approve and publish") { Task { await uploads.approve([photo.id]) } }
                            .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("approvePhoto")
                        Text("It will be uploaded and published publicly on In Process.").font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    if state == .queued || state == .uploading, record != nil {
                        Text(uploads.state.configuration?.paused == true ? "Waiting because uploads are paused." : "Photos decides when background uploads run.").font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                    }
                    // An approval can be taken back until the upload starts.
                    if uploads.unapprovable(photo.id) {
                        Button("Un-approve") { Task { await uploads.unapprove([photo.id]) } }
                            .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("unapprovePhoto")
                    }
                    // Same rule as the X on the thumbnail: waiting and failed photos only.
                    if state != .uploading && uploads.removable(photo.id) {
                        VStack(alignment: .leading, spacing: 6) {
                            Button("Remove from In Process album", role: .destructive) {
                                Task { await uploads.removeFromAlbum([photo.id]); dismiss() }
                            }.accessibilityIdentifier("removeFromAlbum")
                            Text("The photo stays in your library and won’t be published.").font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                        }.padding(.top, 8)
                    }
                }
                .font(Theme.body).foregroundStyle(Theme.ink).buttonStyle(LinkButtonStyle())
                .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Theme.paper)
            .navigationTitle("Photo").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeAlbumItem") } }
        }
        .tint(Theme.ink)
    }
}

/// Settings and reference detail for automatic uploads, opened from the gear on the status screen.
struct UploadSettingsView: View {
    let model: AppModel
    @Bindable var uploads: UploadCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if uploads.configured {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Network").themeSectionLabel()
                            Toggle("Use cellular data", isOn: Binding(get: { uploads.state.configuration?.cellular ?? true }, set: uploads.setCellular))
                                .tint(Theme.ink).font(Theme.callout).accessibilityIdentifier("cellularUploads")
                            Text("With cellular off, uploads wait for a non-expensive connection such as Wi-Fi. Background timing is managed by Photos.").font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                        }.padding().frame(maxWidth: .infinity, alignment: .leading).themeCard()
                    }
                    UploadConfigurationView(uploads: uploads)
                    #if DEBUG
                    DeveloperSection(uploads: uploads)
                    #endif
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Account").themeSectionLabel()
                        LabeledContent("Signed in as") { Text(model.identity?.displayName ?? "").foregroundStyle(Theme.secondaryText).accessibilityIdentifier("configAccount") }
                            .font(Theme.callout)
                        Divider().overlay(Theme.line)
                        // Closing first keeps the sheet from lingering over the sign-in screen.
                        Button("Sign out", role: .destructive) { dismiss(); model.signOut() }
                            .disabled(model.isBusy).accessibilityIdentifier("signOut")
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).themeCard()
                }
                .font(Theme.body).foregroundStyle(Theme.ink).buttonStyle(LinkButtonStyle())
                .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Theme.paper)
            .navigationTitle("Configuration").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeSettings") }
            }
        }
        .tint(Theme.ink)
        .task { await uploads.refreshConfiguration() }
    }
}

private struct UploadConfigurationView: View {
    let uploads: UploadCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details").themeSectionLabel()
            // Album, upload state and network only mean something once an album is connected.
            if uploads.state.configuration != nil {
                row("Photos album", uploads.connectedAlbumName, "configAlbum")
                row("Automatic uploading", uploads.state.configuration?.uploadsAutomatically == false ? "Off" : "On", "configMode")
                // Whether Photos' background upload extension is switched on for this app; distinct from the mode above.
                row("Background uploads", uploads.automaticStatus, "configAutomatic")
                row("Network", uploads.state.configuration.map { $0.cellular ? "Wi-Fi and cellular" : "Wi-Fi only" } ?? "Not configured", "configNetwork")
            }
            row("Photos access", uploads.photosAccess.rawValue, "configPhotos")
            row("Notifications", uploads.notificationAccess?.rawValue ?? "Checking…", "configNotifications")
            row("Upload session", uploads.sessionStatus, "configSession")
            if let configuration = uploads.state.configuration {
                row("Publishes to", configuration.destination.name.isEmpty ? "Default collection" : configuration.destination.name, "configCollection")
                row("Metadata", "Defaults", "configDefaults")
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .themeCard()
    }
    private func row(_ title: String, _ value: String, _ id: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.trailing).accessibilityIdentifier(id) }
            .font(Theme.callout)
    }
}

/// One of the equal-weight actions on the fresh-install home screen.
private struct HomeChoice: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44).background(Theme.line.opacity(0.5), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.headline).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.footnote).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.secondaryText)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading).themeCard().contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle()).accessibilityLabel(title).accessibilityHint(detail)
    }
}

#if DEBUG
/// Debug-only tools, kept out of the main flow behind one row.
private struct DeveloperSection: View {
    let uploads: UploadCoordinator
    @State private var showDiagnostics = false
    @State private var expanded = false
    var body: some View {
        // A plain button, not DisclosureGroup: the group's identifier would also replace its children's.
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation { expanded.toggle() } } label: {
                HStack {
                    Text("Developer"); Spacer()
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                }.font(Theme.callout).foregroundStyle(Theme.secondaryText).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("developmentTesting").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Button("Development diagnostics") { showDiagnostics = true }.accessibilityIdentifier("developmentDiagnostics")
                    .sheet(isPresented: $showDiagnostics) { DiagnosticsView(log: uploads.log) }
                Group {
                    Text("Resource Upload Test Mode is managed in Settings → Developer → Photos. Its state can’t be read by this app.")
                        .accessibilityIdentifier("systemTestModeGuidance")
                    Text("Scheduling overrides require the app and extension to be built and run from Xcode with development signing. Photos still controls when work runs.")
                    Text("The separate one-photo diagnostic is not running on this screen.")
                }.font(Theme.footnote).foregroundStyle(Theme.secondaryText)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
