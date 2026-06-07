// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import os.log

private let ownershipLog = OSLog(subsystem: "com.pylux.stream", category: "CloudOwnership")

/// Raw entitlement fields from Sony internal_entitlements API.
struct PsCloudEntitlement {
    let id: String
    let productId: String
    let activeFlag: Bool
    let packageType: String
    let name: String
    let conceptId: String
    let featureType: Int   // PSN feature_type: 3=full game, 1=trial/free, 0=add-on/DLC
}

enum PsCloudOwnership {
    static let pageSize = 300
    static let pageCooldownSeconds: TimeInterval = 0.1

    private struct CatalogIndex {
        var byProductId: [String: Int] = [:]
        var byConceptId: [String: Int] = [:]
    }

    static func filterOwnedPs5Games(_ entitlements: [PsCloudEntitlement]) -> [PsCloudEntitlement] {
        entitlements.filter { ent in
            // Previously required packageType == "PSGD" (PS5 only), which dropped owned
            // PS4 titles (e.g. God of War 2018) and PS3 titles. Accept every active game
            // entitlement; streamability is enforced downstream by the catalog cross-reference
            // (matches are deduped by conceptId), so non-streamable / add-on entitlements are
            // harmlessly dropped there.
            guard ent.activeFlag else { return false }
            let pid = ent.productId
            guard !pid.hasPrefix("IP"), !pid.hasPrefix("SUB") else { return false }
            // Hide EXTRAS: feature_type==0 is DLC / add-ons / themes / avatars / cross-buy "tracks",
            // never a base game (games are feature_type 1=trial/free or 3/5=full). Safe: can't hide a
            // game. Trials/free and full games are kept; the trial-vs-full split is handled at merge.
            guard ent.featureType != 0 else { return false }
            return true
        }
    }

    static func crossReferenceOwnedGames(
        filteredEntitlements: [PsCloudEntitlement],
        publicCatalog: [CloudGame],
        plusLibrarySupplement: [CloudGame] = [],
        productIdAliases: [String: String] = [:],
        componentIdsByProductId: [String: [String]] = [:]
    ) -> [CloudGame] {
        var catalogMap: [String: CloudGame] = [:]
        for game in publicCatalog {
            catalogMap[game.id] = game
        }
        for (alias, canonical) in productIdAliases {
            if catalogMap[alias] != nil { continue }
            if let meta = catalogMap[canonical] {
                catalogMap[alias] = meta
            }
        }
        var supplementMap: [String: CloudGame] = [:]
        for game in plusLibrarySupplement {
            supplementMap[game.id] = game
        }

        let browseStableKey = buildStableKeyIndex(publicCatalog)
        let supplementStableKey = buildStableKeyIndex(plusLibrarySupplement)
        let browseByConcept = buildConceptIdIndex(publicCatalog)
        let supplementByConcept = buildConceptIdIndex(plusLibrarySupplement)

        var byKey: [String: CloudGame] = [:]
        var byKeyRank: [String: Int] = [:]

        // Enrich one matched catalog row into an owned CloudGame and dedupe it into byKey, keeping
        // OUR convention (conceptId+PLATFORM dedupe, canonical-entitlement rank). Called once for a
        // direct match, or once per component for a bundle (upstream PR #15 bundle-sibling matching).
        func emit(_ meta: CloudGame, _ ent: PsCloudEntitlement) {
            let displayName = meta.name.isEmpty ? ent.name : meta.name
            let game = CloudGame(
                productId: meta.id,
                name: displayName,
                imageUrl: meta.imageUrl,
                landscapeImageUrl: meta.landscapeImageUrl,
                platform: meta.platform,
                serviceType: meta.serviceType,
                conceptUrl: meta.conceptUrl,
                conceptId: meta.conceptId,
                isOwned: true,
                entitlementId: ent.id,
                storeProductId: ent.productId,
                featureType: ent.featureType
            )
            let key = ownedDedupeKey(meta: meta, ent: ent)
            let candidateRank = ownedStreamRank(ent)
            if byKey[key] != nil {
                // Keep the best streaming candidate: the canonical full-game entitlement (its
                // product_id is the real streamable game, not a DLC/bonus product Gaikai rejects).
                if candidateRank > (byKeyRank[key] ?? -1) {
                    byKey[key] = game
                    byKeyRank[key] = candidateRank
                }
            } else {
                byKey[key] = game
                byKeyRank[key] = candidateRank
            }
        }

        for ent in filteredEntitlements {
            let stable = productIdStableKey(ent.productId)
            let entStable = productIdStableKey(ent.id)
            let skipStableDemo = ent.name.localizedCaseInsensitiveContains("demo")
            let meta: CloudGame?
            if !ent.productId.isEmpty, let g = catalogMap[ent.productId] {
                meta = g
            } else if !ent.id.isEmpty, let g = catalogMap[ent.id] {
                meta = g
            } else if !ent.conceptId.isEmpty, let g = browseByConcept[ent.conceptId] {
                // conceptId is region-stable; product IDs are region-prefixed (EP9000 vs UP9000).
                meta = g
            } else if !ent.conceptId.isEmpty, let g = supplementByConcept[ent.conceptId] {
                meta = g
            } else if !ent.productId.isEmpty, ent.id == ent.productId,
                      let g = supplementMap[ent.productId] {
                meta = g
            } else if let stable, !skipStableDemo, let g = browseStableKey[stable] {
                meta = g
            } else if let stable, !skipStableDemo, let g = supplementStableKey[stable] {
                meta = g
            } else if let entStable, !skipStableDemo, let g = browseStableKey[entStable] {
                // Stable-key match on the ENTITLEMENT id (upstream PR #15): catches cross-gen / upgrade
                // entitlement ids whose stable key matches a catalog row even when product_id did not.
                meta = g
            } else if let entStable, !skipStableDemo, let g = supplementStableKey[entStable] {
                meta = g
            } else {
                meta = nil
            }

            if let meta {
                emit(meta, ent)
                continue
            }

            // Bundle-sibling expansion (upstream PR #15): a bundle entitlement (e.g. RE7 Gold) has no
            // direct catalog row, but its component entitlement ids each map to a component game.
            var seenPids = Set<String>()
            for siblingId in componentIdsByProductId[ent.productId] ?? [] {
                let siblingMeta: CloudGame?
                if let g = catalogMap[siblingId] {
                    siblingMeta = g
                } else if let g = supplementMap[siblingId] {
                    siblingMeta = g
                } else if let sStable = productIdStableKey(siblingId), !skipStableDemo {
                    siblingMeta = browseStableKey[sStable] ?? supplementStableKey[sStable]
                } else {
                    siblingMeta = nil
                }
                guard let sMeta = siblingMeta, !sMeta.id.isEmpty, !seenPids.contains(sMeta.id) else { continue }
                seenPids.insert(sMeta.id)
                emit(sMeta, ent)
            }
        }

        // Disc-upgrade rescue (mirrors cloudcatalogbackend.cpp). feature_type 5 is a PS4-disc -> PS5
        // *disc upgrade* license; Gaikai refuses to cloud-stream it ("disc-upgrade-unsupported"). The
        // browse catalog often binds the concept to exactly that SKU (e.g. Horizon Forbidden West
        // concept 10000886 -> PPSA01521), while the user's streamable full-game entitlement is a
        // DIFFERENT title id (e.g. Complete Edition PPSA17903) that is absent from the catalog and
        // carries no conceptId -- so it never matches and only the disc-upgrade SKU survives. When a
        // concept winner is a disc upgrade, adopt a same-name full-game (feature_type 3) owned SKU's
        // product id so the card streams the edition Gaikai accepts.
        //
        // Entitlements carry no conceptId and the disc-upgrade SKU shares no id/sku with the real
        // edition, so the only in-data bridge is the title name. To keep that safe: SAME PLATFORM only
        // (a PS5/PPSA disc upgrade must never resolve to a PS4/CUSA SKU), prefer the canonical base
        // game (product_id == entitlement id), and BAIL on genuine ambiguity rather than guess.
        for key in Array(byKey.keys) {
            guard let game = byKey[key], game.featureType == 5 else { continue }
            let discPid = game.storeProductId
            let discPlatform = platformToken(discPid)
            guard let discEnt = filteredEntitlements.first(where: {
                $0.productId == discPid && $0.featureType == 5
            }) else { continue }
            let discName = normalizeTitle(discEnt.name)
            guard !discName.isEmpty else { continue }
            var canonical: [String] = []   // base-game SKUs (product_id == entitlement id)
            var other: [String] = []       // non-canonical full-game SKUs
            for cand in filteredEntitlements where cand.featureType == 3 {
                guard normalizeTitle(cand.name) == discName else { continue }
                let candPid = cand.productId
                guard !candPid.isEmpty, candPid != discPid else { continue }
                guard platformToken(candPid) == discPlatform else { continue }
                if candPid == cand.id {
                    if !canonical.contains(candPid) { canonical.append(candPid) }
                } else if !other.contains(candPid) {
                    other.append(candPid)
                }
            }
            let replacement: String?
            if canonical.count == 1 {
                replacement = canonical[0]
            } else if canonical.isEmpty, other.count == 1 {
                replacement = other[0]
            } else {
                replacement = nil
            }
            guard let rep = replacement else {
                if !canonical.isEmpty || !other.isEmpty {
                    os_log(.info, log: ownershipLog,
                           "disc-upgrade rescue: ambiguous candidates for %{public}s -- leaving disc SKU",
                           discName)
                }
                continue
            }
            var updated = game
            updated.storeProductId = rep
            byKey[key] = updated
            os_log(.info, log: ownershipLog, "disc-upgrade rescue: %{public}s %{public}s -> %{public}s",
                   discName, discPid, rep)
        }

        return Array(byKey.values)
    }

    // Edition identity = conceptId + PLATFORM (matching the catalog's edition key), so a cross-gen
    // title owned on both PS4 and PS5 stays as two separate library entries instead of collapsing
    // into one. Same-platform duplicate SKUs (a remaster's add-ons) still merge.
    private static func ownedDedupeKey(meta: CloudGame, ent: PsCloudEntitlement) -> String {
        if !meta.conceptId.isEmpty { return "c:\(meta.conceptId):\(platformToken(ent.productId))" }
        if !meta.id.isEmpty { return "p:\(meta.id)" }
        if !ent.id.isEmpty { return "e:\(ent.id)" }
        return "u:\(meta.id):\(ent.id)"
    }

    // Platform token from a product id (CUSA = PS4, PPSA = PS5).
    static func platformToken(_ productId: String) -> String {
        if productId.contains("PPSA") { return "ps5" }
        if productId.contains("CUSA") { return "ps4" }
        return ""
    }

    // Lowercase, strip trademark/registered/service-mark glyphs, and collapse whitespace so two owned
    // entitlements for the same game compare equal across punctuation/spacing differences.
    private static func normalizeTitle(_ raw: String) -> String {
        let stripped = raw.lowercased()
            .replacingOccurrences(of: "\u{2122}", with: "")
            .replacingOccurrences(of: "\u{00AE}", with: "")
            .replacingOccurrences(of: "\u{2120}", with: "")
        return stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // A "full game" entitlement (vs add-on/avatar/theme): PSN marks the base game with a *GD
    // package_type (PSGD/PS4GD); add-ons use PS4MISC/PSAL/etc.
    private static func isFullGameEntitlement(_ ent: PsCloudEntitlement) -> Bool {
        ent.featureType == 3 || ent.packageType.hasSuffix("GD")
    }

    // Rank an owned entitlement as THE streaming candidate for its edition (higher = preferred).
    // Bonus/upgrade SKUs collapse to the same conceptId+platform as the base game; package/feature
    // flags don't disambiguate (Death Stranding DC's "Bonus Content" is also PSGD + feature_type 3).
    // The reliable signal: the base game's entitlement id EQUALS its product_id, while bonus/upgrade
    // SKUs carry a different id -- so prefer the canonical full-game entitlement.
    private static func ownedStreamRank(_ ent: PsCloudEntitlement) -> Int {
        var rank = 0
        if !ent.productId.isEmpty && ent.productId == ent.id { rank += 4 } // canonical base-game SKU
        if isFullGameEntitlement(ent) { rank += 2 }
        if !ent.id.isEmpty { rank += 1 }
        return rank
    }

    // conceptId + platform for an owned/catalog game; the owned product id (storeProductId) takes
    // precedence so the owned edition's platform is used, else the catalog product id.
    private static func conceptPlatformKey(_ game: CloudGame) -> String {
        guard !game.conceptId.isEmpty else { return "" }
        let pid = game.storeProductId.isEmpty ? game.id : game.storeProductId
        return "\(game.conceptId)|\(platformToken(pid))"
    }

    /// Tokenize on '-' and '_'; identity is all tokens except the last (store SKU).
    private static func productIdStableKey(_ productId: String) -> String? {
        guard !productId.isEmpty else { return nil }
        var tokens: [String] = []
        for dashPart in productId.split(separator: "-") {
            for token in dashPart.split(separator: "_") where !token.isEmpty {
                tokens.append(String(token))
            }
        }
        guard tokens.count >= 2 else { return nil }
        return tokens.dropLast().joined(separator: "|")
    }

    private static func buildStableKeyIndex(_ games: [CloudGame]) -> [String: CloudGame] {
        var index: [String: CloudGame] = [:]
        for game in games {
            guard let key = productIdStableKey(game.id) else { continue }
            if index[key] == nil {
                index[key] = game
            }
        }
        return index
    }

    private static func buildConceptIdIndex(_ games: [CloudGame]) -> [String: CloudGame] {
        var index: [String: CloudGame] = [:]
        for game in games where !game.conceptId.isEmpty {
            if index[game.conceptId] == nil {
                index[game.conceptId] = game
            }
        }
        return index
    }

    /// Normalize a conceptId (imagic encodes it as a number) to a non-empty string, else nil.
    static func conceptIdString(_ value: Any?) -> String? {
        if let i = value as? Int { return i > 0 ? String(i) : nil }
        if let d = value as? Double { return d > 0 ? String(Int(d)) : nil }
        if let s = value as? String, !s.isEmpty { return s }
        return nil
    }

    static func mergeOwnedIntoBrowseCatalog(
        browseCatalog: [CloudGame],
        ownedCrossRef: [CloudGame],
        addUnmatched: Bool = true   // false = only mark ownership on catalog entries (Catalog tab)
    ) -> [CloudGame] {
        var games = browseCatalog
        var catalogIndex = buildCatalogIndex(games)

        for owned in ownedCrossRef {
            // Trials / free-to-play (feature_type 1) are kept as their OWN card so the user can Stream
            // the trial/free build, while the full version still shows separately as a not-owned
            // "Add Game" card -- so a trial must NOT collapse into the full-game catalog entry.
            let isTrialTier = owned.featureType == 1
            let catalogMatch = isTrialTier ? -1 : findCatalogIndexForOwned(owned, catalogIndex: catalogIndex)
            if catalogMatch >= 0 {
                var existing = games[catalogMatch]
                existing.isOwned = true
                if !owned.entitlementId.isEmpty { existing.entitlementId = owned.entitlementId }
                if !owned.storeProductId.isEmpty { existing.storeProductId = owned.storeProductId }
                games[catalogMatch] = existing
                continue
            }

            guard addUnmatched else { continue }
            var entry = owned
            entry.isOwned = true
            registerInCatalogIndex(entry, index: games.count, catalogIndex: &catalogIndex)
            games.append(entry)
        }

        return games.sorted {
            if $0.isOwned != $1.isOwned { return $0.isOwned && !$1.isOwned }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func parseEntitlement(_ obj: [String: Any]) -> PsCloudEntitlement? {
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let gameMeta = obj["game_meta"] as? [String: Any] ?? [:]
        let name = (gameMeta["name"] as? String) ?? id
        let conceptId = conceptIdString(gameMeta["conceptId"])
            ?? conceptIdString(gameMeta["concept_id"])
            ?? conceptIdString(obj["conceptId"])
            ?? ""
        return PsCloudEntitlement(
            id: id,
            productId: (obj["product_id"] as? String) ?? "",
            activeFlag: (obj["active_flag"] as? Bool) ?? false,
            packageType: (gameMeta["package_type"] as? String) ?? "",
            name: name,
            conceptId: conceptId,
            featureType: (obj["feature_type"] as? NSNumber)?.intValue ?? 0
        )
    }

    private static func buildCatalogIndex(_ games: [CloudGame]) -> CatalogIndex {
        var catalogIndex = CatalogIndex()
        for i in games.indices {
            registerInCatalogIndex(games[i], index: i, catalogIndex: &catalogIndex)
        }
        return catalogIndex
    }

    private static func registerInCatalogIndex(
        _ game: CloudGame,
        index: Int,
        catalogIndex: inout CatalogIndex
    ) {
        if !game.id.isEmpty { catalogIndex.byProductId[game.id] = index }
        let conceptKey = conceptPlatformKey(game)
        if !conceptKey.isEmpty { catalogIndex.byConceptId[conceptKey] = index }
        if !game.entitlementId.isEmpty, game.entitlementId != game.id {
            catalogIndex.byProductId[game.entitlementId] = index
        }
    }

    private static func findCatalogIndexForOwned(_ owned: CloudGame, catalogIndex: CatalogIndex) -> Int {
        if !owned.id.isEmpty, let idx = catalogIndex.byProductId[owned.id] { return idx }
        if !owned.entitlementId.isEmpty, let idx = catalogIndex.byProductId[owned.entitlementId] { return idx }
        if !owned.storeProductId.isEmpty, let idx = catalogIndex.byProductId[owned.storeProductId] { return idx }
        // Match by conceptId + platform so an owned PS4 edition does not match a PS5-only catalog
        // entry (and vice-versa); cross-gen editions stay as separate library cards.
        let conceptKey = conceptPlatformKey(owned)
        if !conceptKey.isEmpty, let idx = catalogIndex.byConceptId[conceptKey] { return idx }
        return -1
    }
}
