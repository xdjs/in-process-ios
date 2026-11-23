import SwiftUI
import PhotosUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    /// The gear opens Configuration from any signed-in home screen; it is also where Sign out lives.
    private var settingsAvailable: Bool { model.isAuthenticated && model.route == .home && model.automatic != nil }
    /// The connected album screen, which can be refreshed and has the floating add button.
    private var albumHome: Bool {
        guard settingsAvailable, let automatic = model.automatic else { return false }
        return automatic.configured || automatic.state.blocker != nil
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if model.restoringSession { LoadingView(message: "Opening In Process…") }
                    else if model.isSigningIn { LoadingView(message: "Signing in…") }
                    else if !model.isAuthenticated { SignInView(model: model) }
                    else if let automatic = model.automatic, model.route == .home {
                        UploadStatusView(model: model, uploads: automatic)
                    } else if model.route == .setup, let automatic = model.automatic {
                        AutomaticSetupView(model: model, uploads: automatic)
                    } else if !model.ownsDraft {
                        ContentUnavailableView("A draft is saved for another account", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("Sign out and return with the account that started this draft. It has been kept safe on this device."))
                    } else if model.draft?.stage == .published { SuccessView(model: model) }
                    else { ComposeView(model: model) }
                    if let activity = model.activity, !model.restoringSession, !model.isSigningIn {
                        HStack(spacing: 12) { ProgressView(); Text(activity).font(Theme.callout) }.accessibilityIdentifier("activity")
                    }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(Theme.callout).foregroundStyle(Theme.error).accessibilityIdentifier("errorMessage")
                    }
                    if let status = model.signOutStatus { Text(status).font(Theme.callout).foregroundStyle(Theme.secondaryText).accessibilityIdentifier("signOutStatus") }
                    #if DEBUG
                    if let status = model.credentialValidationStatus { Text(status).font(Theme.callout).accessibilityIdentifier("credentialValidationStatus") }
                    #endif
                }
                .font(Theme.body).foregroundStyle(Theme.ink).buttonStyle(LinkButtonStyle())
                .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity, alignment: .center)
                .animation(.easeInOut(duration: 0.25), value: model.route)
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if albumHome, let automatic = model.automatic, automatic.configured {
                    AddToAlbumButton(uploads: automatic).padding(.bottom, 12).transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .refreshable { if albumHome, let automatic = model.automatic { await automatic.scan(); await automatic.refreshConfiguration() } }
            .background(Theme.paper)
            .toolbarBackground(Theme.paper, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("in•process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("in·process").font(Theme.wordmark).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                }
                if model.isAuthenticated && model.route != .home {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation(.easeInOut(duration: 0.25)) { model.route = .home }; model.automatic?.refresh() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Home").accessibilityIdentifier("home")
                    }
                }
                if settingsAvailable {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Configuration").accessibilityIdentifier("uploadSettings")
                    }
                }
                // Sign out lives in Configuration. Without upload storage there is no Configuration, so it stays here.
                if model.isAuthenticated && model.automatic == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Sign out", action: model.signOut).font(Theme.callout).disabled(model.isBusy).accessibilityIdentifier("signOut")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                if let automatic = model.automatic { UploadSettingsView(model: model, uploads: automatic) }
            }
            .onChange(of: settingsAvailable) { _, available in if !available { showSettings = false } } // Never leave settings open past sign-out or expiry.
            .onChange(of: model.isAuthenticated, initial: true) { _, value in
                model.log.emit(.authGate, .auth, [.authorized: .flag(value)])
            }
            .task(id: model.session?.expiresAt) { await model.waitForSessionExpiry() }
            .tint(Theme.ink)
        }
    }
}

/// Shown while a session is being restored or a sign-in completed: nothing to tap, and no sign-in controls.
struct LoadingView: View {
    let message: String
    var body: some View {
        VStack(spacing: 20) {
            Image("Squiggle").resizable().scaledToFit().frame(width: 64, height: 64).foregroundStyle(Theme.ink).accessibilityHidden(true).appear(0)
            HStack(spacing: 12) { ProgressView().tint(Theme.ink); Text(message).font(Theme.callout).foregroundStyle(Theme.secondaryText) }
                .accessibilityIdentifier("loading").appear(1)
        }
        // Fills the visible screen so the logo sits at its vertical centre. The allowance covers the page
        // padding and the title bar above, which would otherwise push the logo below the middle.
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical) { height, _ in max(0, height - 90) }
    }
}

struct SignInView: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("Squiggle").resizable().scaledToFit().frame(width: 64, height: 64).foregroundStyle(Theme.ink)
                .padding(.top, 36).padding(.bottom, 28).accessibilityHidden(true).appear(0)
            DisplayTitle(lines: model.codeSent ? ["Check your", "email."] : ["A moment of", "your process."])
                .id(model.codeSent).transition(.opacity).appear(1)
            Text(model.codeSent ? "Enter the six-digit code sent to \(model.email)." : "Sign in to or create your In Process account.")
                .foregroundStyle(Theme.secondaryText).padding(.top, 14).appear(2)
            if model.automatic?.configured == true {
                Text("Sign in to resume uploads. Your album configuration, pending uploads, and draft are saved.")
                    .font(Theme.callout).foregroundStyle(Theme.secondaryText).padding(.top, 12).accessibilityIdentifier("signInRecovery")
            }
            VStack(alignment: .leading, spacing: 14) {
                if model.session != nil || model.needsCredentialRetry {
                    Button("Retry loading account") { Task { await model.retryAccount() } }.buttonStyle(PrimaryButtonStyle()).disabled(model.isBusy).accessibilityIdentifier("retryAccount")
                    if model.mayReplaceCredential {
                        Button("Create a replacement sign-in key") { Task { await model.replaceUncertainCredential() } }
                            .disabled(model.isBusy).accessibilityIdentifier("replaceCredential")
                        Link("Manage existing API keys", destination: URL(string: "https://inprocess.world/manage/api-keys")!)
                    }
                    Button("Use a different email", action: model.signOut).disabled(model.isBusy)
                } else if model.codeSent {
                    TextField("000000", text: $model.code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        .font(Theme.stat.monospacedDigit()).tracking(10).multilineTextAlignment(.center)
                        .themeField(focused: focused)
                        .accessibilityLabel("Six-digit code").accessibilityIdentifier("codeField").focused($focused)
                        .onChange(of: model.code) { old, value in
                            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                            model.code = digits
                            // Submit once when the sixth digit arrives; the Sign in button remains for retries.
                            if digits.count == 6, old.count < 6, !model.isBusy { focused = false; Task { await model.signIn() } }
                        }
                    Button("Sign in") { focused = false; Task { await model.signIn() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!model.validCode || model.isBusy).accessibilityIdentifier("verifyCode")
                    HStack {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(ceil(model.resendAvailableAt.timeIntervalSince(context.date))))
                            Button(seconds > 0 ? "Resend code in \(seconds)s" : "Resend code") { Task { await model.sendCode() } }
                                .disabled(seconds > 0 || model.isBusy)
                        }
                        Spacer()
                        Button("Use a different email") { model.log.emit(.authVerify, .auth, [.status: .tag(.canceled)]); model.codeSent = false; model.code = ""; model.error = nil }.disabled(model.isBusy)
                    }
                    .padding(.top, 4)
                } else {
                    TextField("Email address", text: $model.email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .themeField(focused: focused).accessibilityIdentifier("emailField").focused($focused)
                        .submitLabel(.send).onSubmit { if model.validEmail && !model.isBusy { focused = false; Task { await model.sendCode() } } }
                    Button("Send sign-in code") { focused = false; Task { await model.sendCode() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!model.validEmail || model.isBusy).accessibilityIdentifier("sendCode")
                    Text("We’ll email you a six-digit code. There’s no password.")
                        .font(Theme.footnote).foregroundStyle(Theme.secondaryText).padding(.top, 2)
                }
            }
            .padding(.top, 32).appear(3)
        }
        .animation(.easeInOut(duration: 0.3), value: model.codeSent)
    }
}

struct ComposeView: View {
    @Bindable var model: AppModel
    @State private var selection: PhotosPickerItem?
    @State private var showPicker = false
    /// New Moment never exists without a photo: a draft with nothing chosen has no screen here.
    private var empty: Bool { model.draft?.stage == .draft && model.photo == nil }
    var body: some View {
        if empty { Color.clear.frame(height: 1).onAppear { model.route = .home } } else { content }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New Moment").font(Theme.display).tracking(-0.8)
                Text("Publishing as \(model.identity?.displayName ?? "")").foregroundStyle(Theme.secondaryText)
            }.appear(0)
            if let photo = model.photo { PhotoPreview(photo: photo).appear(1) }
            if model.draft?.stage == .draft {
                // Changing the photo is a minor action; keep Publish in view. Removing it leaves New Moment.
                HStack(spacing: 18) {
                    Button("Choose a different photo") { openPicker() }.buttonStyle(BracketButtonStyle()).accessibilityIdentifier("choosePhoto")
                    Button("Remove photo", role: .destructive) {
                        model.removePhoto(); selection = nil
                        if model.photo == nil { model.route = .home }
                    }.buttonStyle(BracketButtonStyle()).accessibilityIdentifier("removePhoto")
                }.disabled(model.isBusy).padding(.top, -10)
                if model.loadingPhoto {
                    HStack { ProgressView(); Text("Loading your photo, including from iCloud…").font(Theme.callout) }
                    Button("Cancel photo loading") { model.cancelPhotoLoad(); selection = nil }
                }
                if model.photo != nil {
                    TextField("Title (optional)", text: Binding(get: { model.draft?.title ?? "" }, set: { model.edit(title: $0) }))
                        .themeField().accessibilityIdentifier("titleField")
                    TextField("Description (optional)", text: Binding(get: { model.draft?.description ?? "" }, set: { model.edit(description: $0) }), axis: .vertical)
                        .lineLimit(3...6).themeField().accessibilityIdentifier("descriptionField")
                }
            } else if let draft = model.draft, !draft.title.isEmpty { Text(draft.title).font(Theme.title) }
            if model.photo != nil {
                VStack(spacing: 12) {
                    LabeledContent("Collection") { Text(model.draft?.destination.name ?? "").foregroundStyle(Theme.secondaryText) }
                    Divider().overlay(Theme.line)
                    LabeledContent("Collect price") { Text("1 USDC").font(Theme.note).foregroundStyle(Theme.gold) }
                }.font(Theme.callout).padding().themeCard()
                ForEach(model.draft?.alterations ?? [], id: \.self) { Text($0).font(Theme.footnote).foregroundStyle(Theme.secondaryText) }
                if model.draft?.sourceAssetID == nil {
                    Text("Photos did not provide an asset identifier. This selection cannot be matched reliably to a later album upload.").font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                }
                if model.draft?.stage == .uncertain {
                    Text("Publication needs checking").font(Theme.headline)
                    Text("The request may have completed. Checking looks for this exact Moment and will not publish another copy.").font(Theme.callout).foregroundStyle(Theme.secondaryText)
                    Button("Check publication status") { Task { await model.checkPublication() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(model.isBusy).accessibilityIdentifier("checkStatus")
                    Link("Open In Process", destination: URL(string: "https://inprocess.world")!)
                } else {
                    Text("Publishing makes this photo public and may store it permanently. In Process covers storage. The collect price is for collectors.")
                        .font(Theme.footnote).foregroundStyle(Theme.secondaryText)
                    Button(model.draft?.stage == .draft ? "Publish Moment" : "Continue publishing") { Task { await model.publish() } }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!model.canPublish).accessibilityIdentifier("publishMoment")
                }
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $selection, matching: .images, preferredItemEncoding: .current)
        .task(id: selection) { await model.loadPhoto(selection) }
    }
    private func openPicker() { model.log.emit(.photoPicker, .library); showPicker = true }
}

struct SuccessView: View {
    let model: AppModel
    /// The photo arrives grey and comes into colour, as album photos do when they are published.
    @State private var revealed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Published", systemImage: "checkmark.circle.fill").font(Theme.display).tracking(-0.8)
                .symbolEffect(.bounce, value: revealed).accessibilityIdentifier("publishedHeading").appear(0)
            if let photo = model.photo {
                PhotoPreview(photo: photo).saturation(revealed ? 1 : 0).opacity(revealed ? 1 : 0.55)
            }
            if let title = model.draft?.title, !title.isEmpty { Text(title).font(Theme.title) }
            Text("Your Moment is on In Process. Collect price: \(Text("1 USDC").foregroundStyle(Theme.gold)).").foregroundStyle(Theme.secondaryText).appear(1)
            VStack(spacing: 14) {
                if let result = model.draft?.result {
                    Link("View on In Process", destination: result.websiteURL).buttonStyle(PrimaryButtonStyle())
                }
                Button("Choose another photo", action: model.startAnother).frame(maxWidth: .infinity)
            }.appear(2)
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.9).delay(0.15)) { revealed = true } }
        .sensoryFeedback(.success, trigger: revealed)
    }
}

struct PhotoPreview: View {
    let photo: UIImage
    var body: some View {
        Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 380)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
            .shadow(color: Theme.ink.opacity(0.14), radius: 12, y: 6)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Selected photo preview")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.button).frame(maxWidth: .infinity).padding(.vertical, 15)
            .foregroundStyle(Theme.onInk)
            .background(Theme.ink.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.25), in: RoundedRectangle(cornerRadius: Theme.buttonRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed).animation(.easeOut(duration: 0.2), value: enabled)
    }
}
