import AppKit
import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(0)

            StreamDashboardView()
                .tabItem { Label("Stream", systemImage: "rectangle.grid.2x2.fill") }
                .tag(1)
        }
        .tint(AppTheme.accent)
    }
}

private struct HomeView: View {
    @EnvironmentObject private var store: CameraStore
    @State private var showingAddCamera = false
    @State private var showingAddOptions = false
    @State private var showingBatchAdd = false
    @State private var selectedCamera: CameraRecord?
    @State private var editingCamera: CameraRecord?
    @State private var deletingCamera: CameraRecord?

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    HStack(spacing: 14) {
                        Image("LocalCamLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 54, height: 54)
                        Text("Local Cam")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(AppTheme.ink)
                    }

                    Spacer()

                    Button {
                        showingAddOptions = true
                    } label: {
                        Label("Add Camera", systemImage: "plus")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if store.cameras.isEmpty {
                    EmptyHomeView {
                        showingAddOptions = true
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                            ForEach(store.cameras) { camera in
                                CameraCardView(camera: camera) {
                                    selectedCamera = camera
                                } onEdit: {
                                    editingCamera = camera
                                } onDelete: {
                                    deletingCamera = camera
                                }
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $showingAddCamera) {
            AddCameraView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 760)
        }
        .sheet(isPresented: $showingBatchAdd) {
            BatchAddCameraView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 760)
        }
        .sheet(item: $editingCamera) { camera in
            AddCameraView(cameraToEdit: camera)
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 760)
        }
        .sheet(item: $selectedCamera) { camera in
            CameraDetailView(camera: camera)
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 760)
        }
        .alert("Delete camera?", isPresented: Binding(get: { deletingCamera != nil }, set: { if !$0 { deletingCamera = nil } })) {
            Button("Cancel", role: .cancel) {
                deletingCamera = nil
            }
            Button("Delete", role: .destructive) {
                if let deletingCamera {
                    store.remove(deletingCamera)
                }
                deletingCamera = nil
            }
        } message: {
            Text("Remove \(deletingCamera?.name ?? "this camera") from Local Cam?")
        }
        .confirmationDialog("Add cameras", isPresented: $showingAddOptions) {
            Button("Add Camera") {
                showingAddCamera = true
            }
            Button("Batch Add Cameras") {
                showingBatchAdd = true
            }
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct EmptyHomeView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image("LocalCamLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 132, height: 132)

            Text("No Cameras Added Yet")
                .font(.title.bold())
                .foregroundStyle(AppTheme.ink)

            Text("Add your first camera to start monitoring live video.")
                .font(.title3)
                .foregroundStyle(.secondary)

            Button("Add Camera", action: onAdd)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(42)
        .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct CameraCardView: View {
    let camera: CameraRecord
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BrandLogoView(type: camera.cameraType, size: 58)

                VStack(alignment: .leading, spacing: 5) {
                    Text(camera.name)
                        .font(.title3.bold())
                        .foregroundStyle(AppTheme.ink)
                    Text(camera.connectionSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack {
                Button("Open", action: onOpen)
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                Button("Edit", action: onEdit)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(SecondaryButtonStyle(compact: true))
            }
        }
        .padding(18)
        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

private struct AddCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CameraStore

    private let cameraToEdit: CameraRecord?

    @State private var cameraType: CameraType?
    @State private var cameraName: String
    @State private var host: String
    @State private var username: String
    @State private var password: String
    @State private var rtspPort: String
    @State private var onvifPort: String
    @State private var customMainPath: String
    @State private var customSubPath: String
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var discoveredCameras: [DiscoveredCamera] = []
    @State private var searchMessage: String?
    @State private var validationMessage: String?
    @State private var isPasswordVisible = false

    init(cameraToEdit: CameraRecord? = nil) {
        self.cameraToEdit = cameraToEdit
        let type = cameraToEdit?.cameraType
        _cameraType = State(initialValue: type)
        _cameraName = State(initialValue: cameraToEdit?.name ?? "")
        _host = State(initialValue: cameraToEdit?.host ?? "")
        _username = State(initialValue: cameraToEdit?.username ?? type?.defaultUsername ?? "")
        _password = State(initialValue: cameraToEdit?.password ?? "")
        _rtspPort = State(initialValue: String(cameraToEdit?.rtspPort ?? type?.defaultRTSPPort ?? 554))
        _onvifPort = State(initialValue: String(cameraToEdit?.onvifPort ?? type?.defaultONVIFPort ?? 8080))
        _customMainPath = State(initialValue: cameraToEdit?.rtspPath ?? CameraType.other.rtspPath(for: .main))
        _customSubPath = State(initialValue: cameraToEdit?.rtspSubPath ?? CameraType.other.rtspPath(for: .sub))
    }

    private var credentialStatusLabel: String {
        let usernameText = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "username blank" : "username set"
        let passwordText = password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "password blank" : "password set"
        return "\(usernameText) | \(passwordText)"
    }

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            if let selectedType = cameraType {
                setupForm(for: selectedType)
            } else {
                BrandSelectionView(onBack: {
                    dismiss()
                }) { selectedType in
                    cameraType = selectedType
                    applyDefaults(for: selectedType)
                }
            }
        }
    }

    private func setupForm(for selectedType: CameraType) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button(cameraToEdit == nil ? "Back" : "Cancel") {
                    if cameraToEdit == nil {
                        cameraType = nil
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)

                Spacer()

                Text(cameraToEdit == nil ? "Add Camera" : "Edit Camera")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)

                Spacer()

                Button(cameraToEdit == nil ? "Save" : "Update") {
                    Task { await saveCamera() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .disabled(isSaving)
            }
            .padding(22)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrandSummaryCard(type: selectedType)

                    sectionTitle("LAN SEARCH")
                    lanSearchCard(selectedType)

                    sectionTitle("CAMERA")
                    MacFormCard {
                        TextField("Camera name", text: $cameraName)
                        Divider()
                        TextField("Camera IP or host", text: $host)
                    }

                    if selectedType == .other {
                        sectionTitle("PORTS")
                        MacFormCard {
                            HStack {
                                TextField("RTSP port", text: $rtspPort)
                                Divider()
                                TextField("ONVIF port", text: $onvifPort)
                            }
                        }
                    }

                    sectionTitle("STREAMS")
                    MacFormCard {
                        streamPreviewRow(title: "Main Stream", path: mainPath(for: selectedType))
                        Divider()
                        streamPreviewRow(title: "Sub Stream", path: subPath(for: selectedType))
                        if selectedType == .other {
                            Divider()
                            TextField("Main stream path", text: $customMainPath)
                            Divider()
                            TextField("Sub stream path", text: $customSubPath)
                        }
                    }

                    sectionTitle("CREDENTIALS")
                    MacFormCard {
                        TextField("Username", text: $username)
                        Divider()
                        HStack {
                            Group {
                                if isPasswordVisible {
                                    TextField("Password", text: $password)
                                } else {
                                    SecureField("Password", text: $password)
                                }
                            }
                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.accent)
                            .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                        }
                    }

                    if isSaving {
                        HStack {
                            ProgressView()
                            Text("Validating camera...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
    }

    private func lanSearchCard(_ selectedType: CameraType) -> some View {
        MacFormCard {
            Button {
                searchLAN()
            } label: {
                HStack {
                    if isSearching {
                        ProgressView()
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    Text(isSearching ? "Searching Local Network" : "Search Local Network")
                        .font(.title3.weight(.medium))
                    Spacer()
                }
                .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.plain)

            Divider()

            Text(searchMessage ?? "Tap a discovered camera to prefill its host.")
                .foregroundStyle(.secondary)

            ForEach(discoveredCameras) { camera in
                Divider()
                Button {
                    applyDiscovery(camera)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(camera.name)
                            .font(.title3.weight(.medium))
                        Text("\(camera.host) | \(credentialStatusLabel)")
                            .foregroundStyle(Color(red: 0.22, green: 0.54, blue: 0.88))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
            }
        }
    }

    private func streamPreviewRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(path.isEmpty ? "/" : path)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func searchLAN() {
        isSearching = true
        discoveredCameras = []
        searchMessage = nil
        Task {
            guard await LocalCameraDiscoveryService.shared.isWiFiAvailable() else {
                await MainActor.run {
                    isSearching = false
                    searchMessage = "Connect to a network and try again."
                }
                return
            }
            let results = await LocalCameraDiscoveryService.shared.search()
            await MainActor.run {
                isSearching = false
                discoveredCameras = results
                searchMessage = results.isEmpty
                    ? "No ONVIF cameras replied on the LAN. You can still enter camera details manually."
                    : "Tap a discovered camera to prefill its host."
            }
        }
    }

    private func applyDiscovery(_ camera: DiscoveredCamera) {
        cameraName = camera.name
        host = camera.host
        if cameraType == .other {
            rtspPort = String(camera.rtspPort)
            onvifPort = String(camera.onvifPort)
        }
        validationMessage = nil
    }

    @MainActor
    private func saveCamera() async {
        guard let selectedType = cameraType else { return }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Camera IP or host is required."
            return
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Username is required."
            return
        }
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Password is required."
            return
        }
        let parsedRTSP: Int
        let parsedONVIF: Int
        if selectedType == .other {
            guard let customRTSP = Int(rtspPort), let customONVIF = Int(onvifPort) else {
                validationMessage = "Ports must be valid whole numbers."
                return
            }
            parsedRTSP = customRTSP
            parsedONVIF = customONVIF
        } else {
            parsedRTSP = selectedType.defaultRTSPPort
            parsedONVIF = selectedType.defaultONVIFPort
        }

        let camera = CameraRecord(
            id: cameraToEdit?.id ?? UUID(),
            name: cameraName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(selectedType.title) \(host)" : cameraName,
            cameraType: selectedType,
            host: host,
            username: username,
            password: password,
            rtspPort: parsedRTSP,
            onvifPort: parsedONVIF,
            rtspPath: mainPath(for: selectedType),
            rtspSubPath: subPath(for: selectedType)
        )

        isSaving = true
        validationMessage = nil
        do {
            try await LocalONVIFCameraService.shared.validateCredentials(for: camera)
        } catch {
            isSaving = false
            validationMessage = "ONVIF validation failed. Please check username, password, IP, and ONVIF port."
            return
        }
        isSaving = false

        if cameraToEdit == nil {
            store.add(camera: camera)
        } else {
            store.update(camera: camera)
        }
        dismiss()
    }

    private func applyDefaults(for type: CameraType) {
        username = type.defaultUsername
        rtspPort = String(type.defaultRTSPPort)
        onvifPort = String(type.defaultONVIFPort)
        customMainPath = type.rtspPath(for: .main)
        customSubPath = type.rtspPath(for: .sub)
        validationMessage = nil
    }

    private func mainPath(for type: CameraType) -> String {
        type == .other ? customMainPath : type.rtspPath(for: .main)
    }

    private func subPath(for type: CameraType) -> String {
        type == .other ? customSubPath : type.rtspPath(for: .sub)
    }
}

private struct BatchCameraDraft: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var username = ""
    var password = ""
    var isExpanded = false

    var credentialStatusLabel: String {
        let usernameText = username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "username blank" : "username set"
        let passwordText = password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "password blank" : "password set"
        return "\(usernameText) | \(passwordText)"
    }
}

private struct BatchAddCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CameraStore

    @State private var cameraType: CameraType?
    @State private var sharedUsername = ""
    @State private var sharedPassword = ""
    @State private var customRTSPPort = "554"
    @State private var customONVIFPort = "8080"
    @State private var customMainPath = CameraType.other.rtspPath(for: .main)
    @State private var customSubPath = CameraType.other.rtspPath(for: .sub)
    @State private var isSearching = false
    @State private var isSaving = false
    @State private var drafts: [BatchCameraDraft] = []
    @State private var message: String?
    @State private var validationError: String?
    @State private var isPasswordVisible = false

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()

            if let selectedType = cameraType {
                batchForm(for: selectedType)
            } else {
                BrandSelectionView(onBack: {
                    dismiss()
                }) { selectedType in
                    cameraType = selectedType
                    sharedUsername = selectedType.defaultUsername
                    customRTSPPort = String(selectedType.defaultRTSPPort)
                    customONVIFPort = String(selectedType.defaultONVIFPort)
                    customMainPath = selectedType.rtspPath(for: .main)
                    customSubPath = selectedType.rtspPath(for: .sub)
                }
            }
        }
        .alert("Validation failed", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) {
            Button("OK", role: .cancel) {
                validationError = nil
            }
        } message: {
            Text(validationError ?? "")
        }
    }

    private func batchForm(for selectedType: CameraType) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("Back") {
                    cameraType = nil
                    drafts = []
                    message = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)

                Spacer()

                Text("Batch Add Cameras")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)

                Spacer()

                Button("Add All") {
                    Task {
                        await saveAll(for: selectedType)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)
                .disabled(isSaving)
            }
            .padding(22)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    BrandSummaryCard(type: selectedType)

                    sectionTitle("SHARED CREDENTIALS")
                    MacFormCard {
                        TextField("Username", text: $sharedUsername)
                        Divider()
                        HStack {
                            Group {
                                if isPasswordVisible {
                                    TextField("Password", text: $sharedPassword)
                                } else {
                                    SecureField("Password", text: $sharedPassword)
                                }
                            }
                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.accent)
                        }
                        Divider()
                        Button("Apply Credentials To All Cameras") {
                            drafts = drafts.map { draft in
                                var updated = draft
                                updated.username = sharedUsername
                                updated.password = sharedPassword
                                return updated
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.accent)
                    }

                    sectionTitle("LAN SEARCH")
                    MacFormCard {
                        Button {
                            searchLAN()
                        } label: {
                            HStack {
                                if isSearching {
                                    ProgressView()
                                } else {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                }
                                Text(isSearching ? "Searching Local Network" : "Search Local Network")
                                    .font(.title3.weight(.medium))
                                Spacer()
                            }
                            .foregroundStyle(AppTheme.accent)
                        }
                        .buttonStyle(.plain)

                        Divider()
                        Text(message ?? "Tap a discovered camera to update its username and password.")
                            .foregroundStyle(.secondary)

                        ForEach($drafts) { $draft in
                            Divider()
                            Button {
                                draft.isExpanded.toggle()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(draft.name)
                                        .font(.title3.weight(.medium))
                                    Text("\(draft.host) | \(draft.credentialStatusLabel)")
                                        .foregroundStyle(Color(red: 0.22, green: 0.54, blue: 0.88))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.accent)

                            if draft.isExpanded {
                                TextField("Username", text: $draft.username)
                                Divider()
                                SecureField("Password", text: $draft.password)
                            }
                        }
                    }

                    if selectedType == .other {
                        sectionTitle("PORTS")
                        MacFormCard {
                            HStack {
                                TextField("RTSP port", text: $customRTSPPort)
                                Divider()
                                TextField("ONVIF port", text: $customONVIFPort)
                            }
                        }

                        sectionTitle("STREAMS")
                        MacFormCard {
                            TextField("Main stream path", text: $customMainPath)
                            Divider()
                            TextField("Sub stream path", text: $customSubPath)
                        }
                    }

                    Button("Batch Add All Cameras") {
                        Task {
                            await saveAll(for: selectedType)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSaving)

                    if isSaving {
                        HStack {
                            ProgressView()
                            Text("Validating cameras...")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
    }

    private func searchLAN() {
        isSearching = true
        drafts = []
        message = nil
        Task {
            let results = await LocalCameraDiscoveryService.shared.search()
            await MainActor.run {
                isSearching = false
                drafts = results.map {
                    BatchCameraDraft(name: $0.name, host: $0.host, username: sharedUsername, password: sharedPassword)
                }
                message = drafts.isEmpty ? "No ONVIF cameras replied on the LAN." : "Found \(drafts.count) camera(s). Click one to edit credentials."
            }
        }
    }

    @MainActor
    private func saveAll(for selectedType: CameraType) async {
        guard !drafts.isEmpty else {
            validationError = "Search and select cameras first."
            return
        }
        guard drafts.allSatisfy({ !$0.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            validationError = "Username and password are required for every camera."
            return
        }

        let rtspPort: Int
        let onvifPort: Int
        if selectedType == .other {
            guard let parsedRTSP = Int(customRTSPPort), let parsedONVIF = Int(customONVIFPort) else {
                validationError = "Ports must be valid whole numbers."
                return
            }
            rtspPort = parsedRTSP
            onvifPort = parsedONVIF
        } else {
            rtspPort = selectedType.defaultRTSPPort
            onvifPort = selectedType.defaultONVIFPort
        }

        let cameras = drafts.map { draft in
            CameraRecord(
                name: draft.name.isEmpty ? "\(selectedType.title) \(draft.host)" : draft.name,
                cameraType: selectedType,
                host: draft.host,
                username: draft.username,
                password: draft.password,
                rtspPort: rtspPort,
                onvifPort: onvifPort,
                rtspPath: selectedType == .other ? customMainPath : selectedType.rtspPath(for: .main),
                rtspSubPath: selectedType == .other ? customSubPath : selectedType.rtspPath(for: .sub)
            )
        }

        isSaving = true
        for camera in cameras {
            do {
                try await LocalONVIFCameraService.shared.validateCredentials(for: camera)
            } catch {
                isSaving = false
                validationError = "ONVIF validation failed for \(camera.name). Please check username, password, IP, and ONVIF port."
                return
            }
        }
        isSaving = false

        store.add(cameras: cameras)
        dismiss()
    }
}

private struct BrandSelectionView: View {
    let onBack: () -> Void
    let onSelect: (CameraType) -> Void
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.headline.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.accent)

                Spacer()

                Text("Camera Type")
                    .font(.title2.weight(.semibold))

                Spacer()

                Color.clear
                    .frame(width: 74, height: 1)
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(CameraType.allCases) { type in
                        Button {
                            onSelect(type)
                        } label: {
                            VStack(spacing: 14) {
                                BrandLogoView(type: type, size: 82)
                                Text(type.title)
                                    .font(.headline)
                                    .foregroundStyle(AppTheme.ink)
                                Text("ONVIF \(type.defaultONVIFPort)")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .padding()
                            .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(30)
            }
        }
    }
}

private struct CameraDetailView: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss

    let camera: CameraRecord

    @StateObject private var playerController: RTSPPlayerController
    @State private var selectedStream: StreamType = .main
    @State private var editingCamera: CameraRecord?
    @State private var toastMessage: String?
    @State private var activeCommand: CameraCommand?
    @State private var isSendingCommand = false
    @State private var isPTZUnavailable = false
    @State private var fullscreenPresenter = FullscreenWindowPresenter()

    init(camera: CameraRecord) {
        self.camera = camera
        _playerController = StateObject(
            wrappedValue: RTSPPlayerController(rtspURL: camera.manualRTSPURL(for: .main) ?? URL(string: "rtsp://127.0.0.1:554/11")!)
        )
    }

    private var currentCamera: CameraRecord {
        store.cameras.first(where: { $0.id == camera.id }) ?? camera
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppTheme.pageBackground.ignoresSafeArea()

            VStack(spacing: 18) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)

                    Text(currentCamera.name)
                        .font(.title.weight(.bold))
                    Spacer()
                    Button {
                        fullscreenPresenter.present {
                            FullscreenStreamView(camera: currentCamera, stream: selectedStream) {
                                fullscreenPresenter.close()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(CircleButtonStyle())
                    Button {
                        editingCamera = currentCamera
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(CircleButtonStyle())
                }
                .foregroundStyle(AppTheme.ink)

                HStack(alignment: .top, spacing: 22) {
                    VStack(spacing: 16) {
                        videoPlayer
                        streamPicker
                    }

                    VStack {
                        controls
                        Spacer()
                    }
                    .frame(width: 360)
                }

                Spacer()
            }
            .padding(26)

            if let toastMessage {
                ToastView(message: toastMessage)
                    .padding(.top, 22)
            }
        }
        .sheet(item: $editingCamera) { camera in
            AddCameraView(cameraToEdit: camera)
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 760)
        }
        .task {
            preparePlayback()
        }
        .onChange(of: selectedStream) { _ in
            preparePlayback()
        }
        .onDisappear {
            playerController.stop()
            fullscreenPresenter.close()
        }
    }

    private var videoPlayer: some View {
        VLCVideoContainerView(controller: playerController)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(.black)
            .overlay(alignment: .topLeading) {
                PlaybackStatusBadge(controller: playerController)
                    .padding(10)
            }
    }

    private var streamPicker: some View {
        StreamSegmentedControl(selection: $selectedStream)
    }

    private var controls: some View {
        VStack(spacing: 18) {
            ControlButton(icon: CameraCommand.up.icon, isActive: activeCommand == .up, isBusy: isSendingCommand, isUnavailable: isPTZUnavailable) { sendCommand(.up) }
            HStack(spacing: 18) {
                ControlButton(icon: CameraCommand.left.icon, isActive: activeCommand == .left, isBusy: isSendingCommand, isUnavailable: isPTZUnavailable) { sendCommand(.left) }
                ZoomControlButton(
                    isZoomInActive: activeCommand == .zoomIn,
                    isZoomOutActive: activeCommand == .zoomOut,
                    isBusy: isSendingCommand,
                    isUnavailable: isPTZUnavailable,
                    onZoomIn: { sendCommand(.zoomIn) },
                    onZoomOut: { sendCommand(.zoomOut) }
                )
                ControlButton(icon: CameraCommand.right.icon, isActive: activeCommand == .right, isBusy: isSendingCommand, isUnavailable: isPTZUnavailable) { sendCommand(.right) }
            }
            ControlButton(icon: CameraCommand.down.icon, isActive: activeCommand == .down, isBusy: isSendingCommand, isUnavailable: isPTZUnavailable) { sendCommand(.down) }
        }
    }

    private func preparePlayback() {
        guard let url = currentCamera.manualRTSPURL(for: selectedStream) else { return }
        playerController.setStream(url: url)
        playerController.play()
    }

    private func sendCommand(_ command: CameraCommand) {
        guard !isSendingCommand else { return }
        guard !isPTZUnavailable else {
            showToast("PTZ Service not reported by this camera")
            return
        }
        activeCommand = command
        isSendingCommand = true
        Task {
            let result = await LocalONVIFCameraService.shared.sendPTZ(command: command, camera: currentCamera)
            await MainActor.run {
                isSendingCommand = false
                activeCommand = nil
                if result.localizedCaseInsensitiveContains("PTZ service not reported") {
                    isPTZUnavailable = true
                }
                showToast(result)
            }
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            await MainActor.run {
                toastMessage = nil
            }
        }
    }
}

private struct StreamDashboardView: View {
    @EnvironmentObject private var store: CameraStore
    @AppStorage("stream-wall.rows") private var rows = 2
    @AppStorage("stream-wall.columns") private var columns = 2
    @AppStorage("stream-wall.slot-camera-ids") private var slotCameraIDsValue = ""
    @State private var selectedCamera: CameraRecord?
    @State private var fullscreenPresenter = FullscreenWindowPresenter()
    @State private var isFullscreenActive = false
    @State private var streamRefreshID = UUID()

    private var slotCount: Int { rows * columns }
    private var gridColumns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 14), count: columns) }
    private var slotCameraIDs: [String] { slotCameraIDsValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    private var camerasForSlots: [CameraRecord?] { (0..<slotCount).map { cameraForSlot($0) } }

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Streams")
                        .font(.system(size: 34, weight: .bold))
                    Spacer()
                    Button {
                        isFullscreenActive = true
                        fullscreenPresenter.present {
                            StreamWallFullscreenView(cameras: camerasForSlots, rows: rows, columns: columns) {
                                fullscreenPresenter.close()
                                isFullscreenActive = false
                                refreshStreamGridAfterFullscreen()
                            }
                        }
                    } label: {
                        Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(store.cameras.isEmpty)
                }

                layoutControls

                if store.cameras.isEmpty {
                    EmptyHomeView {}
                } else {
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            ForEach(0..<slotCount, id: \.self) { index in
                                StreamSlotView(
                                    slotNumber: index + 1,
                                    camera: cameraForSlot(index),
                                    cameras: store.cameras,
                                    isPlaybackPaused: isFullscreenActive,
                                    onSelect: { cameraID in setCameraID(cameraID, forSlot: index) },
                                    onOpen: { camera in selectedCamera = camera }
                                )
                            }
                        }
                        .id(streamRefreshID)
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $selectedCamera) { camera in
            CameraDetailView(camera: camera)
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 760)
        }
        .onDisappear {
            fullscreenPresenter.close()
            isFullscreenActive = false
        }
    }

    private var layoutControls: some View {
        HStack(spacing: 18) {
            Stepper("Rows \(rows)", value: $rows, in: 1...4)
            Stepper("Columns \(columns)", value: $columns, in: 1...4)
            Text("\(rows) x \(columns)")
                .font(.headline)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func cameraForSlot(_ index: Int) -> CameraRecord? {
        let ids = slotCameraIDs
        if ids.indices.contains(index), let id = UUID(uuidString: ids[index]) {
            return store.cameras.first { $0.id == id }
        }
        guard store.cameras.indices.contains(index) else { return nil }
        return store.cameras[index]
    }

    private func setCameraID(_ cameraID: UUID?, forSlot index: Int) {
        var ids = slotCameraIDs
        if ids.count < slotCount {
            ids.append(contentsOf: Array(repeating: "", count: slotCount - ids.count))
        }
        ids[index] = cameraID?.uuidString ?? ""
        slotCameraIDsValue = ids.joined(separator: ",")
    }

    private func refreshStreamGridAfterFullscreen() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            streamRefreshID = UUID()
        }
    }
}

private struct StreamSlotView: View {
    let slotNumber: Int
    let camera: CameraRecord?
    let cameras: [CameraRecord]
    let isPlaybackPaused: Bool
    let onSelect: (UUID?) -> Void
    let onOpen: (CameraRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Slot \(slotNumber)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu(camera?.name ?? "Select") {
                    Button("None") { onSelect(nil) }
                    ForEach(cameras) { camera in
                        Button(camera.name) { onSelect(camera.id) }
                    }
                }
            }
            if let camera {
                Button {
                    onOpen(camera)
                } label: {
                    StreamTileView(camera: camera, isPlaybackPaused: isPlaybackPaused)
                }
                .buttonStyle(.plain)
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.title.bold())
                            .foregroundStyle(AppTheme.accent)
                    }
            }
        }
    }
}

private struct StreamTileView: View {
    let camera: CameraRecord
    let isPlaybackPaused: Bool
    @StateObject private var playerController: RTSPPlayerController

    init(camera: CameraRecord, isPlaybackPaused: Bool) {
        self.camera = camera
        self.isPlaybackPaused = isPlaybackPaused
        _playerController = StateObject(wrappedValue: RTSPPlayerController(rtspURL: camera.manualRTSPURL(for: .main) ?? URL(string: "rtsp://127.0.0.1:554/11")!))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VLCVideoContainerView(controller: playerController)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(.black)
                .overlay(alignment: .topLeading) {
                    PlaybackStatusBadge(controller: playerController)
                        .padding(8)
                }
            HStack {
                BrandLogoView(type: camera.cameraType, size: 42)
                VStack(alignment: .leading) {
                    Text(camera.name)
                        .font(.headline)
                    Text("\(camera.cameraType.title) • \(camera.trimmedHost)")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task {
            if !isPlaybackPaused {
                resumePreviewPlayback()
            }
        }
        .onChange(of: isPlaybackPaused) { paused in
            if paused {
                playerController.stop()
            } else {
                resumePreviewPlayback()
            }
        }
        .onDisappear { playerController.stop() }
    }

    private func resumePreviewPlayback() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !isPlaybackPaused else { return }
            playerController.reload()
        }
    }
}

private struct FullscreenStreamView: View {
    let camera: CameraRecord
    let stream: StreamType
    let onClose: () -> Void
    @StateObject private var playerController: RTSPPlayerController

    init(camera: CameraRecord, stream: StreamType, onClose: @escaping () -> Void) {
        self.camera = camera
        self.stream = stream
        self.onClose = onClose
        _playerController = StateObject(wrappedValue: RTSPPlayerController(rtspURL: camera.manualRTSPURL(for: stream) ?? URL(string: "rtsp://127.0.0.1:554/11")!))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            VLCVideoContainerView(controller: playerController)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .overlay(alignment: .topLeading) {
                    PlaybackStatusBadge(controller: playerController)
                        .padding()
                }
            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { playerController.play() }
        .onDisappear { playerController.stop() }
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(CircleButtonStyle())
        .padding()
    }
}

private struct StreamWallFullscreenView: View {
    let cameras: [CameraRecord?]
    let rows: Int
    let columns: Int
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            VStack(spacing: 2) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<columns, id: \.self) { column in
                            let index = row * columns + column
                            if cameras.indices.contains(index), let camera = cameras[index] {
                                StreamOnlyTileView(camera: camera, slotIndex: index)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                Color.black
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(CircleButtonStyle())
        .padding()
    }
}

private struct StreamOnlyTileView: View {
    let camera: CameraRecord
    let slotIndex: Int
    @StateObject private var playerController: RTSPPlayerController

    init(camera: CameraRecord, slotIndex: Int = 0) {
        self.camera = camera
        self.slotIndex = slotIndex
        _playerController = StateObject(wrappedValue: RTSPPlayerController(rtspURL: camera.manualRTSPURL(for: .main) ?? URL(string: "rtsp://127.0.0.1:554/11")!))
    }

    var body: some View {
        VLCVideoContainerView(controller: playerController)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .overlay(alignment: .topLeading) {
                PlaybackStatusBadge(controller: playerController)
                    .padding(8)
            }
            .task(id: "\(slotIndex)-\(camera.id.uuidString)") {
                let delay = UInt64(slotIndex) * 220_000_000
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                if !Task.isCancelled {
                    playerController.play()
                }
            }
            .onDisappear { playerController.stop() }
    }
}

private struct PlaybackStatusBadge: View {
    @ObservedObject var controller: RTSPPlayerController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(controller.statusText)
                .font(.caption.weight(.semibold))
            if let errorMessage = controller.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
private final class FullscreenWindowPresenter {
    private var window: NSWindow?

    func present<Content: View>(@ViewBuilder content: () -> Content) {
        close()

        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        window.backgroundColor = .black
        window.isOpaque = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentViewController = NSHostingController(rootView: content())
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.contentViewController = nil
        window?.close()
        window = nil
    }
}

private struct StreamSegmentedControl: View {
    @Binding var selection: StreamType

    var body: some View {
        HStack(spacing: 6) {
            Text("Stream")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(StreamType.allCases) { stream in
                Button {
                    selection = stream
                } label: {
                    Text(stream.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(selection == stream ? .white : AppTheme.ink.opacity(0.72))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .frame(minWidth: 126)
                        .background(
                            selection == stream ? AppTheme.accent : Color.white.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.black.opacity(selection == stream ? 0 : 0.08), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.white.opacity(0.86), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 14, x: 0, y: 8)
    }
}

private struct ControlButton: View {
    let icon: String
    let isActive: Bool
    let isBusy: Bool
    let isUnavailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(isActive ? .white : AppTheme.controlInk)
                .frame(width: 92, height: 92)
                .background(isActive ? AppTheme.accent : AppTheme.controlIdle, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isUnavailable)
        .opacity((isBusy && !isActive) || isUnavailable ? 0.45 : 1)
    }
}

private struct ZoomControlButton: View {
    let isZoomInActive: Bool
    let isZoomOutActive: Bool
    let isBusy: Bool
    let isUnavailable: Bool
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onZoomIn) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isZoomInActive ? .white : AppTheme.controlInk)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(isZoomInActive ? AppTheme.accent : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            Text("Zoom")
                .font(.headline)
                .foregroundStyle(AppTheme.controlInk)
            Button(action: onZoomOut) {
                Image(systemName: "minus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(isZoomOutActive ? .white : AppTheme.controlInk)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(isZoomOutActive ? AppTheme.accent : Color.clear)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 106, height: 106)
        .padding(10)
        .background(AppTheme.controlIdle, in: Circle())
        .disabled(isBusy || isUnavailable)
        .opacity((isBusy && !isZoomInActive && !isZoomOutActive) || isUnavailable ? 0.45 : 1)
    }
}

private struct BrandLogoView: View {
    let type: CameraType
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.95, green: 0.97, blue: 1.0))
            if let assetName = type.logoAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else {
                Image(systemName: "camera.aperture")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.blue)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct BrandSummaryCard: View {
    let type: CameraType

    var body: some View {
        HStack(spacing: 16) {
            BrandLogoView(type: type, size: 78)
            VStack(alignment: .leading, spacing: 7) {
                Text(type.title)
                    .font(.title.bold())
                    .foregroundStyle(AppTheme.ink)
                Text(type.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct MacFormCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.headline.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.leading, 18)
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.82), in: Capsule())
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .headline : .title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 8 : 12)
            .background(AppTheme.accent.opacity(configuration.isPressed ? 0.76 : 1), in: Capsule())
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .headline : .title3.weight(.semibold))
            .foregroundStyle(AppTheme.accent)
            .padding(.horizontal, compact ? 14 : 18)
            .padding(.vertical, compact ? 8 : 12)
            .background(Color.white.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
    }
}

private struct CircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 46, height: 46)
            .background(Color.black.opacity(configuration.isPressed ? 0.45 : 0.62), in: Circle())
    }
}

private enum AppTheme {
    static let accent = Color.blue
    static let ink = Color(red: 0.08, green: 0.10, blue: 0.14)
    static let controlInk = Color(red: 0.13, green: 0.16, blue: 0.22)
    static let controlIdle = Color(red: 0.78, green: 0.81, blue: 0.88)
    static let pageBackground = LinearGradient(
        colors: [Color(red: 0.94, green: 0.97, blue: 1.0), Color(red: 0.99, green: 0.99, blue: 1.0)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
