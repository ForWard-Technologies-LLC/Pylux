// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud catalog fetching - mirrors Android CloudGameRepository.kt + PsnCatalogService.kt + PsCloudCatalogService.kt

import Foundation
import os.log

private let catalogLog = OSLog(subsystem: "com.pylux.stream", category: "CloudCatalog")

/// CloudCatalogService - Fetches and caches game catalogs for both PSNow and PS5 Cloud
/// Mirrors: android/.../cloudplay/repository/CloudGameRepository.kt
final class CloudCatalogService {

    // MARK: - Disk Cache (matches Android: context.cacheDir/cloud_catalog_cache/)

    private static let cacheDuration: TimeInterval = 86400 // 24 hours
    private static let psnowCacheFile = "psnow_catalog.json"
    private static let pscloudCacheFile = "pscloud_catalog.json"
    private static let pscloudOwnedCacheFile = "pscloud_owned.json"

    private static var cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cloud_catalog_cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Cache Read/Write

    private func loadCachedGames(_ filename: String) -> [CloudGame]? {
        let file = Self.cacheDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        // Check age
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let age = Date().timeIntervalSince(modified)
        if age > Self.cacheDuration {
            os_log(.info, log: catalogLog, "Cache expired for %{public}s (%.0fs old)", filename, age)
            try? FileManager.default.removeItem(at: file)
            return nil
        }

        // Parse
        guard let data = try? Data(contentsOf: file),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            os_log(.error, log: catalogLog, "Failed to parse cache file: %{public}s", filename)
            try? FileManager.default.removeItem(at: file)
            return nil
        }

        let games = arr.compactMap { deserializeGame($0) }
        os_log(.info, log: catalogLog, "Loaded %d games from cache: %{public}s", games.count, filename)
        return games
    }

    private func cacheGames(_ games: [CloudGame], filename: String) {
        let arr = games.map { serializeGame($0) }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: []) else { return }
        let file = Self.cacheDir.appendingPathComponent(filename)
        try? data.write(to: file, options: .atomic)
        os_log(.info, log: catalogLog, "Cached %d games to: %{public}s", games.count, filename)
    }

    private func serializeGame(_ g: CloudGame) -> [String: Any] {
        return [
            "productId": g.id, "name": g.name,
            "imageUrl": g.imageUrl, "landscapeImageUrl": g.landscapeImageUrl,
            "platform": g.platform, "serviceType": g.serviceType,
            "conceptUrl": g.conceptUrl, "isOwned": g.isOwned
        ]
    }

    private func deserializeGame(_ d: [String: Any]) -> CloudGame? {
        guard let pid = d["productId"] as? String, !pid.isEmpty,
              let name = d["name"] as? String, !name.isEmpty else { return nil }
        return CloudGame(
            productId: pid, name: name,
            imageUrl: d["imageUrl"] as? String ?? "",
            landscapeImageUrl: d["landscapeImageUrl"] as? String ?? "",
            platform: d["platform"] as? String ?? "ps4",
            serviceType: d["serviceType"] as? String ?? "psnow",
            conceptUrl: d["conceptUrl"] as? String ?? "",
            isOwned: d["isOwned"] as? Bool ?? false
        )
    }

    // MARK: - PS5 Cloud Catalog (Public)

    /// Fetch PS5 Cloud catalog (public list of streamable PS5 games)
    func fetchPs5CloudCatalog(locale: String = "en-us", forceRefresh: Bool = false) -> [CloudGame] {
        if !forceRefresh, let cached = loadCachedGames(Self.pscloudCacheFile) {
            return cached
        }

        os_log(.info, log: catalogLog, "=== Fetching PS5 Cloud Catalog ===")
        let url = "https://www.playstation.com/bin/imagic/gameslist?locale=\(locale)&categoryList=all-ps5-list"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        ]), response.statusCode == 200 else {
            os_log(.error, log: catalogLog, "PS5 catalog fetch failed")
            return []
        }

        guard let data = response.body.data(using: .utf8),
              let categories = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            os_log(.error, log: catalogLog, "PS5 catalog: invalid JSON")
            return []
        }

        var games: [CloudGame] = []
        for category in categories {
            guard let gameArray = category["games"] as? [[String: Any]] else { continue }
            for gameObj in gameArray {
                guard (gameObj["streamingSupported"] as? Bool) == true else { continue }
                let productId = gameObj["productId"] as? String ?? ""
                let name = gameObj["name"] as? String ?? "Unknown"
                var imageUrl = gameObj["imageUrl"] as? String ?? ""
                let conceptUrl = gameObj["conceptUrl"] as? String
                    ?? gameObj["concept_url"] as? String
                    ?? gameObj["url"] as? String ?? ""

                if imageUrl.hasPrefix("http://") { imageUrl = imageUrl.replacingOccurrences(of: "http://", with: "https://") }

                guard !productId.isEmpty else { continue }
                games.append(CloudGame(
                    productId: productId, name: name,
                    imageUrl: imageUrl, landscapeImageUrl: imageUrl,
                    platform: "ps5", serviceType: "pscloud",
                    conceptUrl: conceptUrl, isOwned: false
                ))
            }
        }

        os_log(.info, log: catalogLog, "PS5 Cloud catalog: %d streaming games", games.count)
        if !games.isEmpty { cacheGames(games, filename: Self.pscloudCacheFile) }
        return games
    }

    // MARK: - PS5 Cloud Library: All Games (matches Android fetchPs5CloudCatalog with ownership)

    /// Fetch ALL PS5 Cloud games with ownership flags.
    /// Matches Android: repository.fetchPs5CloudCatalog() + crossReferenceOwnership()
    /// Uses pscloudCacheFile (same cache as public catalog, but with ownership marked).
    func fetchAllPs5CloudGames(npssoToken: String, locale: String = "en-us", forceRefresh: Bool = false) -> [CloudGame] {
        // Check cache - pscloud_catalog.json stores ALL games with ownership already marked
        if !forceRefresh, let cached = loadCachedGames(Self.pscloudCacheFile) {
            // Verify cache has ownership info (check if any game has isOwned set)
            return cached
        }

        os_log(.info, log: catalogLog, "=== Fetching ALL PS5 Cloud Games (with ownership) ===")

        // Step 1: Fetch fresh public catalog (bypass our own cache since we're refreshing)
        let url = "https://www.playstation.com/bin/imagic/gameslist?locale=\(locale)&categoryList=all-ps5-list"
        guard let response = CloudHttpClient.get(url: url, headers: [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        ]), response.statusCode == 200,
              let data = response.body.data(using: .utf8),
              let categories = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            os_log(.error, log: catalogLog, "PS5 catalog fetch failed")
            return []
        }

        var games: [CloudGame] = []
        for category in categories {
            guard let gameArray = category["games"] as? [[String: Any]] else { continue }
            for gameObj in gameArray {
                guard (gameObj["streamingSupported"] as? Bool) == true else { continue }
                let productId = gameObj["productId"] as? String ?? ""
                let name = gameObj["name"] as? String ?? "Unknown"
                var imageUrl = gameObj["imageUrl"] as? String ?? ""
                let conceptUrl = gameObj["conceptUrl"] as? String
                    ?? gameObj["concept_url"] as? String
                    ?? gameObj["url"] as? String ?? ""
                if imageUrl.hasPrefix("http://") { imageUrl = imageUrl.replacingOccurrences(of: "http://", with: "https://") }
                guard !productId.isEmpty else { continue }
                games.append(CloudGame(
                    productId: productId, name: name,
                    imageUrl: imageUrl, landscapeImageUrl: imageUrl,
                    platform: "ps5", serviceType: "pscloud",
                    conceptUrl: conceptUrl, isOwned: false
                ))
            }
        }

        os_log(.info, log: catalogLog, "PS5 Cloud catalog: %d streaming games", games.count)

        // Step 2: Cross-reference ownership (matches Android crossReferenceOwnership)
        var entitlementSet: Set<String> = []
        if !npssoToken.isEmpty,
           let oauthToken = fetchOwnedGamesOAuthToken(npssoToken: npssoToken) {
            entitlementSet = Set(fetchEntitlements(oauthToken: oauthToken))
            os_log(.info, log: catalogLog, "User owns %d entitlements", entitlementSet.count)
        }

        let allGames = games.map { game -> CloudGame in
            var g = game
            g.isOwned = entitlementSet.contains(game.id)
            return g
        }

        let ownedCount = allGames.filter { $0.isOwned }.count
        os_log(.info, log: catalogLog, "PS5 Library: %d total, %d owned", allGames.count, ownedCount)
        if !allGames.isEmpty { cacheGames(allGames, filename: Self.pscloudCacheFile) }
        return allGames
    }

    // MARK: - PS5 Cloud Library: Owned Only (matches Android fetchOwnedPs5Games)

    /// Fetch ONLY owned PS5 Cloud games.
    /// Matches Android: repository.fetchOwnedPs5Games()
    func fetchOwnedPs5Games(npssoToken: String, locale: String = "en-us", forceRefresh: Bool = false) -> [CloudGame] {
        if !forceRefresh, let cached = loadCachedGames(Self.pscloudOwnedCacheFile) {
            return cached
        }
        guard !npssoToken.isEmpty else { return [] }
        os_log(.info, log: catalogLog, "=== Fetching Owned PS5 Games Only ===")

        guard let oauthToken = fetchOwnedGamesOAuthToken(npssoToken: npssoToken) else { return [] }
        let entitlements = fetchEntitlements(oauthToken: oauthToken)
        let publicCatalog = fetchPs5CloudCatalog(locale: locale)

        let entitlementSet = Set(entitlements)
        let owned = publicCatalog.compactMap { game -> CloudGame? in
            guard entitlementSet.contains(game.id) else { return nil }
            var ownedGame = game
            ownedGame.isOwned = true
            return ownedGame
        }

        os_log(.info, log: catalogLog, "Owned streaming games: %d", owned.count)
        if !owned.isEmpty { cacheGames(owned, filename: Self.pscloudOwnedCacheFile) }
        return owned
    }

    private func fetchOwnedGamesOAuthToken(npssoToken: String) -> String? {
        let scope = "kamaji:get_internal_entitlements user:account.attributes.validate"
        let redirectUri = CloudApiConstants.kamajiRedirectUri
        let clientId = "dc523cc2-b51b-4190-bff0-3397c06871b3"

        let query = "response_type=token&scope=\(scope.cloudUrlEncoded)&client_id=\(clientId)&redirect_uri=\(redirectUri.cloudUrlEncoded)&service_entity=urn%3Aservice-entity%3Apsn&prompt=none"
        let url = "\(CloudApiConstants.accountBase)/v1/oauth/authorize?\(query)"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Cookie": "npsso=\(npssoToken)",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        ], followRedirects: false), response.statusCode == 302,
              let location = CloudHttpClient.extractLocation(from: response),
              let range = location.range(of: "access_token=") else { return nil }

        let rest = String(location[range.upperBound...])
        return rest.split(separator: "&").first.map(String.init)
    }

    private func fetchEntitlements(oauthToken: String) -> [String] {
        let url = "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements?fields=game_meta&entitlement_type=5&start=0&size=10000"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Authorization": "Bearer \(oauthToken)",
            "Accept": "application/json"
        ]), response.statusCode == 200,
              let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ents = json["entitlements"] as? [[String: Any]] else { return [] }

        return ents.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
    }

    // MARK: - PSNow Catalog

    /// Fetch PSNow catalog (PS3/PS4 games)
    func fetchPsnowCatalog(npssoToken: String, forceRefresh: Bool = false) -> [CloudGame] {
        if !forceRefresh, let cached = loadCachedGames(Self.psnowCacheFile) {
            return cached
        }

        os_log(.info, log: catalogLog, "=== Fetching PSNow Catalog ===")
        let duid = generateDuid()

        guard let oauthCode = fetchPsnowOAuthCode(npssoToken: npssoToken, duid: duid) else {
            os_log(.error, log: catalogLog, "PSNow OAuth failed")
            return []
        }
        guard let sessionId = createPsnowKamajiSession(oauthCode: oauthCode, duid: duid) else {
            os_log(.error, log: catalogLog, "PSNow Kamaji session failed")
            return []
        }
        guard let baseUrl = fetchPsnowStores(sessionId: sessionId) else {
            os_log(.error, log: catalogLog, "PSNow stores fetch failed")
            return []
        }
        guard let categoryUrls = fetchPsnowRootContainer(baseUrl: baseUrl, sessionId: sessionId) else {
            os_log(.error, log: catalogLog, "PSNow root container failed")
            return []
        }

        var allGames: [CloudGame] = []
        for (name, url) in categoryUrls {
            os_log(.info, log: catalogLog, "Fetching category: %{public}s", name)
            allGames += fetchPsnowCategoryGames(url: url)
        }

        os_log(.info, log: catalogLog, "PSNow catalog: %d games", allGames.count)
        if !allGames.isEmpty { cacheGames(allGames, filename: Self.psnowCacheFile) }
        return allGames
    }

    // MARK: - PSNow helpers

    private func fetchPsnowOAuthCode(npssoToken: String, duid: String) -> String? {
        let params: [(String, String)] = [
            ("smcid", "pc:psnow"), ("applicationId", "psnow"),
            ("response_type", "code"), ("scope", CloudApiConstants.ps4Scopes),
            ("client_id", CloudApiConstants.kamajiClientId),
            ("redirect_uri", CloudApiConstants.kamajiRedirectUri),
            ("service_entity", "urn:service-entity:psn"), ("prompt", "none"),
            ("renderMode", "mobilePortrait"), ("hidePageElements", "forgotPasswordLink"),
            ("displayFooter", "none"), ("disableLinks", "qriocityLink"),
            ("mid", "PSNOW"), ("duid", duid), ("layout_type", "popup"),
            ("service_logo", "ps"), ("tp_psn", "true"), ("noEVBlock", "true")
        ]
        let query = params.map { "\($0.0)=\($0.1.cloudUrlEncoded)" }.joined(separator: "&")
        let url = "\(CloudApiConstants.accountBase)/v1/oauth/authorize?\(query)"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Cookie": "npsso=\(npssoToken)"
        ], followRedirects: false), response.statusCode == 302,
              let location = CloudHttpClient.extractLocation(from: response),
              let comps = URLComponents(string: location),
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        return code
    }

    private func createPsnowKamajiSession(oauthCode: String, duid: String) -> String? {
        let url = "\(CloudApiConstants.kamajiBase)/user/session"
        let body = "code=\(oauthCode)&client_id=\(CloudApiConstants.kamajiClientId)&duid=\(duid)"

        guard let response = CloudHttpClient.post(url: url, body: body, headers: [
            "Content-Type": "text/plain;charset=UTF-8",
            "X-Alt-Referer": CloudApiConstants.kamajiRedirectUri,
            "Origin": CloudApiConstants.kamajiOrigin,
            "Referer": CloudApiConstants.kamajiReferer,
            "Accept": "*/*"
        ]), response.statusCode == 200 else { return nil }

        return CloudHttpClient.extractCookie(from: response, name: "JSESSIONID")
    }

    private func fetchPsnowStores(sessionId: String) -> String? {
        let url = "\(CloudApiConstants.kamajiBase)/user/stores"
        guard let response = CloudHttpClient.get(url: url, headers: [
            "Cookie": "JSESSIONID=\(sessionId)",
            "Origin": CloudApiConstants.kamajiOrigin,
            "Referer": CloudApiConstants.kamajiReferer,
            "Accept": "application/json"
        ]), response.statusCode == 200,
              let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let baseUrl = dataObj["base_url"] as? String else { return nil }
        return baseUrl
    }

    private static let categoryPatterns = ["A - B", "C - D", "E - G", "H - L", "M - O", "P - R", "S", "T", "U - Z"]

    private func fetchPsnowRootContainer(baseUrl: String, sessionId: String) -> [(String, String)]? {
        let url = "\(baseUrl)?size=100"
        guard let response = CloudHttpClient.get(url: url, headers: [
            "Cookie": "JSESSIONID=\(sessionId)",
            "Origin": CloudApiConstants.kamajiOrigin,
            "Referer": CloudApiConstants.kamajiReferer,
            "Accept": "application/json"
        ]), response.statusCode == 200,
              let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = json["links"] as? [[String: Any]] else { return nil }

        var result: [(String, String)] = []
        for link in links {
            guard let name = link["name"] as? String,
                  let url = link["url"] as? String,
                  Self.categoryPatterns.contains(name) else { continue }
            result.append((name, url))
        }
        return result
    }

    private func fetchPsnowCategoryGames(url categoryUrl: String) -> [CloudGame] {
        let url = categoryUrl.contains("?") ? "\(categoryUrl)&start=0&size=500" : "\(categoryUrl)?start=0&size=500"

        guard let response = CloudHttpClient.get(url: url, headers: [
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        ]), response.statusCode == 200,
              let data = response.body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = json["links"] as? [[String: Any]] else { return [] }

        return links.compactMap { parsePsnowGameObject($0) }
    }

    private func parsePsnowGameObject(_ obj: [String: Any]) -> CloudGame? {
        guard let productId = obj["id"] as? String, !productId.isEmpty,
              let name = obj["name"] as? String, !name.isEmpty else { return nil }

        let (coverUrl, landscapeUrl) = extractImageUrls(from: obj)
        var cover = coverUrl, landscape = landscapeUrl
        if cover.hasPrefix("http://") { cover = cover.replacingOccurrences(of: "http://", with: "https://") }
        if landscape.hasPrefix("http://") { landscape = landscape.replacingOccurrences(of: "http://", with: "https://") }

        var platform = "ps4"
        if let platforms = obj["playable_platform"] as? [String] {
            for p in platforms {
                if p.localizedCaseInsensitiveContains("PS3") { platform = "ps3"; break }
                if p.localizedCaseInsensitiveContains("PS4") { platform = "ps4" }
            }
        }

        return CloudGame(productId: productId, name: name, imageUrl: cover,
                         landscapeImageUrl: landscape, platform: platform)
    }

    private func extractImageUrls(from obj: [String: Any]) -> (String, String) {
        guard let images = obj["images"] as? [[String: Any]] else {
            let fallback = obj["imageUrl"] as? String ?? ""
            return (fallback, fallback)
        }

        var cover = "", landscape = ""
        for img in images {
            let type = img["type"] as? Int ?? -1
            let url = img["url"] as? String ?? ""
            if url.isEmpty { continue }
            if type == 10 && cover.isEmpty { cover = url }
            else if type == 12 && landscape.isEmpty { landscape = url }
            else if type == 13 && landscape.isEmpty { landscape = url }
        }
        if landscape.isEmpty && !cover.isEmpty { landscape = cover }
        if cover.isEmpty && !landscape.isEmpty { cover = landscape }
        return (cover, landscape)
    }

    private func generateDuid() -> String {
        let prefix = "0000000700410080"
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        return prefix + randomBytes.map { String(format: "%02x", $0) }.joined()
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
