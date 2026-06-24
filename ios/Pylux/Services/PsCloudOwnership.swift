// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

import Foundation
import os.log

private let ownershipLog = OSLog(subsystem: "com.pylux.stream", category: "CloudOwnership")

/// Raw entitlement fields from Sony internal_entitlements API.
struct PsCloudEntitlement {
    let id: String
    let productId: String
    let skuId: String      // PSN sku_id -- stable unique key for deterministic dedupe tie-breaking
    let activeFlag: Bool
    let packageType: String
    let name: String
    let conceptId: String
    let featureType: Int   // PSN feature_type: 3=full game, 1=trial/free, 0=add-on/DLC
    // Structured platform from entitlement_attributes[].platform_id ("ps5"/"ps4"/"ps3"). This is the
    // authoritative stream-backend signal -- NOT a CUSA/PPSA id prefix, since a cross-buy PS4 license
    // can carry a PS5-looking product_id wrapper (Red Dead's PS4 license has product_id ...PPSA30528).
    let platformId: String
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
        var byKeyEnt: [String: PsCloudEntitlement] = [:]

        // Enrich one matched catalog row into an owned CloudGame and dedupe it into byKey, keeping
        // OUR convention (conceptId+PLATFORM dedupe, canonical-entitlement rank). Called once for a
        // direct match, or once per component for a bundle (upstream PR #15 bundle-sibling matching).
        func emit(_ meta: CloudGame, _ ent: PsCloudEntitlement) {
            let displayName = meta.name.isEmpty ? ent.name : meta.name
            // The owned card's serviceType comes from the ENTITLEMENT's platform_id (pscloud == PS5,
            // psnow == PS3/PS4), not the matched catalog row's: a cross-buy PS4 license can match a
            // PS5 catalog row by shared product_id, but it must still route as PS4/Kamaji.
            let ownedService = ownedServiceType(ent, meta)
            // Qt emitOwned field convention: productId = entitlement.product_id (NOT catalog meta.id);
            // entitlementId = entitlement.id. Merge + QMap sort rely on these being separate for cross-buy.
            let streamProductId = ent.productId.isEmpty ? meta.id : ent.productId
            let game = CloudGame(
                productId: streamProductId,
                name: displayName,
                imageUrl: meta.imageUrl,
                landscapeImageUrl: meta.landscapeImageUrl,
                platform: meta.platform,
                serviceType: ownedService,
                conceptUrl: meta.conceptUrl,
                conceptId: meta.conceptId,
                isOwned: true,
                entitlementId: ent.id,
                storeProductId: ent.productId,
                featureType: ent.featureType
            )
            let key = ownedDedupeKey(meta: meta, ent: ent)
            // Keep the best streaming candidate via a DETERMINISTIC total order (ownedEntitlementBetter),
            // independent of the PSN entitlements response order, so the catalog is stable across
            // refreshes (cross-buy titles with equal stream rank routinely tie). Mirrors Qt
            // ps5CloudOwnedEntitlementBetter in cloudcatalogbackend.cpp.
            if let existingEnt = byKeyEnt[key] {
                if ownedEntitlementBetter(ent, existingEnt) {
                    byKey[key] = game
                    byKeyEnt[key] = ent
                }
            } else {
                byKey[key] = game
                byKeyEnt[key] = ent
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
            // Inert in practice: PSN entitlements carry no conceptId (see findCatalogIndexForOwned note), so this
            // platform-blind concept lookup almost never fires; owned games match by exact id above.
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

        // QMap iteration is sorted by dedupe key; merge depends on :ps4 before :ps5 (cloudcatalogbackend.cpp).
        return byKey.keys.sorted().compactMap { byKey[$0] }
    }

    // Edition identity = conceptId + PLATFORM (matching the catalog's edition key), so a cross-gen
    // title owned on both PS4 and PS5 stays as two separate library entries instead of collapsing
    // into one. Same-platform duplicate SKUs (a remaster's add-ons) still merge.
    private static func ownedDedupeKey(meta: CloudGame, ent: PsCloudEntitlement) -> String {
        // Platform from the ENTITLEMENT's structured platform_id (NOT the matched catalog row's, and NOT
        // a product-id prefix): a cross-buy title gives the user up to three entitlements that resolve to
        // ONE catalog row -- a clean PS4 (CUSA, platform_id ps4), a real PS5 (PPSA, platform_id ps5), and
        // a PS5-wrapper PS4 license (id CUSA, product_id ...PPSA..., platform_id ps4). The real PS5 and
        // the PS5-wrapper PS4 must stay in SEPARATE buckets (ps5 vs ps4) so the PS5 entitlement is not
        // discarded by a same-key collision; the merge then stamps the PS5 card from the PS5 entitlement
        // and DROPS the PS4 wrapper (it can't claim a PS5 card). Collapsing by the catalog row's platform
        // instead let the wrapper win and threw away the real PS5 license (the Blood Omen / GTA V PS5
        // streaming failure).
        if !meta.conceptId.isEmpty { return "c:\(meta.conceptId):\(entPlatform(ent))" }
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

    // Is this a "Game Streaming" (GS) package? PSN labels the cloud-streamable SKU *GS (e.g. PS4GS) and
    // the installable download *GD (PS4GD / PSGD). For a cross-buy title the GS entitlement carries the
    // clean, streamable product for its platform, while the GD cross-buy SKU can carry a cross-gen
    // *wrapper* product. So when two same-platform SKUs collapse to one edition, the GS SKU is the right
    // streaming candidate. Uses the structured package_type field -- no product-id prefix guessing.
    private static func isStreamingPackage(_ ent: PsCloudEntitlement) -> Bool {
        ent.packageType.hasSuffix("GS")
    }

    // Deterministic total order over owned entitlements that collapse to the same edition (conceptId +
    // platform). MUST be independent of the PSN entitlements response order so the assembled catalog is
    // stable across refreshes. Returns true if `cand` should replace `cur` as the edition's
    // representative. Signals, in priority order, all from structured API fields: (1) higher stream rank
    // (canonical full-game product); (2) the cloud-streaming (GS) package over a download (GD) SKU;
    // (3) stable unique sku_id, then product_id, then entitlement id, to guarantee one deterministic
    // winner. Mirrors Qt ps5CloudOwnedEntitlementBetter (cloudcatalogbackend.cpp).
    private static func ownedEntitlementBetter(_ cand: PsCloudEntitlement, _ cur: PsCloudEntitlement) -> Bool {
        let rc = ownedStreamRank(cand), ru = ownedStreamRank(cur)
        if rc != ru { return rc > ru }
        let gc = isStreamingPackage(cand), gu = isStreamingPackage(cur)
        if gc != gu { return gc }
        if cand.skuId != cur.skuId { return cand.skuId < cur.skuId }
        if cand.productId != cur.productId { return cand.productId < cur.productId }
        return cand.id < cur.id
    }

    // conceptId + platform for an owned/catalog game. Platform comes from the canonical serviceType
    // (pscloud == ps5, psnow == ps4-class) -- filled for owned cards from the entitlement's
    // platform_id -- so an owned cross-buy PS4 license whose product_id is a PS5-looking wrapper
    // buckets to the PS4 edition, not the PS5 one. Falls back to the product-id token when serviceType
    // is absent (non-owned imagic browse rows, whose ids are clean).
    private static func conceptPlatformKey(_ game: CloudGame) -> String {
        guard !game.conceptId.isEmpty else { return "" }
        return "\(game.conceptId)|\(platformClassForCard(game))"
    }

    /// Platform CLASS of a catalog/owned card (ps5 or ps4). serviceType is canonical when present;
    /// non-owned imagic browse rows may only have a clean product-id token (PPSA/CUSA). Mirrors Qt
    /// gamePlatformStructured + ps5CloudPlatformToken fallback in mergeOwnedIntoBrowseCatalog.
    private static func platformClassForCard(_ game: CloudGame) -> String {
        let st = game.serviceType.lowercased()
        if st == "pscloud" { return "ps5" }
        if st == "psnow" { return "ps4" }
        return platformToken(game.storeProductId.isEmpty ? game.id : game.storeProductId)
    }

    /// Rebuild a catalog row after merge stamping (serviceType is let, so we must replace the struct).
    private static func stampMergedCard(_ existing: CloudGame, from owned: CloudGame, serviceType: String) -> CloudGame {
        CloudGame(
            productId: existing.id,
            name: existing.name,
            imageUrl: existing.imageUrl,
            landscapeImageUrl: existing.landscapeImageUrl,
            platform: existing.platform,
            serviceType: serviceType,
            conceptUrl: existing.conceptUrl,
            conceptId: existing.conceptId,
            isOwned: true,
            entitlementId: owned.entitlementId.isEmpty ? existing.entitlementId : owned.entitlementId,
            storeProductId: owned.storeProductId.isEmpty ? existing.storeProductId : owned.storeProductId,
            plusCatalog: existing.plusCatalog,
            featureType: owned.featureType != 0 ? owned.featureType : existing.featureType,
            category: existing.category
        )
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

        // Products the user FULLY owns (feature_type != 1). A trial (ft1) is kept as its own card ONLY
        // when the full game is NOT owned; when the SAME product is also held as a full license (common
        // for F2P cross-buy titles: a PS4 trial whose product_id is the PS5 PPSA wrapper, e.g. Trackmania
        // / Super Animal Royale / Fantasy Beauties) the trial card is redundant AND broken -- it routes
        // to Kamaji (psnow) while carrying a PS5 product. Suppress those trials. Order-independent
        // pre-pass. Mirrors Qt mergeOwnedIntoBrowseCatalog (cloudcatalogbackend.cpp).
        let fullyOwnedProductIds = Set(
            ownedCrossRef.filter { $0.featureType != 1 }.map { $0.id }.filter { !$0.isEmpty }
        )

        // Process pscloud (PS5) owned claims BEFORE psnow (PS3/PS4). A PS5 (pscloud) claim is
        // authoritative and stamps the PS5 browse row in place; doing it first means the row is already
        // owned by the time any PS4 cross-buy license (whose product_id is the SAME PPSA wrapper) is
        // seen, so the wrapper is dropped cleanly instead of appending a duplicate / orphaning the
        // browse row as a "ghost". Deterministic, order-independent. Stable partition. (Qt parity.)
        let ownedOrdered = ownedCrossRef.filter { $0.serviceType.lowercased() == "pscloud" }
            + ownedCrossRef.filter { $0.serviceType.lowercased() != "pscloud" }

        for owned in ownedOrdered {
            let isTrialTier = owned.featureType == 1
            // A trial whose product is also fully owned is superseded by the full license -- drop it.
            if isTrialTier && fullyOwnedProductIds.contains(owned.id) { continue }
            let catalogMatch = isTrialTier ? -1 : findCatalogIndexForOwned(owned, catalogIndex: catalogIndex)
            if catalogMatch >= 0 {
                let existing = games[catalogMatch]
                let ownedService = owned.serviceType.lowercased()
                let existingService = existing.serviceType.lowercased()
                let existingClass = platformClassForCard(existing)
                // The card's stream identity must come from the OWNED entitlement of THIS card's
                // platform. Cross-buy editions share one product_id (Red Dead's PS4 license and PS5
                // license both carry ...PPSA30528...), so matching by product_id alone lets a PS4
                // entitlement land on the PS5 card. Rule: a PS5 (pscloud) claim is authoritative; a
                // PS4/PS3 (psnow) entitlement must NEVER overwrite a PS5-class card. Mirrors Qt
                // mergeOwnedIntoBrowseCatalog exactly (cloudcatalogbackend.cpp).
                if ownedService == "pscloud" {
                    games[catalogMatch] = stampMergedCard(existing, from: owned, serviceType: "pscloud")
                    continue
                }
                if ownedService == "psnow" && existingService != "pscloud" && existingClass != "ps5" {
                    games[catalogMatch] = stampMergedCard(existing, from: owned, serviceType: "psnow")
                    continue
                }
                // psnow entitlement whose matched card is PS5-class: this is a PS4 CROSS-BUY license
                // whose product_id is the shared PS5 (PPSA) wrapper. DROP it (Qt parity): the PS5 card
                // is claimed by the PS5 (pscloud) license processed first, the real PS4 variant matches
                // its own CUSA row independently, and appending here would create a bogus duplicate /
                // ghost that can't stream (a PS5 cloud product needs a PS5 entitlement).
                if ownedService == "psnow" { continue }
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
        // Structured platform from entitlement_attributes[].platform_id. Sony also returns a numeric
        // top-level "serviceType" here that is unrelated to our routing -- we never read it.
        var platformId = ""
        if let attrs = obj["entitlement_attributes"] as? [[String: Any]] {
            // Scan for the first RECOGNIZED platform (ps5/ps4/ps3); skip any unknown value so a junk
            // attribute ordered first can't shadow a real one (mirrors Qt ownedEntitlementServiceType).
            for a in attrs {
                guard let p = (a["platform_id"] as? String)?.lowercased() else { continue }
                if p == "ps5" || p == "ps4" || p == "ps3" { platformId = p; break }
            }
        }
        return PsCloudEntitlement(
            id: id,
            productId: (obj["product_id"] as? String) ?? "",
            skuId: (obj["sku_id"] as? String) ?? "",
            activeFlag: (obj["active_flag"] as? Bool) ?? false,
            packageType: (gameMeta["package_type"] as? String) ?? "",
            name: name,
            conceptId: conceptId,
            featureType: (obj["feature_type"] as? NSNumber)?.intValue ?? 0,
            platformId: platformId
        )
    }

    // Canonical stream service for an owned entitlement from its structured platform_id:
    // ps5 -> pscloud (cronos), ps4/ps3 -> psnow (Kamaji). Empty if platform_id is absent.
    static func entServiceType(_ ent: PsCloudEntitlement) -> String {
        switch ent.platformId {
        case "ps5": return "pscloud"
        case "ps4", "ps3": return "psnow"
        default: return ""
        }
    }

    // Stream backend for an owned entitlement, with Qt's exact fallback (streamServiceTypeForGame):
    // 1) the structured platform_id (authoritative -- a cross-buy PS4 wrapper has platform_id "ps4"
    //    even though its product_id is a PS5-looking PPSA, so it correctly stays psnow/Kamaji); else
    // 2) the entitlement's own product-id TOKEN (CUSA = PS4/Kamaji, PPSA = PS5/cronos). PS Plus classics
    //    (e.g. Blood Omen, product ...PPSA24270...) carry NO platform_id and match a PS Now/Apollo
    //    (psnow) browse row by concept -- inheriting meta.serviceType would mis-route them to Kamaji and
    //    fail. The product-id token routes them to cronos like Qt. Only when neither token is present do
    //    we fall back to the matched row's serviceType.
    private static func ownedServiceType(_ ent: PsCloudEntitlement, _ meta: CloudGame) -> String {
        let svc = entServiceType(ent)
        if !svc.isEmpty { return svc }
        let tok = ent.productId + " " + ent.id
        if tok.contains("CUSA") { return "psnow" }
        if tok.contains("PPSA") { return "pscloud" }
        return meta.serviceType
    }

    // Platform class (ps5/ps4) for owned dedupe, from platform_id; falls back to the product-id token
    // only when platform_id is absent (never relied on for the CUSA/PPSA wrapper-prone cross-buy case,
    // which always carries a platform_id).
    private static func entPlatform(_ ent: PsCloudEntitlement) -> String {
        switch ent.platformId {
        case "ps5": return "ps5"
        case "ps4", "ps3": return "ps4"
        default: return platformToken(ent.productId)
        }
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

    // IMPORTANT (this cost real debugging time): PSN *owned entitlements* carry NO conceptId in practice
    // -- their game_meta is just { name, package_type, icon_url }. So every conceptId-based step below is
    // effectively INERT for owned games: an owned entitlement resolves to a catalog row by EXACT ID ONLY
    // (product_id -> entitlement id -> store product id). The conceptId machinery's live job is catalog-row
    // edition dedup (edition / conceptPlatformKey), NOT owned->catalog matching.
    //
    // Also: a PS4 CROSS-BUY license can carry a PS5-looking PPSA *product_id* wrapper while its real PS4
    // component is the CUSA *id* (platform_id stays "ps4"). product_id is matched against the catalog FIRST,
    // so such a ps4 license can land on a PS5 (PPSA) row. NEVER infer platform from a product-id prefix for
    // owned entitlements -- use the platform_id-derived serviceType (pscloud=PS5, psnow=PS3/PS4). The merge
    // guard keys on the matched card's platform CLASS so a ps4 license can never corrupt a PS5 card.
    private static func findCatalogIndexForOwned(_ owned: CloudGame, catalogIndex: CatalogIndex) -> Int {
        // Mirrors Qt findCatalogIndexForOwned: product_id, entitlement id, store product id, concept+platform.
        let productId = owned.id
        if !productId.isEmpty, let idx = catalogIndex.byProductId[productId] { return idx }
        if !owned.entitlementId.isEmpty, owned.entitlementId != productId,
           let idx = catalogIndex.byProductId[owned.entitlementId] { return idx }
        if !owned.storeProductId.isEmpty, let idx = catalogIndex.byProductId[owned.storeProductId] { return idx }
        // Match by conceptId + platform so an owned PS4 edition does not match a PS5-only catalog
        // entry (and vice-versa); cross-gen editions stay as separate library cards.
        let conceptKey = conceptPlatformKey(owned)
        if !conceptKey.isEmpty, let idx = catalogIndex.byConceptId[conceptKey] { return idx }
        return -1
    }

    // MARK: - Unified-page assembly: acquisition tag + concept-sibling streamability gate

    static let CATEGORY_OWNED = "owned"
    static let CATEGORY_STREAMABLE = "streamable"
    static let CATEGORY_PURCHASEABLE = "purchaseable"

    static func categoryFor(_ game: CloudGame) -> String {
        if game.isOwned { return CATEGORY_OWNED }
        if game.streamServiceType == "psnow" { return CATEGORY_STREAMABLE }
        return CATEGORY_PURCHASEABLE
    }

    /// Concept-sibling streamability gate index, built from the ACTUAL streamable catalog.
    struct StreamabilityIndex {
        private let productKeys: Set<String>
        private let streamableConceptIds: Set<String>

        init(
            apolloCatalog: [CloudGame],
            imagicBrowse: [CloudGame],
            imagicConceptRows: [CloudGame]
        ) {
            var keys = Set<String>()
            var conceptIds = Set<String>()

            func addProduct(_ productId: String) {
                guard !productId.isEmpty else { return }
                keys.insert(productId)
                if let stable = PsCloudOwnership.productIdStableKey(productId) {
                    keys.insert(stable)
                }
            }

            for game in apolloCatalog { addProduct(game.id) }
            for game in imagicBrowse {
                addProduct(game.id)
                if !game.conceptId.isEmpty { conceptIds.insert(game.conceptId) }
            }
            for row in imagicConceptRows {
                guard !row.conceptId.isEmpty else { continue }
                let rowKeys = [row.id, PsCloudOwnership.productIdStableKey(row.id)].compactMap { $0 }
                if rowKeys.contains(where: { keys.contains($0) }) {
                    conceptIds.insert(row.conceptId)
                }
            }

            productKeys = keys
            streamableConceptIds = conceptIds
        }

        func isStreamable(_ game: CloudGame) -> Bool {
            for p in [game.id, game.storeProductId, game.entitlementId] {
                guard !p.isEmpty else { continue }
                if productKeys.contains(p) { return true }
                if let stable = PsCloudOwnership.productIdStableKey(p), productKeys.contains(stable) { return true }
            }
            return !game.conceptId.isEmpty && streamableConceptIds.contains(game.conceptId)
        }
    }

    static func applyStreamabilityGate(_ games: [CloudGame], index: StreamabilityIndex) -> [CloudGame] {
        var kept: [CloudGame] = []
        var dropped = 0
        for game in games {
            if !game.isOwned || index.isStreamable(game) {
                kept.append(game)
            } else {
                dropped += 1
                os_log(.info, log: ownershipLog,
                       "streamability gate: dropped owned non-streamable '%{public}s' (%{public}s)",
                       game.name, game.id)
            }
        }
        if dropped > 0 {
            os_log(.info, log: ownershipLog,
                   "streamability gate: dropped %d owned non-streamable titles", dropped)
        }
        return kept
    }
}
