// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Thin wrapper over libchiaki's unified cloud catalog. ALL fetching, OAuth/session
// exchanges, dedup, ownership cross-reference and tagging happen once in the lib
// (chiaki/cloudcatalog.h, shared with Qt and Android). iOS supplies npsso/locale/
// cache dir and renders the returned contract verbatim — no client-side catalog logic.

import Foundation
import os.log

private let catalogLog = OSLog(subsystem: "com.pylux.stream", category: "CloudCatalog")

final class CloudCatalogService {

    private(set) var lastLibraryFetchError: String?
    private(set) var lastCatalogFetchWarning: String?

    /// Dir handed to the lib; the lib owns every file inside it (browse/library/unified caches).
    private static var cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud_catalog_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Unified cloud catalog: ONE merged, deduped, tagged list across PS3/PS4 (PS Now) and
    /// PS5 (cloud). Blocking — call from a background queue. The lib serves an on-disk cache
    /// hit with no network I/O; `forceRefresh` bypasses it.
    func fetchUnifiedCatalog(npssoToken: String, forceRefresh: Bool = false) -> [CloudGame] {
        lastLibraryFetchError = nil
        lastCatalogFetchWarning = nil

        var errorMessage: NSString?
        let json = PyluxCloudCatalog.fetchUnifiedJSON(
            withNpsso: npssoToken.isEmpty ? nil : npssoToken,
            locale: CloudLocaleSettings.stored,
            cacheDir: Self.cacheDir.path,
            forceRefresh: forceRefresh,
            errorMessage: &errorMessage
        )

        guard let json else {
            lastLibraryFetchError = (errorMessage as String?) ?? "Failed to fetch cloud catalog. Check your connection."
            os_log(.error, log: catalogLog, "Unified catalog fetch failed: %{public}s", lastLibraryFetchError ?? "")
            return []
        }

        return parseUnifiedCatalog(json)
    }

    private func parseUnifiedCatalog(_ json: String) -> [CloudGame] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastLibraryFetchError = "Failed to parse cloud catalog."
            return []
        }

        // The lib resolves the working store locale and region group; reflect them back so the
        // streaming path (which reads CloudLocaleSettings.stored) and the region banner agree.
        if let settled = root["settledLocale"] as? String {
            CloudLocaleSettings.noteSettledLocale(settled)
        }
        SecureStore.shared.cloudResolvedStoreCountry = root["fallbackRegion"] as? String ?? ""
        SecureStore.shared.cloudResolvedStoreLang = root["resolvedStoreLang"] as? String ?? ""
        if let nativeMode = root["nativeMode"] as? Bool {
            SecureStore.shared.cloudCatalogNativeMode = nativeMode
        }

        if let warning = root["warning"] as? String, !warning.isEmpty {
            lastCatalogFetchWarning = warning
        }

        let gamesArr = root["games"] as? [[String: Any]] ?? []
        let games = gamesArr.compactMap { CloudGame(contract: $0) }
        os_log(.info, log: catalogLog, "Unified catalog: %d games (%d owned)",
               games.count, games.filter { $0.isOwned }.count)
        if games.isEmpty && lastLibraryFetchError == nil {
            lastLibraryFetchError = "No cloud games found. Check your connection."
        }
        return games
    }
}

// MARK: - Favorites Manager (matches Android Preferences.kt favorite_games)

enum CloudFavoritesManager {

    static func getFavorites() -> Set<String> {
        SecureStore.shared.cloudFavorites
    }

    static func isFavorite(_ productId: String) -> Bool {
        SecureStore.shared.cloudFavorites.contains(productId)
    }

    static func addFavorite(_ productId: String) {
        var favs = SecureStore.shared.cloudFavorites
        favs.insert(productId)
        SecureStore.shared.cloudFavorites = favs
    }

    static func removeFavorite(_ productId: String) {
        var favs = SecureStore.shared.cloudFavorites
        favs.remove(productId)
        SecureStore.shared.cloudFavorites = favs
    }

    static func toggleFavorite(_ productId: String) -> Bool {
        if isFavorite(productId) {
            removeFavorite(productId)
            return false
        } else {
            addFavorite(productId)
            return true
        }
    }
}
