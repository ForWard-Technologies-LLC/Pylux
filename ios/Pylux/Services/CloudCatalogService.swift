// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Cloud catalog fetching - mirrors Android CloudGameRepository.kt + PsnCatalogService.kt + PsCloudCatalogService.kt

import Foundation
import os.log

private let catalogLog = OSLog(subsystem: "com.pylux.stream", category: "CloudCatalog")

/// CloudCatalogService - Fetches and caches game catalogs for both PSNow and PS5 Cloud
/// Mirrors: android/.../cloudplay/repository/CloudGameRepository.kt
final class CloudCatalogService {

    private(set) var lastLibraryFetchError: String?
    private(set) var lastLibraryFetchWarning: String?
    private(set) var lastCatalogFetchWarning: String?

    // MARK: - Disk Cache (matches Android: context.cacheDir/cloud_catalog_cache/)

    private static let cacheDuration: TimeInterval = 86400 // 24 hours
    private static let psnowCacheFile = "psnow_catalog.json"
    private static let ps5PublicCacheFile = "ps5_cloud_catalog_v4.json" // v4: adds plusCatalog tag + broader supplement
    private static let pscloudAllCacheFile = "pscloud_catalog_v2.json"
    private static let pscloudOwnedCacheFile = "pscloud_owned_v3.json" // v3: ft0 filter + rank dedupe + featureType

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

    private struct Ps5CloudCatalogResult {
        let browseGames: [CloudGame]
        let plusLibrarySupplement: [CloudGame]
        let productIdAliases: [String: String]
        let catalogFetchWarning: String?
        let shouldCacheV3: Bool

        init(
            browseGames: [CloudGame],
            plusLibrarySupplement: [CloudGame],
            productIdAliases: [String: String],
            catalogFetchWarning: String? = nil,
            shouldCacheV3: Bool = true
        ) {
            self.browseGames = browseGames
            self.plusLibrarySupplement = plusLibrarySupplement
            self.productIdAliases = productIdAliases
            self.catalogFetchWarning = catalogFetchWarning
            self.shouldCacheV3 = shouldCacheV3
        }
    }

    private func serializeGame(_ g: CloudGame) -> [String: Any] {
        return [
            "productId": g.id, "name": g.name,
            "imageUrl": g.imageUrl, "landscapeImageUrl": g.landscapeImageUrl,
            "platform": g.platform, "serviceType": g.serviceType,
            "conceptUrl": g.conceptUrl, "conceptId": g.conceptId,
            "isOwned": g.isOwned,
            "entitlementId": g.entitlementId, "storeProductId": g.storeProductId,
            "plusCatalog": g.plusCatalog, "featureType": g.featureType
        ]
    }

    private func deserializeGame(_ d: [String: Any]) -> CloudGame? {
        guard let pid = d["productId"] as? String, !pid.isEmpty,
              let name = d["name"] as? String, !name.isEmpty else { return nil }
        return CloudGame(
            productId: pid, name: name,
            imageUrl: d["imageUrl"] as? String ?? "",
            landscapeImageUrl: d["landscapeImageUrl"] as? String ?? "",
            platform: { let p = ps5PlatformToken(pid); return p.isEmpty ? (d["platform"] as? String ?? "ps4") : p }(),
            serviceType: d["serviceType"] as? String ?? "psnow",
            conceptUrl: d["conceptUrl"] as? String ?? "",
            conceptId: d["conceptId"] as? String ?? "",
            isOwned: d["isOwned"] as? Bool ?? false,
            entitlementId: d["entitlementId"] as? String ?? "",
            storeProductId: d["storeProductId"] as? String ?? "",
            plusCatalog: d["plusCatalog"] as? Bool ?? false,
            featureType: (d["featureType"] as? NSNumber)?.intValue ?? 0
        )
    }

    // MARK: - PS5 Cloud Catalog (Public)

    func fetchPs5CloudCatalog(forceRefresh: Bool = false) -> [CloudGame] {
        loadPs5CloudCatalog(forceRefresh: forceRefresh).browseGames
    }

    private func loadPs5CloudCatalog(forceRefresh: Bool) -> Ps5CloudCatalogResult {
        let stored = CloudLocaleSettings.stored
        os_log(.info, log: catalogLog,
               "PS5 catalog stored=%{public}s forceRefresh=%{public}s",
               stored, forceRefresh ? "yes" : "no")
        if !forceRefresh, let cached = loadCachedPs5CatalogV3(expectedLocale: stored) {
            os_log(.info, log: catalogLog, "PS5 catalog: using disk cache")
            lastCatalogFetchWarning = nil
            return cached
        }

        lastCatalogFetchWarning = nil
        // Try the store-locale fallback chain (session locale -> en-COUNTRY -> en-US). A whole
        // tier returning nil means it 404'd for an unsupported locale; escalate to the next.
        for tier in CloudLocaleSettings.fallbackChain() {
            guard let fetched = fetchPs5CloudCatalogFromNetwork(locale: tier.imagic) else {
                os_log(.info, log: catalogLog,
                       "PS5 imagic locale %{public}s failed, trying next tier", tier.imagic)
                continue
            }
            // Persist the locale that actually worked so game details and the cache agree on it.
            if tier.canonical != stored {
                os_log(.info, log: catalogLog,
                       "PS5 store locale settled on %{public}s (was %{public}s)", tier.canonical, stored)
                CloudLocaleSettings.setStored(tier.canonical)
            }
            if fetched.shouldCacheV3,
               !fetched.browseGames.isEmpty || !fetched.plusLibrarySupplement.isEmpty {
                cachePs5CatalogV3(fetched, locale: tier.canonical)
            }
            if let warning = fetched.catalogFetchWarning {
                lastCatalogFetchWarning = warning
            }
            return fetched
        }
        return Ps5CloudCatalogResult(
            browseGames: [], plusLibrarySupplement: [], productIdAliases: [:],
            shouldCacheV3: false
        )
    }

    private func loadCachedPs5CatalogV3(expectedLocale: String) -> Ps5CloudCatalogResult? {
        let file = Self.cacheDir.appendingPathComponent(Self.ps5PublicCacheFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        if Date().timeIntervalSince(modified) > Self.cacheDuration {
            try? FileManager.default.removeItem(at: file)
            return nil
        }

        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }

        if let cachedLocale = root["locale"] as? String, !cachedLocale.isEmpty, cachedLocale != expectedLocale {
            os_log(.info, log: catalogLog,
                   "PS5 catalog v3 locale mismatch (%{public}s != %{public}s), refetching",
                   cachedLocale, expectedLocale)
            try? FileManager.default.removeItem(at: file)
            return nil
        }

        let browseArr = root["games"] as? [[String: Any]] ?? []
        let supplementArr = root["plusLibrarySupplement"] as? [[String: Any]] ?? []
        let browse = browseArr.compactMap { deserializeGame($0) }
        let supplement = supplementArr.compactMap { deserializeGame($0) }
        let aliases = parseProductIdAliases(root["productIdAliases"] as? [String: Any])
        os_log(.info, log: catalogLog, "Loaded PS5 catalog v3: %d browse, %d supplement, %d aliases",
               browse.count, supplement.count, aliases.count)
        return Ps5CloudCatalogResult(browseGames: browse, plusLibrarySupplement: supplement, productIdAliases: aliases)
    }

    private func cachePs5CatalogV3(_ catalog: Ps5CloudCatalogResult, locale: String) {
        var root: [String: Any] = [
            "locale": locale,
            "games": catalog.browseGames.map { serializeGame($0) },
            "plusLibrarySupplement": catalog.plusLibrarySupplement.map { serializeGame($0) },
            "total": catalog.browseGames.count
        ]
        if !catalog.productIdAliases.isEmpty {
            root["productIdAliases"] = catalog.productIdAliases
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: []) else { return }
        let file = Self.cacheDir.appendingPathComponent(Self.ps5PublicCacheFile)
        try? data.write(to: file, options: .atomic)
        os_log(.info, log: catalogLog, "Cached PS5 catalog v3: %d browse, %d supplement, %d aliases",
               catalog.browseGames.count, catalog.plusLibrarySupplement.count, catalog.productIdAliases.count)
    }

    private func parseProductIdAliases(_ raw: [String: Any]?) -> [String: String] {
        guard let raw else { return [:] }
        var aliases: [String: String] = [:]
        for (alias, value) in raw {
            if let canonical = value as? String, !canonical.isEmpty {
                aliases[alias] = canonical
            }
        }
        return aliases
    }

    private static let ps5ImagicCategoryLists = [
        "plus-games-list",
        "ubisoft-classics-list",
        "plus-classics-list",
        "plus-monthly-games-list",
        "free-to-play-list",
        "all-ps5-list",
    ]

    private func fetchPs5CloudCatalogFromNetwork(locale: String) -> Ps5CloudCatalogResult? {
        os_log(.info, log: catalogLog,
               "=== Fetching PS5 Cloud Catalog (6 imagic lists) locale=%{public}s ===", locale)

        var byConceptId: [String: [String: Any]] = [:]
        var order: [String] = []
        var plusSupplementByProductId: [String: [String: Any]] = [:]
        var productIdAliases: [String: String] = [:]
        var totalRows = 0
        var failedLists: [String] = []
        var succeededListCount = 0
        var allPs5ListSucceeded = false

        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        ]

        for categoryList in Self.ps5ImagicCategoryLists {
            let url = "https://www.playstation.com/bin/imagic/gameslist?locale=\(locale)&categoryList=\(categoryList)"
            guard let response = CloudHttpClient.get(url: url, headers: headers),
                  response.statusCode == 200,
                  let data = response.body.data(using: .utf8),
                  let categories = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                os_log(.error, log: catalogLog, "PS5 imagic list fetch failed: %{public}s", categoryList)
                failedLists.append(categoryList)
                continue
            }

            succeededListCount += 1
            if categoryList == "all-ps5-list" {
                allPs5ListSucceeded = true
            }

            let isPlus = isPlusCatalogList(categoryList) // subscription catalog vs the all-ps5 universe
            for category in categories {
                guard let gameArray = category["games"] as? [[String: Any]] else { continue }
                totalRows += gameArray.count
                for gameObj in gameArray {
                    // Accept PS4 and PS5; the old PS5-only gate dropped PS4-only PS-Plus-catalog
                    // titles (e.g. God of War 2018) before they could reach the supplement below.
                    guard isCloudDeviceGame(gameObj) else { continue }

                    // Subscription-catalog titles with streamingSupported=false → library-stream
                    // supplement, captured from EVERY subscription list (not just plus-games-list).
                    if isPlus, (gameObj["streamingSupported"] as? Bool) != true {
                        let productId = gameObj["productId"] as? String ?? ""
                        if !productId.isEmpty, plusSupplementByProductId[productId] == nil {
                            var g = gameObj; g["plusCatalog"] = true
                            plusSupplementByProductId[productId] = g
                        }
                        continue
                    }

                    guard isCloudStreamingGame(gameObj) else { continue }
                    let key = editionKey(for: gameObj) // per game per platform (cross-gen split)
                    let productId = gameObj["productId"] as? String ?? ""
                    guard !key.isEmpty, !productId.isEmpty else { continue }

                    if var existing = byConceptId[key] {
                        let canonicalProductId = existing["productId"] as? String ?? ""
                        if !canonicalProductId.isEmpty, productId != canonicalProductId,
                           productIdAliases[productId] == nil {
                            productIdAliases[productId] = canonicalProductId
                        }
                        if isPlus, (existing["plusCatalog"] as? Bool) != true {
                            existing["plusCatalog"] = true
                            byConceptId[key] = existing
                        }
                        continue
                    }

                    var g = gameObj; g["plusCatalog"] = isPlus
                    byConceptId[key] = g
                    order.append(key)
                }
            }
        }

        if succeededListCount == 0 {
            os_log(.error, log: catalogLog, "All PS5 imagic lists failed")
            return nil
        }

        var catalogFetchWarning: String?
        if !failedLists.isEmpty {
            catalogFetchWarning = "Some catalog lists failed to load (\(failedLists.joined(separator: ", "))). Catalog may be incomplete."
            os_log(.info, log: catalogLog, "PS5 imagic partial fetch; failed: %{public}s",
                   failedLists.joined(separator: ", "))
        }

        var browseGames: [CloudGame] = []
        for key in order {
            guard let gameObj = byConceptId[key],
                  let cloudGame = cloudGameFromImagic(gameObj) else { continue }
            browseGames.append(cloudGame)
        }

        let plusLibrarySupplement = plusSupplementByProductId.values.compactMap { cloudGameFromImagic($0) }

        os_log(.info, log: catalogLog,
               "PS5 Cloud catalog: %d rows scanned, %d streaming, %d supplement, %d aliases",
               totalRows, browseGames.count, plusLibrarySupplement.count, productIdAliases.count)
        return Ps5CloudCatalogResult(
            browseGames: browseGames,
            plusLibrarySupplement: plusLibrarySupplement,
            productIdAliases: productIdAliases,
            catalogFetchWarning: catalogFetchWarning,
            shouldCacheV3: allPs5ListSucceeded
        )
    }

    // PS Plus cloud streaming covers PS4 and PS5 titles (PS3 is not in these imagic lists).
    // A PS4-only title such as God of War (2018) is streamable when owned even though it
    // carries device ["PS4"], so the catalog must not discard it.
    private func isCloudDeviceGame(_ gameObj: [String: Any]) -> Bool {
        guard let devices = gameObj["device"] as? [String] else { return false }
        return devices.contains("PS5") || devices.contains("PS4")
    }

    private func isCloudStreamingGame(_ gameObj: [String: Any]) -> Bool {
        guard (gameObj["streamingSupported"] as? Bool) == true else { return false }
        return isCloudDeviceGame(gameObj)
    }

    // The PS Plus subscription catalog = these curated lists (≈ what Sony lists). all-ps5-list is
    // the full streamable universe and must NOT count as subscription catalog.
    private func isPlusCatalogList(_ categoryList: String) -> Bool {
        return categoryList == "plus-games-list" || categoryList == "plus-classics-list"
            || categoryList == "ubisoft-classics-list" || categoryList == "plus-monthly-games-list"
    }

    private func conceptKey(for gameObj: [String: Any]) -> String {
        if let conceptId = gameObj["conceptId"] as? Int { return String(conceptId) }
        if let conceptId = gameObj["conceptId"] as? Double { return String(Int(conceptId)) }
        if let conceptId = gameObj["conceptId"] as? String, !conceptId.isEmpty { return conceptId }
        return gameObj["productId"] as? String ?? ""
    }

    // Platform token from a product id (CUSA = PS4, PPSA = PS5).
    private func ps5PlatformToken(_ productId: String) -> String {
        if productId.contains("PPSA") { return "ps5" }
        if productId.contains("CUSA") { return "ps4" }
        return ""
    }

    // Dedupe identity: one entry per game PER PLATFORM, so cross-gen PS4/PS5 editions (e.g. Deliver
    // Us The Moon) both appear, while duplicate same-platform SKUs still collapse.
    private func editionKey(for gameObj: [String: Any]) -> String {
        let c = conceptKey(for: gameObj)
        if c.isEmpty { return "" }
        return c + "|" + ps5PlatformToken(gameObj["productId"] as? String ?? "")
    }

    private func cloudGameFromImagic(_ gameObj: [String: Any]) -> CloudGame? {
        let productId = gameObj["productId"] as? String ?? ""
        guard !productId.isEmpty else { return nil }
        let name = gameObj["name"] as? String ?? "Unknown"
        var imageUrl = gameObj["imageUrl"] as? String ?? ""
        let conceptUrl = gameObj["conceptUrl"] as? String
            ?? gameObj["concept_url"] as? String
            ?? gameObj["url"] as? String ?? ""
        if imageUrl.hasPrefix("http://") {
            imageUrl = imageUrl.replacingOccurrences(of: "http://", with: "https://")
        }
        return CloudGame(
            productId: productId, name: name,
            imageUrl: imageUrl, landscapeImageUrl: imageUrl,
            platform: { let p = ps5PlatformToken(productId); return p.isEmpty ? "ps5" : p }(), serviceType: "pscloud",
            conceptUrl: conceptUrl, conceptId: conceptKey(for: gameObj),
            isOwned: false,
            plusCatalog: gameObj["plusCatalog"] as? Bool ?? false
        )
    }

    // MARK: - PS5 Cloud Library: All Games (matches Android fetchPs5CloudCatalog with ownership)

    /// Fetch ALL PS5 Cloud games with ownership flags.
    /// Mirrors Qt: fetchPs5CloudCatalog + getOwnedPs5CloudGames + CloudPlayView All tab
    func fetchAllPs5CloudGames(npssoToken: String, forceRefresh: Bool = false) -> [CloudGame] {
        lastLibraryFetchError = nil
        lastLibraryFetchWarning = nil
        CloudLocaleSettings.ensureConfigured(npssoToken: npssoToken)

        if !forceRefresh, let cached = loadCachedGames(Self.pscloudAllCacheFile) {
            os_log(.info, log: catalogLog, "Returning %d PS5 games from cache (ownership included)", cached.count)
            return cached
        }

        os_log(.info, log: catalogLog, "=== Fetching ALL PS5 Cloud Games (with ownership) ===")

        let catalog = loadPs5CloudCatalog(forceRefresh: forceRefresh)
        guard !catalog.browseGames.isEmpty || !catalog.plusLibrarySupplement.isEmpty else { return [] }

        guard let ownedCrossRef = getOwnedPs5CloudGames(
            npssoToken: npssoToken,
            publicCatalog: catalog.browseGames,
            plusLibrarySupplement: catalog.plusLibrarySupplement,
            productIdAliases: catalog.productIdAliases
        ) else {
            os_log(.info, log: catalogLog,
                   "Entitlements fetch failed; returning browse catalog without ownership")
            lastLibraryFetchWarning =
                "Failed to verify game ownership. Some games may show as not owned."
            let browseGames = catalog.browseGames
            if !browseGames.isEmpty {
                cacheGames(browseGames, filename: Self.pscloudAllCacheFile)
            }
            return browseGames
        }
        let allGames = PsCloudOwnership.mergeOwnedIntoBrowseCatalog(
            browseCatalog: catalog.browseGames,
            ownedCrossRef: ownedCrossRef
        )

        if !allGames.isEmpty {
            cacheGames(allGames, filename: Self.pscloudAllCacheFile)
        }

        let ownedCount = allGames.filter { $0.isOwned }.count
        os_log(.info, log: catalogLog, "PS5 Library: %d total, %d owned", allGames.count, ownedCount)
        return allGames
    }

    // MARK: - PS Plus Subscription Catalog (Catalog tab)

    /// The PS Plus subscription catalog: plusCatalog browse titles + the library-stream supplement
    /// (the ~630 set Sony lists), NOT the full all-ps5 universe. No ownership fetch — every
    /// subscription title is shown as streamable. Mirrors Qt ps5PlusCatalogGames + Catalog tab.
    func fetchPlusCatalogGames(npssoToken: String = "", forceRefresh: Bool = false) -> [CloudGame] {
        let catalog = loadPs5CloudCatalog(forceRefresh: forceRefresh)
        var games = catalog.browseGames.filter { $0.plusCatalog }
        games.append(contentsOf: catalog.plusLibrarySupplement)
        games.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Mark which subscription titles you already own, so owned games show "Stream" and non-owned
        // show "Add Game" (they must be added to your library first). addUnmatched:false keeps the
        // Catalog the pure subscription set (mark only; never add owned-but-uncatalogued games).
        guard !npssoToken.isEmpty else { return games }
        let owned = fetchOwnedPs5Games(npssoToken: npssoToken, forceRefresh: forceRefresh)
        return PsCloudOwnership.mergeOwnedIntoBrowseCatalog(
            browseCatalog: games, ownedCrossRef: owned, addUnmatched: false)
    }

    // MARK: - PS5 Cloud Library: Owned Only

    /// Mirrors CloudCatalogBackend::getOwnedPs5CloudGames (owned tab)
    func fetchOwnedPs5Games(npssoToken: String, forceRefresh: Bool = false) -> [CloudGame] {
        lastLibraryFetchError = nil
        lastLibraryFetchWarning = nil
        CloudLocaleSettings.ensureConfigured(npssoToken: npssoToken)

        guard !npssoToken.isEmpty else { return [] }

        if !forceRefresh, let cached = loadCachedGames(Self.pscloudOwnedCacheFile) {
            os_log(.info, log: catalogLog, "Returning %d owned PS5 games from cache", cached.count)
            return cached
        }

        os_log(.info, log: catalogLog, "=== Fetching Owned PS5 Games Only ===")

        let catalog = loadPs5CloudCatalog(forceRefresh: forceRefresh)
        guard let owned = getOwnedPs5CloudGames(
            npssoToken: npssoToken,
            publicCatalog: catalog.browseGames,
            plusLibrarySupplement: catalog.plusLibrarySupplement,
            productIdAliases: catalog.productIdAliases
        ) else {
            lastLibraryFetchError = "Failed to fetch owned games. Check your connection."
            return []
        }

        if !owned.isEmpty {
            cacheGames(owned, filename: Self.pscloudOwnedCacheFile)
        }

        os_log(.info, log: catalogLog, "Owned streaming games: %d", owned.count)
        return owned
    }

    /// Mirrors CloudCatalogBackend::getOwnedPs5CloudGames orchestration (network path).
    private func getOwnedPs5CloudGames(
        npssoToken: String,
        publicCatalog: [CloudGame],
        plusLibrarySupplement: [CloudGame] = [],
        productIdAliases: [String: String] = [:]
    ) -> [CloudGame]? {
        guard !npssoToken.isEmpty,
              let oauthToken = fetchOwnedGamesOAuthToken(npssoToken: npssoToken) else {
            return nil
        }

        Thread.sleep(forTimeInterval: PsCloudOwnership.pageCooldownSeconds)
        guard let rawObjects = fetchEntitlementsPaginated(oauthToken: oauthToken) else {
            return nil
        }
        let rawEntitlements = rawObjects.compactMap { PsCloudOwnership.parseEntitlement($0) }
        let filtered = PsCloudOwnership.filterOwnedPs5Games(rawEntitlements)

        // Map each bundle product_id -> the entitlement ids sharing it, so a bundle (e.g. RE7 Gold)
        // expands to its component games during cross-reference (upstream PR #15 bundle-sibling match).
        var componentIds: [String: [String]] = [:]
        for ent in rawEntitlements where !ent.productId.isEmpty && !ent.id.isEmpty {
            componentIds[ent.productId, default: []].append(ent.id)
        }

        return PsCloudOwnership.crossReferenceOwnedGames(
            filteredEntitlements: filtered,
            publicCatalog: publicCatalog,
            plusLibrarySupplement: plusLibrarySupplement,
            productIdAliases: productIdAliases,
            componentIdsByProductId: componentIds
        )
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

    private func fetchEntitlementsPaginated(oauthToken: String) -> [[String: Any]]? {
        var all: [[String: Any]] = []
        var start = 0

        while true {
            let url = "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements?fields=game_meta&entitlement_type=5&start=\(start)&size=\(PsCloudOwnership.pageSize)"

            guard let response = CloudHttpClient.get(url: url, headers: [
                "Authorization": "Bearer \(oauthToken)",
                "Accept": "application/json"
            ]), response.statusCode == 200,
                  let data = response.body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = json["entitlements"] as? [[String: Any]] else {
                os_log(.error, log: catalogLog, "Entitlements page failed at start=%d", start)
                return nil
            }

            all.append(contentsOf: page)
            if page.count < PsCloudOwnership.pageSize { break }
            start += page.count
            Thread.sleep(forTimeInterval: PsCloudOwnership.pageCooldownSeconds)
        }

        return all
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

    // MARK: - PS3 Classics Catalog (public Apollo container walk)
    //
    // The PS Plus PC ("Apollo") app browses the streamable catalog through the public pcnow
    // container API at psnow.playstation.com. There is a dedicated PS3 container (e.g.
    // STORE-MSF192018-APOLLOPS3GAMES for Americas) that lists ~300 streamable PS3 titles with
    // their PS3 product ids (NPUA/NPUB/BLUS/BCUS) — none of which appear in the imagic gameslist
    // the rest of the catalog uses. The container API needs no OAuth or per-account session
    // (unlike /user/stores, which 404s in regions where the PC app is unavailable, e.g. Hungary),
    // so we can walk it directly in any region. The resulting titles carry playable_platform
    // ["PS3"] and stream via the existing PSNOW -> Gaikai konan path.

    /// Resolve the account's region group from its stored store locale (e.g. "en-HU" -> "HU").
    /// pcnow has two Classics id families (Americas/SCEA and PAL/SCEE); a PS Plus account is
    /// authorized at Gaikai only for the family of its own region group, so the catalog must be
    /// browsed in that group. See ClassicsRegion.classicsStoreCountry / classicsPs3ContainerId.
    private func ps3AccountCountry() -> String {
        return CloudLocaleSettings.parseStorePath(CloudLocaleSettings.stored).country
    }

    /// Fetch the streamable PS3 Classics from the public Apollo container for the account's
    /// region group. Mirrors Qt CloudCatalogBackend::fetchPs3Catalog. PUBLIC API: no auth.
    func fetchPs3Catalog(forceRefresh: Bool = false) -> [CloudGame] {
        let country = ps3AccountCountry()
        let storeCountry = ClassicsRegion.classicsStoreCountry(country)
        // Region-group-specific cache key so an Americas/PAL switch doesn't serve stale ids.
        let cacheFile = "ps3_catalog_\(storeCountry).json"
        if !forceRefresh, let cached = loadCachedGames(cacheFile) {
            os_log(.info, log: catalogLog, "Returning %d PS3 Classics from cache", cached.count)
            return cached
        }

        let containerId = ClassicsRegion.classicsPs3ContainerId(country)
        let containerUrl = "\(CloudApiConstants.storeBase)/container/\(storeCountry)/en/19/\(containerId)"
        os_log(.info, log: catalogLog,
               "=== Fetching PS3 Classics catalog (region group %{public}s for account country %{public}s) ===",
               storeCountry, country)

        var allGames: [CloudGame] = []
        var start = 0
        var totalResults = -1

        while true {
            let url = "\(containerUrl)?useOffers=true&gkb=1&gkb2=1&start=\(start)&size=100"
            guard let response = CloudHttpClient.get(url: url, headers: [
                "Accept": "application/json",
                "User-Agent": CloudApiConstants.kamajiUserAgent
            ]), response.statusCode == 200,
                  let data = response.body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                os_log(.error, log: catalogLog, "PS3 catalog page failed at start=%d", start)
                break
            }

            if totalResults < 0 {
                totalResults = (json["total_results"] as? Int)
                    ?? (json["total_results"] as? NSNumber)?.intValue ?? 0
            }

            let links = json["links"] as? [[String: Any]] ?? []
            var productCount = 0
            for link in links {
                guard (link["container_type"] as? String) == "product" else { continue }
                guard let game = parsePsnowGameObject(link) else { continue }
                allGames.append(game)
                productCount += 1
            }

            os_log(.info, log: catalogLog, "PS3 page games: %d accumulated: %d of %d",
                   productCount, allGames.count, totalResults)

            start += 100
            if productCount == 0 || start >= totalResults { break }
        }

        os_log(.info, log: catalogLog, "PS3 Classics catalog: %d titles", allGames.count)
        if !allGames.isEmpty { cacheGames(allGames, filename: cacheFile) }
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

        CloudLocaleSettings.applyLocaleFromKamajiSessionBody(response.body)
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
