// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud Play UI - mirrors Android CloudPlayFragment.kt + CloudPlayViewModel.kt

import SwiftUI
import os.log

private let cloudUILog = OSLog(subsystem: "com.pylux.stream", category: "CloudPlayUI")

// MARK: - ViewModel (matches Android CloudPlayViewModel.kt)

@MainActor
final class CloudPlayViewModel: ObservableObject {
    static let tagFilterCategories = [
        CloudCategory.owned,
        CloudCategory.streamable,
        CloudCategory.purchaseable
    ]
    static let tagFilterLabels = ["Owned", "Streamable", "Store"]

    enum SortOrder: Int, CaseIterable {
        case defaultOrder = 0  // Playable First
        case nameAsc = 1       // Name: A -> Z
        case nameDesc = 2      // Name: Z -> A

        var label: String {
            switch self {
            case .defaultOrder: return "Playable First"
            case .nameAsc:      return "Name: A \u{2192} Z"
            case .nameDesc:     return "Name: Z \u{2192} A"
            }
        }
    }

    @Published var games: [CloudGame] = []
    @Published var loading = false
    @Published var refreshing = false
    @Published var error: String?
    @Published var warning: String?
    @Published var fallbackRegion: String = SecureStore.shared.cloudResolvedStoreCountry
    @Published var catalogIsForeign: Bool = SecureStore.shared.isCloudCatalogIsForeign
    @Published var searchQuery = ""
    @Published var sortOrder: SortOrder = .defaultOrder
    @Published var showFavoritesOnly = false
    @Published var activeTagFilters: Set<String> = SecureStore.shared.cloudTagFilters
    @Published var favoriteIds: Set<String> = CloudFavoritesManager.getFavorites()

    // Allocation state
    @Published var allocating = false
    @Published var allocationProgress = ""
    @Published var allocationError: String?
    @Published var showPingTooHighDialog = false
    @Published var cloudSession: CloudStreamSession?

    private let catalogService = CloudCatalogService()
    private let streamingBackend = CloudStreamingBackend()

    func loadPersistedSortOrder() {
        sortOrder = SortOrder(rawValue: SecureStore.shared.cloudSortState) ?? .defaultOrder
    }

    func persistSortOrder() {
        SecureStore.shared.cloudSortState = sortOrder.rawValue
    }

    var filterSummary: String {
        if activeTagFilters.isEmpty { return "All games" }
        return Self.tagFilterCategories
            .filter { activeTagFilters.contains($0) }
            .map { tag in
                Self.tagFilterLabels[Self.tagFilterCategories.firstIndex(of: tag) ?? 0]
            }
            .joined(separator: " · ")
    }

    var filteredGames: [CloudGame] {
        var result = games

        if !activeTagFilters.isEmpty {
            result = result.filter { activeTagFilters.contains($0.category) }
        }

        if showFavoritesOnly {
            result = result.filter { favoriteIds.contains($0.id) }
        }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
            }
        }

        switch sortOrder {
        case .defaultOrder:
            result.sort {
                let p0 = $0.category != CloudCategory.purchaseable
                let p1 = $1.category != CloudCategory.purchaseable
                if p0 != p1 { return p0 && !p1 }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nameAsc:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
        return result
    }

    func isTagFilterActive(_ tag: String) -> Bool {
        activeTagFilters.isEmpty || activeTagFilters.contains(tag)
    }

    func toggleTagFilter(_ tag: String) {
        var next = activeTagFilters
        if activeTagFilters.isEmpty {
            next = Set(Self.tagFilterCategories.filter { $0 != tag })
        } else if next.contains(tag) {
            next.remove(tag)
        } else {
            next.insert(tag)
        }
        normalizeAndPersistTagFilters(next)
    }

    func setTagFilters(_ tags: Set<String>) {
        normalizeAndPersistTagFilters(tags)
    }

    private func normalizeAndPersistTagFilters(_ tags: Set<String>) {
        let allTags = Set(Self.tagFilterCategories)
        activeTagFilters = (tags.isEmpty || tags == allTags) ? [] : tags
        SecureStore.shared.cloudTagFilters = activeTagFilters
    }

    func toggleFavorite(for game: CloudGame) {
        _ = CloudFavoritesManager.toggleFavorite(game.id)
        favoriteIds = CloudFavoritesManager.getFavorites()
    }

    func loadGames(npssoToken: String) {
        loading = true
        error = nil
        warning = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let loadedGames = self.catalogService.fetchUnifiedCatalog(npssoToken: npssoToken)
            await MainActor.run {
                self.applyLoadedGames(loadedGames)
            }
        }
    }

    private func applyLoadedGames(_ loadedGames: [CloudGame]) {
        games = loadedGames
        loading = false
        fallbackRegion = SecureStore.shared.cloudResolvedStoreCountry
        catalogIsForeign = SecureStore.shared.isCloudCatalogIsForeign
        if let fetchError = catalogService.lastLibraryFetchError {
            error = fetchError
        } else if loadedGames.isEmpty {
            error = "No cloud games found. Check your connection."
        }
        if let catalogWarning = catalogService.lastCatalogFetchWarning {
            warning = catalogWarning
        } else if !CloudLocaleSettings.isConfigured {
            warning = CloudLocaleSettings.unconfiguredWarning()
        }
    }

    func refreshGames(npssoToken: String) {
        guard !refreshing else { return }
        refreshing = true
        loading = true
        error = nil
        warning = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                Task { @MainActor in
                    self?.loading = false
                    self?.refreshing = false
                }
            }
            guard let self = self else { return }
            let loadedGames = self.catalogService.fetchUnifiedCatalog(
                npssoToken: npssoToken, forceRefresh: true
            )
            await MainActor.run {
                self.applyLoadedGames(loadedGames)
            }
        }
    }

    func startCloudStreaming(game: CloudGame, npssoToken: String) {
        allocating = true
        allocationProgress = "Starting..."
        allocationError = nil
        showPingTooHighDialog = false
        cloudSession = nil

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Stream routing is precomputed by libchiaki: streamServiceType picks the endpoint
            // (psnow/Kamaji vs pscloud/cronos) and streamIdentifier is the exact id to launch.
            let gameIdentifier = game.streamIdentifier
            let gameName = game.name
            let serviceType = game.streamServiceType
            var cancelled = false

            do {
                let session = try self.streamingBackend.startCompleteCloudSession(
                    serviceType: serviceType,
                    gameIdentifier: gameIdentifier,
                    gameName: gameName,
                    npssoToken: npssoToken,
                    onProgress: { msg in
                        Task { @MainActor in
                            self.allocationProgress = msg
                        }
                    },
                    isCancelled: { cancelled }
                )

                await MainActor.run {
                    self.allocating = false
                    self.cloudSession = session
                }
            } catch let error as PsPlusSubscriptionError {
                await MainActor.run {
                    self.allocating = false
                    self.allocationError = error.message
                }
            } catch is PingTimeoutError {
                await MainActor.run {
                    self.allocating = false
                    self.showPingTooHighDialog = true
                }
            } catch {
                await MainActor.run {
                    self.allocating = false
                    self.allocationError = error.localizedDescription
                }
            }
        }
    }

    func cancelAllocation() {
        allocating = false
    }
}

// MARK: - Dark color constants
private let cloudBgColor = Color(red: 0.06, green: 0.06, blue: 0.09)
private let cloudCardBg = Color(red: 0.10, green: 0.10, blue: 0.14)
private let cloudSubtabBg = Color(red: 0.08, green: 0.08, blue: 0.12)

// MARK: - Cloud Play View (matches Android CloudPlayFragment)

struct CloudPlayView: View {
    @Environment(\.openURL) private var openURL
    @StateObject private var viewModel = CloudPlayViewModel()
    @State private var showSearch = false
    @State private var selectedGame: CloudGame?
    @State private var showStreamView = false
    @State private var addToLibraryGame: CloudGame?
    @State private var showMissingConceptAlert = false
    @State private var availableWidth: CGFloat = 390

    let npssoToken: String
    let onSignInTapped: () -> Void

    /// Compute grid columns from actual available width
    private var columns: [GridItem] {
        // Target: ~160-180pt per column in portrait, ~140-160pt in landscape
        let colWidth: CGFloat = availableWidth > 500 ? 140 : 160
        let count = max(2, Int(availableWidth / colWidth))
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    var body: some View {
        GeometryReader { outerGeo in
            ZStack {
                cloudBgColor.ignoresSafeArea()

                // Show sign-in prompt if not logged in
                if npssoToken.isEmpty {
                    signInPrompt
                } else {
                    VStack(spacing: 0) {
                        cloudSubTabs

                        if viewModel.catalogIsForeign {
                            Text("Cloud catalog isn't fully available in your region; some titles may not stream.")
                                .font(.caption)
                                .foregroundColor(.black.opacity(0.85))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(Color(red: 1.0, green: 0.92, blue: 0.23))
                        }

                        if let warning = viewModel.warning {
                            Text(warning)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }

                        // Search bar (when visible)
                        if showSearch {
                            searchBar
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        // Content
                        ZStack {
                            if viewModel.loading && viewModel.games.isEmpty {
                                loadingView
                            } else if let error = viewModel.error, viewModel.games.isEmpty {
                                errorView(error)
                            } else if viewModel.filteredGames.isEmpty {
                                emptyView
                            } else {
                                gameGrid
                            }
                        }
                    }
                }
            }
            .onAppear { availableWidth = outerGeo.size.width }
            .onChange(of: outerGeo.size.width) { newWidth in
                availableWidth = newWidth
            }
        }
        .onAppear {
            viewModel.loadPersistedSortOrder()
            if viewModel.games.isEmpty && !npssoToken.isEmpty {
                viewModel.loadGames(npssoToken: npssoToken)
            }
        }
        // Allocation progress overlay
        .overlay {
            if viewModel.allocating {
                allocationOverlay
            }
        }
        // Allocation error alert
        .alert("Cloud Streaming Error", isPresented: .init(
            get: { viewModel.allocationError != nil },
            set: { if !$0 { viewModel.allocationError = nil } }
        )) {
            Button("OK") { viewModel.allocationError = nil }
        } message: {
            Text(viewModel.allocationError ?? "")
        }
        .alert(PingTimeoutError.alertTitle, isPresented: $viewModel.showPingTooHighDialog) {
            Button("OK") { viewModel.showPingTooHighDialog = false }
        } message: {
            Text(PingTimeoutError.alertMessage)
        }
        .alert("Add to Library", isPresented: Binding(
            get: { addToLibraryGame != nil },
            set: { if !$0 { addToLibraryGame = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                addToLibraryGame = nil
            }
            Button("Add Now") {
                if let g = addToLibraryGame {
                    let trimmed = g.conceptUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: trimmed) {
                        openURL(url)
                    }
                }
                addToLibraryGame = nil
            }
        } message: {
            Text("This game needs to be added to your library before you can stream it.\n\nAfter adding the game, pull down to refresh the game list.")
        }
        .alert("Add to Library", isPresented: $showMissingConceptAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Unable to add this game to your library. The game URL is not available.")
        }
        // Stream view
        .fullScreenCover(isPresented: $showStreamView) {
            if let session = viewModel.cloudSession {
                CloudStreamWrapperView(cloudSession: session, npssoToken: npssoToken)
            }
        }
        .onChange(of: viewModel.cloudSession != nil) { hasSession in
            if hasSession { showStreamView = true }
        }
    }

    // MARK: - Sub-tabs

    private var cloudSubTabs: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(Array(CloudPlayViewModel.tagFilterCategories.enumerated()), id: \.offset) { index, tag in
                    Button {
                        viewModel.toggleTagFilter(tag)
                    } label: {
                        HStack {
                            Text(CloudPlayViewModel.tagFilterLabels[index])
                            if viewModel.isTagFilterActive(tag) {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Divider()
                Button("Show all") {
                    viewModel.setTagFilters([])
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                    Text(viewModel.filterSummary)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundColor(viewModel.activeTagFilters.isEmpty ? .white.opacity(0.45) : .blue.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                // Search toggle (left of favorites, matches Android header order)
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showSearch.toggle() }
                    if !showSearch { viewModel.searchQuery = "" }
                } label: {
                    Image(systemName: showSearch ? "magnifyingglass.circle.fill" : "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(showSearch ? .white : .white.opacity(0.45))
                        .frame(width: 28, height: 28)
                }

                // Favorites filter
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.showFavoritesOnly.toggle()
                    }
                } label: {
                    Image(systemName: viewModel.showFavoritesOnly ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundColor(viewModel.showFavoritesOnly ? .yellow : .white.opacity(0.45))
                        .frame(width: 28, height: 28)
                }

                // Sort menu
                Menu {
                    ForEach(CloudPlayViewModel.SortOrder.allCases, id: \.self) { order in
                        Button {
                            viewModel.sortOrder = order
                            viewModel.persistSortOrder()
                        } label: {
                            HStack {
                                Text(order.label)
                                if viewModel.sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .frame(width: 28, height: 28)
                }

                // Refresh
                Button {
                    viewModel.refreshGames(npssoToken: npssoToken)
                } label: {
                    Group {
                        if viewModel.refreshing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.7)))
                                .scaleEffect(0.65)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: 28, height: 28)
                }
                .disabled(viewModel.refreshing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(cloudSubtabBg)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.4))
            TextField("Search games...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .foregroundColor(.white)
                .autocorrectionDisabled()
            if !viewModel.searchQuery.isEmpty {
                Button { viewModel.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handleGameTap(_ game: CloudGame) {
        if game.category == CloudCategory.purchaseable {
            let url = game.conceptUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty {
                showMissingConceptAlert = true
            } else {
                addToLibraryGame = game
            }
            return
        }
        selectedGame = game
        viewModel.startCloudStreaming(game: game, npssoToken: npssoToken)
    }

    // MARK: - Game Grid

    private var gameGrid: some View {
        ScrollView {
            // Status bar: game count + active sort/filter
            HStack(spacing: 6) {
                Text("\(viewModel.filteredGames.count) games")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))

                if viewModel.showFavoritesOnly {
                    Text("Favorites")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.yellow.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.15)))
                }

                if viewModel.activeTagFilters.count > 0 && viewModel.activeTagFilters.count < CloudPlayViewModel.tagFilterCategories.count {
                    Text(viewModel.filterSummary)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.blue.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.15)))
                }

                if viewModel.sortOrder != .defaultOrder {
                    Text(viewModel.sortOrder.label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(viewModel.filteredGames) { game in
                    CloudGameCardView(
                        game: game,
                        isFavorite: viewModel.favoriteIds.contains(game.id),
                        onTap: {
                            handleGameTap(game)
                        },
                        onFavoriteToggle: {
                            viewModel.toggleFavorite(for: game)
                        }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 20)
        }
        .refreshable {
            viewModel.refreshGames(npssoToken: npssoToken)
        }
    }

    // MARK: - Sign In Prompt

    private var signInPrompt: some View {
        VStack(spacing: 24) {
            Image(systemName: "cloud.fill")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.3))
            
            VStack(spacing: 12) {
                Text("Sign In Required")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Text("Sign in to your account to access Cloud Play")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            Button {
                onSignInTapped()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                    Text("Sign In")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.2)
                .tint(.white.opacity(0.6))
            Text("Loading games...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty / Error

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.15))
            Text("No games found")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            if !viewModel.searchQuery.isEmpty {
                Text("Try a different search term")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.orange.opacity(0.6))
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                viewModel.loadGames(npssoToken: npssoToken)
            } label: {
                Text("Retry")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Allocation Overlay

    /// Portrait: vertically centered stack. Landscape / short height: same pattern; Spacers collapse so ScrollView
    /// scrolls instead of clipping. Avoid horizontal padding from `safeAreaInsets.leading/trailing` — on iPhone
    /// landscape those insets are huge and crush the column.
    private var allocationOverlay: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let thumbW: CGFloat = landscape ? 88 : 100
            let thumbH: CGFloat = landscape ? 114 : 130
            let titleSize: CGFloat = landscape ? 16 : 18
            let bodySpacing: CGFloat = landscape ? 10 : 14
            let hPad: CGFloat = landscape ? 28 : 24
            let safeTop = geo.safeAreaInsets.top + (landscape ? 8 : 12)
            let safeBottom = geo.safeAreaInsets.bottom + (landscape ? 8 : 16)

            ZStack {
                Color.black.opacity(0.88).ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)

                        VStack(spacing: bodySpacing) {
                            if let game = selectedGame {
                                HStack {
                                    Spacer(minLength: 0)
                                    allocationCoverThumbnail(width: thumbW, height: thumbH)
                                    Spacer(minLength: 0)
                                }

                                Text(game.name)
                                    .font(.system(size: titleSize, weight: .bold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 20)

                                HStack {
                                    Spacer(minLength: 0)
                                    Text(game.platform.replacingOccurrences(of: "ps", with: "").uppercased())
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white.opacity(0.5))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Capsule().fill(Color.white.opacity(0.1)))
                                    Spacer(minLength: 0)
                                }
                            }

                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(landscape ? 1.1 : 1.25)
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)

                            Text(viewModel.allocationProgress)
                                .font(.system(size: landscape ? 12 : 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.65))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 20)

                            Button {
                                viewModel.cancelAllocation()
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white.opacity(0.45))
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 8)
                                    .background(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                            .padding(.bottom, 4)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, hPad)

                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: max(0, geo.size.height - safeTop - safeBottom))
                    .padding(.top, safeTop)
                    .padding(.bottom, safeBottom)
                }
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private func allocationCoverThumbnail(width: CGFloat, height: CGFloat) -> some View {
        if let game = selectedGame {
            CachedAsyncImage(url: URL(string: game.imageUrl)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .cornerRadius(10)
                default:
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.1))
                        .frame(width: width, height: height)
                }
            }
            .id(game.imageUrl)
        }
    }
}

// MARK: - Game Card View

struct CloudGameCardView: View {
    let game: CloudGame
    let isFavorite: Bool
    let onTap: () -> Void
    let onFavoriteToggle: () -> Void

    @State private var starTapped = false  // debounce visual

    private var displayCategory: String { game.category }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Layer 1: Cover image (purely visual)
                coverImage(width: geo.size.width, height: geo.size.height)

                // Layer 2: Bottom gradient with text (purely visual)
                VStack {
                    Spacer()
                    bottomOverlay
                }

                // Layer 3: Platform "console coin" pinned to the bottom-right corner,
                // mirroring the star in the top-right. Its own layer (not in the name
                // row) so it never competes with the title for horizontal space.
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        platformCoin
                            .padding(.trailing, 8)
                            .padding(.bottom, 8)
                    }
                }

                // Layer 4: Top overlays - category badge (left) + star (right)
                VStack {
                    HStack(alignment: .top, spacing: 0) {
                        categoryBadge
                            .padding(.top, 6)
                            .padding(.leading, 6)

                        Spacer()

                        // Top-right: Star button
                        Button {
                            onFavoriteToggle()
                            withAnimation(.easeInOut(duration: 0.15)) { starTapped = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { starTapped = false }
                            }
                        } label: {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(isFavorite ? .yellow : .white.opacity(0.6))
                                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                                .scaleEffect(starTapped ? 1.3 : 1.0)
                        }
                        .buttonStyle(StarButtonStyle())
                    }
                    Spacer()
                }

                // Layer 5: Full-card invisible tap target for launching (behind star button)
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
                    .zIndex(-1)
            }
        }
        .aspectRatio(1.0, contentMode: .fit)  // Square cards - matches actual game cover image dimensions
        .background(cloudCardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var categoryBadge: some View {
        let (label, color): (String, Color) = {
            switch displayCategory {
            case CloudCategory.owned:
                return ("Owned", Color(red: 0.30, green: 0.69, blue: 0.31))       // #4CAF50
            case CloudCategory.streamable:
                return ("Streamable", Color(red: 0.13, green: 0.59, blue: 0.95))    // #2196F3
            default:
                return ("Add Game", Color(red: 1.0, green: 0.60, blue: 0.0))        // #FF9800
            }
        }()
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.85))
            )
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }

    @ViewBuilder
    private func coverImage(width: CGFloat, height: CGFloat) -> some View {
        CachedAsyncImage(url: URL(string: game.imageUrl)) { phase in
            switch phase {
            case .success(let image):
                // Use .fit so the full image is visible (no awkward cropping),
                // with cloudCardBg behind for any letterbox areas
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: width, height: height)
            case .failure:
                Rectangle()
                    .fill(cloudCardBg)
                    .overlay {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.15))
                    }
            default:
                Rectangle()
                    .fill(cloudCardBg)
                    .overlay {
                        ProgressView()
                            .tint(.white.opacity(0.3))
                    }
            }
        }
        .allowsHitTesting(false)
    }

    private var bottomOverlay: some View {
        // Name spans the full width; the platform coin lives in its own bottom-right
        // corner layer, so we just reserve a little trailing inset here to keep a long
        // 2-line title from running under the coin.
        HStack(spacing: 0) {
            Text(game.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 34)
        .padding(.bottom, 8)
        .padding(.top, 40)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Color.black.opacity(0.5), location: 0.3),
                    .init(color: Color.black.opacity(0.85), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }

    /// Neon platform tag pinned to the bottom-right corner. A flat, translucent
    /// rounded-rect with a glowing platform-colored outline + text glow, so it reads
    /// as part of the app's electric-blue theme instead of a floating coin.
    private var platformCoin: some View {
        Text(platformLabel)
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundColor(.white)
            .shadow(color: platformColor.opacity(0.95), radius: 3.5) // inner text glow
            .frame(minWidth: 10)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.black.opacity(0.40))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(platformColor.opacity(0.95), lineWidth: 1)
                    )
            )
            .shadow(color: platformColor.opacity(0.75), radius: 5)   // outer neon glow
            .allowsHitTesting(false)
    }

    /// Platform label without "PS" prefix to avoid trademark
    private var platformLabel: String {
        switch game.platform {
        case "ps5":  return "5"
        case "ps4":  return "4"
        case "ps3":  return "3"
        default:     return game.platform.uppercased()
        }
    }

    private var platformColor: Color {
        switch game.platform {
        case "ps5":  return Color(red: 0.30, green: 0.55, blue: 1.0)
        case "ps4":  return Color(red: 0.40, green: 0.45, blue: 0.95)
        case "ps3":  return Color(red: 0.65, green: 0.40, blue: 0.90)
        default:     return .gray
        }
    }
}

/// Custom button style that ensures the star button captures taps
private struct StarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
    }
}

// MARK: - Cloud Stream Wrapper (bridges CloudStreamSession to StreamView)

struct CloudStreamWrapperView: View {
    let cloudSession: CloudStreamSession
    let npssoToken: String
    @Environment(\.dismiss) private var dismiss

    private var cloudConnectInfo: StreamConnectInfo {
        let prefs = StreamPreferences.load()
        let cloudRes = cloudSession.serviceType == "pscloud"
            ? prefs.cloudResolutionDimensionsPscloud
            : prefs.cloudResolutionDimensionsPsnow
        let cloudBitrate = prefs.cloudBitrateKbps(for: cloudSession.serviceType)

        return StreamConnectInfo(
            host: cloudSession.serverIp,
            ps5: cloudSession.platform == "ps5",
            registKey: Data(count: 16),
            morning: Data(count: 16),
            videoWidth: UInt32(cloudRes.width),
            videoHeight: UInt32(cloudRes.height),
            videoMaxFps: 60,
            videoBitrate: UInt32(cloudBitrate),
            videoCodec: cloudSession.serviceType == "pscloud" ? 1 : 0,
            serviceType: cloudSession.serviceType == "pscloud" ? 2 : 1,
            cloudLaunchSpec: cloudSession.launchSpec,
            cloudHandshakeKey: cloudSession.handshakeKey,
            cloudSessionId: cloudSession.sessionId,
            cloudPort: UInt16(cloudSession.serverPort),
            cloudPsnWrapperType: UInt8(cloudSession.psnWrapperType),
            cloudMtuIn: UInt32(cloudSession.mtuIn),
            cloudMtuOut: UInt32(cloudSession.mtuOut),
            cloudRttUs: UInt64(cloudSession.rttMs) * 1000
        )
    }

    var body: some View {
        StreamView(connectInfo: cloudConnectInfo)
    }
}
