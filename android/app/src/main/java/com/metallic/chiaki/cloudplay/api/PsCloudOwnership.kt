// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.model.CloudGame
import org.json.JSONObject

object PsCloudOwnership
{
	private const val TAG = "PsCloudOwnership"
	const val PAGE_SIZE = 300
	const val PAGE_COOLDOWN_MS = 100L

	data class Entitlement(
		val id: String,
		val productId: String,
		val skuId: String,      // PSN sku_id -- stable unique key for deterministic dedupe tie-breaking
		val activeFlag: Boolean,
		val packageType: String,
		val name: String,
		val conceptId: String,
		val featureType: Int,   // PSN feature_type: 3=full game, 1=trial/free, 0=add-on/DLC
		// Structured platform from entitlement_attributes[].platform_id ("ps5"/"ps4"/"ps3"). The
		// authoritative stream-backend signal -- NOT a CUSA/PPSA id prefix, since a cross-buy PS4
		// license can carry a PS5-looking product_id wrapper (Red Dead's PS4 license has ...PPSA30528).
		val platformId: String = ""
	)

	private data class CatalogIndex(
		val byProductId: MutableMap<String, Int>,
		val byConceptId: MutableMap<String, Int>
	)

	fun filterOwnedPs5Games(entitlements: List<Entitlement>): List<Entitlement>
	{
		return entitlements.filter { ent ->
			// Previously required packageType == "PSGD" (PS5 only), which dropped owned PS4
			// titles (e.g. God of War 2018) and PS3 titles. Accept every active game entitlement;
			// streamability is enforced downstream by the cross-reference (deduped by conceptId),
			// so non-streamable / add-on entitlements are harmlessly dropped there.
			ent.activeFlag &&
				!ent.productId.startsWith("IP") &&
				!ent.productId.startsWith("SUB") &&
				// Hide EXTRAS: feature_type==0 is DLC/add-ons/themes/avatars/tracks, never a base game
				// (games are ft 1=trial/free or 3/5=full). Safe -- it can never hide a game.
				ent.featureType != 0
		}
	}

	/** Normalize a conceptId (imagic encodes it as a number) to a non-empty string, else "". */
	private fun conceptIdString(value: Any?): String = when (value)
	{
		is Number -> value.toLong().let { if (it > 0) it.toString() else "" }
		is String -> value
		else -> ""
	}

	fun parseEntitlement(obj: JSONObject): Entitlement?
	{
		val id = obj.optString("id", "")
		if (id.isEmpty()) return null
		val gameMeta = obj.optJSONObject("game_meta") ?: JSONObject()
		val name = gameMeta.optString("name", id)
		val conceptId = conceptIdString(gameMeta.opt("conceptId"))
			.ifEmpty { conceptIdString(gameMeta.opt("concept_id")) }
			.ifEmpty { conceptIdString(obj.opt("conceptId")) }
		// Structured platform from entitlement_attributes[].platform_id. Sony also returns a numeric
		// top-level "serviceType" here that is unrelated to our routing -- we never read it.
		var platformId = ""
		val attrs = obj.optJSONArray("entitlement_attributes")
		if (attrs != null)
		{
			// Scan for the first RECOGNIZED platform (ps5/ps4/ps3); skip any unknown value so a junk
			// attribute ordered first can't shadow a real one (mirrors Qt ownedEntitlementServiceType).
			for (i in 0 until attrs.length())
			{
				val p = attrs.optJSONObject(i)?.optString("platform_id", "")?.lowercase() ?: ""
				if (p == "ps5" || p == "ps4" || p == "ps3") { platformId = p; break }
			}
		}
		return Entitlement(
			id = id,
			productId = obj.optString("product_id", ""),
			skuId = obj.optString("sku_id", ""),
			activeFlag = obj.optBoolean("active_flag", false),
			packageType = gameMeta.optString("package_type", ""),
			name = name,
			conceptId = conceptId,
			featureType = obj.optInt("feature_type", 0),
			platformId = platformId
		)
	}

	/** Canonical stream service for an owned entitlement from its structured platform_id:
	 *  ps5 -> pscloud (cronos), ps4/ps3 -> psnow (Kamaji). Empty if platform_id is absent. */
	fun entServiceType(ent: Entitlement): String = when (ent.platformId)
	{
		"ps5" -> "pscloud"
		"ps4", "ps3" -> "psnow"
		else -> ""
	}

	/** Stream backend for an owned entitlement, with Qt's exact fallback (streamServiceTypeForGame):
	 *  1) the structured platform_id (authoritative -- a cross-buy PS4 wrapper has platform_id "ps4"
	 *     even though its product_id is a PS5-looking PPSA, so it correctly stays psnow/Kamaji); else
	 *  2) the entitlement's own product-id TOKEN (CUSA = PS4/Kamaji, PPSA = PS5/cronos). PS Plus classics
	 *     (e.g. Blood Omen, product ...PPSA24270...) carry NO platform_id and match a PS Now/Apollo
	 *     (psnow) browse row by concept -- inheriting meta.serviceType would mis-route them to Kamaji and
	 *     fail. The product-id token routes them to cronos like Qt. Only when neither token is present do
	 *     we fall back to the matched row's serviceType. */
	private fun ownedServiceType(ent: Entitlement, meta: CloudGame): String
	{
		val svc = entServiceType(ent)
		if (svc.isNotEmpty()) return svc
		val tok = ent.productId + " " + ent.id
		return when
		{
			tok.contains("CUSA") -> "psnow"
			tok.contains("PPSA") -> "pscloud"
			else -> meta.serviceType
		}
	}

	/** Platform class (ps5/ps4) for owned dedupe, from platform_id; falls back to the product-id token
	 *  only when platform_id is absent (never relied on for the CUSA/PPSA wrapper-prone cross-buy case,
	 *  which always carries a platform_id). */
	private fun entPlatform(ent: Entitlement): String = when (ent.platformId)
	{
		"ps5" -> "ps5"
		"ps4", "ps3" -> "ps4"
		else -> platformToken(ent.productId)
	}

	fun crossReferenceOwnedGames(
		filteredEntitlements: List<Entitlement>,
		publicCatalog: List<CloudGame>,
		plusLibrarySupplement: List<CloudGame> = emptyList(),
		productIdAliases: Map<String, String> = emptyMap(),
		componentIdsByProductId: Map<String, List<String>> = emptyMap(),
	): List<CloudGame>
	{
		val catalogMap = catalogMapFirstWins(publicCatalog)
		for ((alias, canonical) in productIdAliases)
		{
			if (alias in catalogMap)
				continue
			catalogMap[canonical]?.let { catalogMap[alias] = it }
		}
		val supplementMap = catalogMapFirstWins(plusLibrarySupplement)
		val browseStableKey = buildStableKeyIndex(publicCatalog)
		val supplementStableKey = buildStableKeyIndex(plusLibrarySupplement)
		val browseByConcept = buildConceptIdIndex(publicCatalog)
		val supplementByConcept = buildConceptIdIndex(plusLibrarySupplement)
		val byKey = linkedMapOf<String, CloudGame>()
		val byKeyEnt = mutableMapOf<String, Entitlement>()

		// Enrich one matched catalog row into an owned CloudGame and dedupe it into byKey, keeping OUR
		// convention (conceptId+PLATFORM dedupe, canonical-entitlement rank). Called once for a direct
		// match, or once per component for a bundle (upstream PR #15 bundle-sibling matching).
		fun emit(meta: CloudGame, ent: Entitlement)
		{
			val displayName = meta.name.ifEmpty { ent.name }
			// The owned card's serviceType comes from the ENTITLEMENT's platform_id (pscloud == PS5,
			// psnow == PS3/PS4), not the matched catalog row's: a cross-buy PS4 license can match a PS5
			// catalog row by shared product_id, but it must still route as PS4/Kamaji.
			val ownedService = ownedServiceType(ent, meta)
			// Qt emitOwned: productId = entitlement.product_id (NOT catalog meta.productId).
			val streamProductId = ent.productId.ifEmpty { meta.productId }
			val game = CloudGame(
				productId = streamProductId,
				name = displayName,
				imageUrl = meta.imageUrl,
				landscapeImageUrl = meta.landscapeImageUrl,
				thumbnailUrl = meta.thumbnailUrl,
				platform = meta.platform,
				serviceType = ownedService,
				conceptUrl = meta.conceptUrl,
				conceptId = meta.conceptId,
				isOwned = true,
				entitlementId = ent.id,
				storeProductId = ent.productId,
				plusCatalog = meta.plusCatalog,
				featureType = ent.featureType,
				category = meta.category
			)
			val key = ownedDedupeKey(meta, ent)
			// Keep the best streaming candidate via a DETERMINISTIC total order (ownedEntitlementBetter),
			// independent of the PSN entitlements response order, so the catalog is stable across
			// refreshes (cross-buy titles with equal stream rank routinely tie). Mirrors Qt
			// ps5CloudOwnedEntitlementBetter in cloudcatalogbackend.cpp.
			val existingEnt = byKeyEnt[key]
			if (existingEnt == null || ownedEntitlementBetter(ent, existingEnt))
			{
				byKey[key] = game
				byKeyEnt[key] = ent
			}
		}

		for (ent in filteredEntitlements)
		{
			val stable = productIdStableKey(ent.productId)
			val entStable = productIdStableKey(ent.id)
			val skipStableDemo = ent.name.contains("demo", ignoreCase = true)
			val meta = when {
				ent.productId.isNotEmpty() && catalogMap.containsKey(ent.productId) ->
					catalogMap[ent.productId]
				ent.id.isNotEmpty() && catalogMap.containsKey(ent.id) ->
					catalogMap[ent.id]
				// Inert in practice: PSN entitlements carry no conceptId (see findCatalogIndexForOwned note), so this
				// platform-blind concept lookup almost never fires; owned games match by exact id above.
				// conceptId is region-stable; product IDs are region-prefixed (EP9000 vs UP9000).
				ent.conceptId.isNotEmpty() && browseByConcept.containsKey(ent.conceptId) ->
					browseByConcept[ent.conceptId]
				ent.conceptId.isNotEmpty() && supplementByConcept.containsKey(ent.conceptId) ->
					supplementByConcept[ent.conceptId]
				ent.productId.isNotEmpty() && ent.id == ent.productId
					&& supplementMap.containsKey(ent.productId) ->
					supplementMap[ent.productId]
				stable != null && !skipStableDemo && browseStableKey.containsKey(stable) ->
					browseStableKey[stable]
				stable != null && !skipStableDemo && supplementStableKey.containsKey(stable) ->
					supplementStableKey[stable]
				// Stable-key match on the ENTITLEMENT id (upstream PR #15): catches cross-gen / upgrade
				// entitlement ids whose stable key matches a catalog row even when product_id did not.
				entStable != null && !skipStableDemo && browseStableKey.containsKey(entStable) ->
					browseStableKey[entStable]
				entStable != null && !skipStableDemo && supplementStableKey.containsKey(entStable) ->
					supplementStableKey[entStable]
				else -> null
			}

			if (meta != null)
			{
				emit(meta, ent)
				continue
			}

			// Bundle-sibling expansion (upstream PR #15): a bundle entitlement (e.g. RE7 Gold) has no
			// direct catalog row, but its component entitlement ids each map to a component game.
			val seenPids = mutableSetOf<String>()
			for (siblingId in componentIdsByProductId[ent.productId] ?: emptyList())
			{
				val siblingMeta = when {
					catalogMap.containsKey(siblingId) -> catalogMap[siblingId]
					supplementMap.containsKey(siblingId) -> supplementMap[siblingId]
					else -> {
						val s2 = productIdStableKey(siblingId)
						if (s2 != null && !skipStableDemo) browseStableKey[s2] ?: supplementStableKey[s2] else null
					}
				} ?: continue
				if (siblingMeta.productId.isEmpty() || seenPids.contains(siblingMeta.productId)) continue
				seenPids.add(siblingMeta.productId)
				emit(siblingMeta, ent)
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
		// (a PS5/PPSA disc upgrade must never resolve to a PS4/CUSA SKU), prefer the canonical base game
		// (product_id == entitlement id), and BAIL on genuine ambiguity rather than guess.
		for (key in byKey.keys.toList())
		{
			val game = byKey[key] ?: continue
			if (game.featureType != 5) continue
			val discPid = game.storeProductId
			val discPlatform = platformToken(discPid)
			val discEnt = filteredEntitlements.firstOrNull {
				it.productId == discPid && it.featureType == 5
			} ?: continue
			val discName = normalizeTitle(discEnt.name)
			if (discName.isEmpty()) continue
			val canonical = mutableListOf<String>()   // base-game SKUs (product_id == entitlement id)
			val other = mutableListOf<String>()        // non-canonical full-game SKUs
			for (cand in filteredEntitlements)
			{
				if (cand.featureType != 3) continue
				if (normalizeTitle(cand.name) != discName) continue
				val candPid = cand.productId
				if (candPid.isEmpty() || candPid == discPid) continue
				if (platformToken(candPid) != discPlatform) continue
				if (candPid == cand.id)
				{
					if (candPid !in canonical) canonical.add(candPid)
				}
				else if (candPid !in other)
				{
					other.add(candPid)
				}
			}
			val replacement = when
			{
				canonical.size == 1 -> canonical[0]
				canonical.isEmpty() && other.size == 1 -> other[0]
				else -> null
			}
			if (replacement == null)
			{
				if (canonical.isNotEmpty() || other.isNotEmpty())
					Log.w(TAG, "disc-upgrade rescue: ambiguous candidates for $discName -- leaving disc SKU")
				continue
			}
			byKey[key] = game.copy(storeProductId = replacement)
			Log.i(TAG, "disc-upgrade rescue: $discName $discPid -> $replacement")
		}

		// QMap iteration is sorted by dedupe key; merge depends on :ps4 before :ps5 (cloudcatalogbackend.cpp).
		return byKey.keys.sorted().mapNotNull { byKey[it] }
	}

	// Edition identity = conceptId + PLATFORM (matching the catalog's edition key), so a cross-gen
	// title owned on both PS4 and PS5 stays as two separate library entries instead of collapsing
	// into one. Same-platform duplicate SKUs (a remaster's add-ons) still merge.
	private fun ownedDedupeKey(meta: CloudGame, ent: Entitlement): String
	{
		// Platform from the ENTITLEMENT's structured platform_id (NOT the matched catalog row's, and NOT
		// a product-id prefix): a cross-buy title gives the user up to three entitlements that resolve to
		// ONE catalog row -- a clean PS4 (CUSA, platform_id ps4), a real PS5 (PPSA, platform_id ps5), and
		// a PS5-wrapper PS4 license (id CUSA, product_id ...PPSA..., platform_id ps4). The real PS5 and
		// the PS5-wrapper PS4 must stay in SEPARATE buckets (ps5 vs ps4) so the PS5 entitlement is not
		// discarded by a same-key collision; the merge then stamps the PS5 card from the PS5 entitlement
		// and DROPS the PS4 wrapper (it can't claim a PS5 card). Collapsing by the catalog row's platform
		// instead let the wrapper win and threw away the real PS5 license (the Blood Omen / GTA V PS5
		// streaming failure).
		if (meta.conceptId.isNotEmpty()) return "c:${meta.conceptId}:${entPlatform(ent)}"
		if (meta.productId.isNotEmpty()) return "p:${meta.productId}"
		if (ent.id.isNotEmpty()) return "e:${ent.id}"
		return "u:${meta.productId}:${ent.id}"
	}

	/** Platform token from a product id (CUSA = PS4, PPSA = PS5). */
	private fun platformToken(productId: String): String = when
	{
		productId.contains("PPSA") -> "ps5"
		productId.contains("CUSA") -> "ps4"
		else -> ""
	}

	/** Lowercase, strip trademark/registered/service-mark glyphs, and collapse whitespace so two owned
	 *  entitlements for the same game compare equal across punctuation/spacing differences. */
	private fun normalizeTitle(raw: String): String =
		raw.lowercase()
			.replace("™", "").replace("®", "").replace("℠", "")
			.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")

	/** A full-game entitlement (vs add-on/avatar): base game has a *GD package_type. */
	private fun isFullGameEntitlement(ent: Entitlement): Boolean =
		ent.featureType == 3 || ent.packageType.endsWith("GD")

	// Rank an owned entitlement as THE streaming candidate for its edition (higher = preferred).
	// Bonus/upgrade SKUs collapse to the same conceptId+platform as the base game; package/feature
	// flags don't disambiguate (Death Stranding DC's "Bonus Content" is also PSGD + feature_type 3).
	// The reliable signal: the base game's entitlement id EQUALS its product_id, while bonus/upgrade
	// SKUs carry a different id -- so prefer the canonical full-game entitlement.
	private fun ownedStreamRank(ent: Entitlement): Int
	{
		var rank = 0
		if (ent.productId.isNotEmpty() && ent.productId == ent.id) rank += 4 // canonical base-game SKU
		if (isFullGameEntitlement(ent)) rank += 2
		if (ent.id.isNotEmpty()) rank += 1
		return rank
	}

	// Is this a "Game Streaming" (GS) package? PSN labels the cloud-streamable SKU *GS (e.g. PS4GS) and
	// the installable download *GD (PS4GD / PSGD). For a cross-buy title the GS entitlement carries the
	// clean, streamable product for its platform, while the GD cross-buy SKU can carry a cross-gen
	// *wrapper* product. So when two same-platform SKUs collapse to one edition, the GS SKU is the right
	// streaming candidate. Uses the structured package_type field -- no product-id prefix guessing.
	private fun isStreamingPackage(ent: Entitlement): Boolean = ent.packageType.endsWith("GS")

	// Deterministic total order over owned entitlements that collapse to the same edition (conceptId +
	// platform). MUST be independent of the PSN entitlements response order so the assembled catalog is
	// stable across refreshes. Returns true if `cand` should replace `cur` as the edition's
	// representative. Signals, in priority order, all from structured API fields: (1) higher stream rank
	// (canonical full-game product); (2) the cloud-streaming (GS) package over a download (GD) SKU;
	// (3) stable unique sku_id, then product_id, then entitlement id, to guarantee one deterministic
	// winner. Mirrors Qt ps5CloudOwnedEntitlementBetter (cloudcatalogbackend.cpp).
	private fun ownedEntitlementBetter(cand: Entitlement, cur: Entitlement): Boolean
	{
		val rc = ownedStreamRank(cand); val ru = ownedStreamRank(cur)
		if (rc != ru) return rc > ru
		val gc = isStreamingPackage(cand); val gu = isStreamingPackage(cur)
		if (gc != gu) return gc
		if (cand.skuId != cur.skuId) return cand.skuId < cur.skuId
		if (cand.productId != cur.productId) return cand.productId < cur.productId
		return cand.id < cur.id
	}

	/** conceptId + platform. Platform comes from the canonical serviceType (pscloud == ps5, psnow ==
	 * ps4-class) -- filled for owned cards from the entitlement's platform_id -- so an owned cross-buy
	 * PS4 license whose product_id is a PS5-looking wrapper buckets to the PS4 edition, not the PS5
	 * one. Falls back to the product-id token when serviceType is absent (non-owned imagic rows). */
	private fun conceptPlatformKey(game: CloudGame): String
	{
		if (game.conceptId.isEmpty()) return ""
		return "${game.conceptId}|${platformClassForCard(game)}"
	}

	/** Platform CLASS of a catalog/owned card (ps5 or ps4). Mirrors Qt gamePlatformStructured +
	 *  ps5CloudPlatformToken fallback in mergeOwnedIntoBrowseCatalog. */
	private fun platformClassForCard(game: CloudGame): String
	{
		val st = game.serviceType.lowercase()
		if (st == "pscloud") return "ps5"
		if (st == "psnow") return "ps4"
		return platformToken(game.storeProductId.ifEmpty { game.productId.ifEmpty { game.entitlementId } })
	}

	private fun catalogMapFirstWins(games: List<CloudGame>): MutableMap<String, CloudGame>
	{
		val map = linkedMapOf<String, CloudGame>()
		for (game in games)
		{
			if (game.productId.isNotEmpty() && game.productId !in map)
				map[game.productId] = game
		}
		return map
	}

	/** Tokenize on '-' and '_'; identity is all tokens except the last (store SKU). */
	private fun productIdStableKey(productId: String): String?
	{
		if (productId.isEmpty())
			return null
		val tokens = mutableListOf<String>()
		for (dashPart in productId.split('-'))
		{
			for (token in dashPart.split('_'))
			{
				if (token.isNotEmpty())
					tokens.add(token)
			}
		}
		if (tokens.size < 2)
			return null
		return tokens.dropLast(1).joinToString("|")
	}

	private fun buildStableKeyIndex(games: List<CloudGame>): Map<String, CloudGame>
	{
		val index = linkedMapOf<String, CloudGame>()
		for (game in games)
		{
			val key = productIdStableKey(game.productId) ?: continue
			if (key !in index)
				index[key] = game
		}
		return index
	}

	private fun buildConceptIdIndex(games: List<CloudGame>): Map<String, CloudGame>
	{
		val index = linkedMapOf<String, CloudGame>()
		for (game in games)
		{
			if (game.conceptId.isNotEmpty() && game.conceptId !in index)
				index[game.conceptId] = game
		}
		return index
	}

	fun mergeOwnedIntoBrowseCatalog(
		browseCatalog: List<CloudGame>,
		ownedCrossRef: List<CloudGame>,
		addUnmatched: Boolean = true   // false = only mark ownership (Catalog tab), never add
	): List<CloudGame>
	{
		val games = browseCatalog.toMutableList()
		val catalogIndex = buildCatalogIndex(games)

		// Products the user FULLY owns (feature_type != 1). A trial (ft1) is kept as its own card ONLY
		// when the full game is NOT owned; when the SAME product is also held as a full license (common
		// for F2P cross-buy titles: a PS4 trial whose product_id is the PS5 PPSA wrapper, e.g. Trackmania
		// / Super Animal Royale / Fantasy Beauties) the trial card is redundant AND broken -- it routes
		// to Kamaji (psnow) while carrying a PS5 product. Suppress those trials. Order-independent
		// pre-pass. Mirrors Qt mergeOwnedIntoBrowseCatalog (cloudcatalogbackend.cpp).
		val fullyOwnedProductIds = ownedCrossRef
			.filter { it.featureType != 1 && it.productId.isNotEmpty() }
			.map { it.productId }
			.toHashSet()

		// Process pscloud (PS5) owned claims BEFORE psnow (PS3/PS4). A PS5 (pscloud) claim is
		// authoritative and stamps the PS5 browse row in place; doing it first means the row is already
		// owned by the time any PS4 cross-buy license (whose product_id is the SAME PPSA wrapper) is
		// seen, so the wrapper is dropped cleanly instead of appending a duplicate / orphaning the
		// browse row as a "ghost". Deterministic, order-independent. Stable partition. (Qt parity.)
		val ownedOrdered = ownedCrossRef.filter { it.serviceType.lowercase() == "pscloud" } +
			ownedCrossRef.filter { it.serviceType.lowercase() != "pscloud" }

		for (owned in ownedOrdered)
		{
			val isTrialTier = owned.featureType == 1
			// A trial whose product is also fully owned is superseded by the full license -- drop it.
			if (isTrialTier && fullyOwnedProductIds.contains(owned.productId)) continue
			val catalogMatch = if (isTrialTier) -1 else findCatalogIndexForOwned(owned, catalogIndex)
			if (catalogMatch >= 0)
			{
				val existing = games[catalogMatch]
				val ownedService = owned.serviceType.lowercase()
				val existingService = existing.serviceType.lowercase()
				val existingClass = platformClassForCard(existing)
				// The card's stream identity must come from the OWNED entitlement of THIS card's
				// platform. Cross-buy editions share one product_id (Red Dead's PS4 license and PS5
				// license both carry ...PPSA30528...), so matching by product_id alone lets a PS4
				// entitlement land on the PS5 card. Rule: a PS5 (pscloud) claim is authoritative; a
				// PS4/PS3 (psnow) entitlement must NEVER overwrite a PS5-class card. Mirrors Qt
				// mergeOwnedIntoBrowseCatalog exactly (cloudcatalogbackend.cpp).
				if (ownedService == "pscloud")
				{
					games[catalogMatch] = existing.copy(
						isOwned = true,
						serviceType = "pscloud",
						entitlementId = owned.entitlementId.ifEmpty { existing.entitlementId },
						storeProductId = owned.storeProductId.ifEmpty { existing.storeProductId }
					)
					continue
				}
				if (ownedService == "psnow" && existingService != "pscloud" && existingClass != "ps5")
				{
					games[catalogMatch] = existing.copy(
						isOwned = true,
						serviceType = "psnow",
						entitlementId = owned.entitlementId.ifEmpty { existing.entitlementId },
						storeProductId = owned.storeProductId.ifEmpty { existing.storeProductId }
					)
					continue
				}
				// psnow entitlement whose matched card is PS5-class: this is a PS4 CROSS-BUY license
				// whose product_id is the shared PS5 (PPSA) wrapper. DROP it (Qt parity): the PS5 card
				// is claimed by the PS5 (pscloud) license processed first, the real PS4 variant matches
				// its own CUSA row independently, and appending here would create a bogus duplicate /
				// ghost that can't stream (a PS5 cloud product needs a PS5 entitlement).
				if (ownedService == "psnow") continue
			}

			if (!addUnmatched) continue
			val entry = owned.copy(isOwned = true)
			registerInCatalogIndex(entry, games.size, catalogIndex)
			games.add(entry)
		}

		return games.sortedWith(
			compareByDescending<CloudGame> { it.isOwned }
				.thenBy { it.name.lowercase() }
		)
	}

	fun streamingIdentifier(game: CloudGame): String
	{
		if (game.serviceType.equals("pscloud", ignoreCase = true))
		{
			// PS5/cronos streams the owned PS5 entitlement's OWN id (entitlementId), resolved from the
			// entitlement's platform_id during cross-reference. Canonical SKUs (Red Dead, Alan Wake)
			// have id == product_id == ...PPSA...; a classic whose product_id is a non-streamable
			// wrapper (Blood Omen) has the ...PPSA..SLUS license id. Never a PS4/CUSA cross-buy id --
			// the platform-disciplined merge guarantees a PS5 card carries only PS5 entitlement data.
			if (game.entitlementId.isNotEmpty()) return game.entitlementId
			if (game.storeProductId.isNotEmpty()) return game.storeProductId
		}
		return game.productId
	}

	// Platform that drives the streaming path (PS4 = Kamaji, PS5 = cronos). serviceType is the
	// canonical signal but with one asymmetry: `psnow` is always PS3/PS4-class (set on PS Now browse
	// rows and filled for owned PS3/PS4 cards from platform_id), while `pscloud` is authoritative ONLY
	// for OWNED cards (filled from the entitlement's platform_id) -- non-owned imagic browse rows are
	// blanket-labeled `pscloud` yet include a few PS4 titles, so for those we use the clean id token
	// (PS4 there streams via PS Now/Kamaji, not cronos). Mirrors canonical Qt, whose non-owned imagic
	// rows simply carry no serviceType and so fall through to the same token path.
	fun streamPlatform(game: CloudGame): String
	{
		val st = game.serviceType.lowercase()
		if (st == "psnow") return "ps4"
		// isOwned gate: imagic browse rows are blanket-tagged serviceType="pscloud" (see catalog parse), so
		// only treat "pscloud" as PS5/cronos when actually OWNED; non-owned rows fall through to the product-id
		// token below, routing non-owned PS4 imagic titles to PS Now (matches Qt, whose imagic rows carry no
		// serviceType at all).
		if (st == "pscloud" && game.isOwned) return "ps5"
		val p = game.storeProductId.ifEmpty { game.productId.ifEmpty { game.entitlementId } }
		return when
		{
			p.contains("PPSA") -> "ps5"
			p.contains("CUSA") -> "ps4"
			else -> game.platform.ifEmpty { "ps5" }
		}
	}

	/** Route by the (platform_id-disciplined) streaming platform: PS3/PS4 via Kamaji (psnow), PS5
	 *  direct (pscloud). */
	fun streamServiceType(game: CloudGame): String
	{
		if (game.serviceType.equals("psnow", ignoreCase = true)) return "psnow"
		return if (streamPlatform(game) == "ps4") "psnow" else "pscloud"
	}

	/** Identifier for startCompleteCloudSession: psnow sends the product id (Kamaji converts it
	 *  and acquires via PS Plus); pscloud sends the owned entitlement id (direct). */
	fun streamIdentifier(game: CloudGame): String
	{
		return if (streamServiceType(game) == "psnow") game.productId.ifEmpty { streamingIdentifier(game) }
		else streamingIdentifier(game)
	}

	private fun buildCatalogIndex(games: List<CloudGame>): CatalogIndex
	{
		val byProductId = mutableMapOf<String, Int>()
		val byConceptId = mutableMapOf<String, Int>()
		for (i in games.indices)
			registerInCatalogIndex(games[i], i, CatalogIndex(byProductId, byConceptId))
		return CatalogIndex(byProductId, byConceptId)
	}

	private fun registerInCatalogIndex(game: CloudGame, index: Int, catalogIndex: CatalogIndex)
	{
		if (game.productId.isNotEmpty())
			catalogIndex.byProductId[game.productId] = index
		val conceptKey = conceptPlatformKey(game)
		if (conceptKey.isNotEmpty())
			catalogIndex.byConceptId[conceptKey] = index
		if (game.entitlementId.isNotEmpty() && game.entitlementId != game.productId)
			catalogIndex.byProductId[game.entitlementId] = index
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
	private fun findCatalogIndexForOwned(owned: CloudGame, catalogIndex: CatalogIndex): Int
	{
		if (owned.productId.isNotEmpty() && catalogIndex.byProductId.containsKey(owned.productId))
			return catalogIndex.byProductId.getValue(owned.productId)
		if (owned.entitlementId.isNotEmpty() && owned.entitlementId != owned.productId
			&& catalogIndex.byProductId.containsKey(owned.entitlementId))
			return catalogIndex.byProductId.getValue(owned.entitlementId)
		if (owned.storeProductId.isNotEmpty() && catalogIndex.byProductId.containsKey(owned.storeProductId))
			return catalogIndex.byProductId.getValue(owned.storeProductId)
		// Match by conceptId + platform so an owned PS4 edition does not match a PS5-only catalog
		// entry (and vice-versa); cross-gen editions stay as separate library cards.
		val conceptKey = conceptPlatformKey(owned)
		if (conceptKey.isNotEmpty() && catalogIndex.byConceptId.containsKey(conceptKey))
			return catalogIndex.byConceptId.getValue(conceptKey)
		return -1
	}

	// ---------------------------------------------------------------------------------------------
	// Unified-page assembly: acquisition tag + concept-sibling streamability gate
	// ---------------------------------------------------------------------------------------------

	/** Acquisition tag for the single unified list. */
	const val CATEGORY_OWNED = "owned"
	const val CATEGORY_STREAMABLE = "streamable"
	const val CATEGORY_PURCHASEABLE = "purchaseable"

	/**
	 * One tag per game, priority Owned > Streamable > Purchaseable:
	 *  - owned        -> entitlement resolved to a streamable row (Stream)
	 *  - streamable   -> not owned, PS Now subscription title (PS3/PS4 via Kamaji) (Stream)
	 *  - purchaseable -> not owned, PS Plus catalog title (PS5 via Gaikai) (Add to Library)
	 */
	fun categoryFor(game: CloudGame): String = when
	{
		game.isOwned -> CATEGORY_OWNED
		catalogServiceType(game) == "psnow" -> CATEGORY_STREAMABLE
		else -> CATEGORY_PURCHASEABLE
	}

	// Category is a CATALOG classification, mirroring Qt categoryForGame + streamServiceTypeForGame
	// EXACTLY: the canonical serviceType wins (BOTH "psnow" and "pscloud" short-circuit); only a row
	// with no serviceType derives from the CUSA/PPSA token. Deliberately independent of
	// streamServiceType, whose isOwned gate re-routes non-owned pscloud rows to Kamaji for STREAMING
	// only -- using it here mis-tags non-owned pscloud PS4 titles (e.g. cross-gen indie bundles) as
	// "streamable" instead of "purchaseable".
	private fun catalogServiceType(game: CloudGame): String
	{
		val st = game.serviceType.lowercase()
		if (st == "psnow" || st == "pscloud") return st
		val p = game.storeProductId.ifEmpty { game.productId.ifEmpty { game.entitlementId } }
		return if (p.contains("CUSA")) "psnow" else "pscloud"
	}

	/**
	 * Concept-sibling streamability gate index, built from the ACTUAL streamable catalog:
	 *   - APOLLOROOT (PS3 + PS4) — streamable via Kamaji
	 *   - main imagic browse (streamingSupported=true) — streamable via Gaikai (PS5 + a few PS4)
	 *
	 * A title is streamable iff it OR a same-conceptId sibling resolves into that catalog. This is
	 * deterministic (concept/id membership), so it never "remembers failures" or hides
	 * intermittently. Keeps cross-gen true positives (e.g. owned PS5 Horizon ZD Remastered via its
	 * PS4 sibling in APOLLOROOT) and drops no-streamable-path titles (e.g. FOR HONOR).
	 */
	class StreamabilityIndex(
		apolloCatalog: List<CloudGame>,        // PS Now APOLLOROOT (PS3 + PS4)
		imagicBrowse: List<CloudGame>,         // imagic streamingSupported=true set
		imagicConceptRows: List<CloudGame>,    // browse + supplement: rows carrying conceptId<->productId
	)
	{
		private val productKeys = HashSet<String>()         // raw product ids + stable keys
		private val streamableConceptIds = HashSet<String>()

		init
		{
			fun addProduct(productId: String)
			{
				if (productId.isEmpty()) return
				productKeys.add(productId)
				productIdStableKey(productId)?.let { productKeys.add(it) }
			}
			apolloCatalog.forEach { addProduct(it.productId) }
			imagicBrowse.forEach {
				addProduct(it.productId)
				if (it.conceptId.isNotEmpty()) streamableConceptIds.add(it.conceptId)
			}
			// Bridge APOLLOROOT membership -> conceptId. APOLLOROOT rows carry no conceptId, so use
			// any imagic row (browse OR supplement) whose product id IS in APOLLOROOT to mark its
			// concept streamable. A cross-gen sibling sharing that concept (e.g. the PS5 edition) is
			// then kept even though it lives only in the supplement.
			for (row in imagicConceptRows)
			{
				if (row.conceptId.isEmpty()) continue
				val keys = listOfNotNull(
					row.productId.takeIf { it.isNotEmpty() },
					productIdStableKey(row.productId)
				)
				if (keys.any { it in productKeys })
					streamableConceptIds.add(row.conceptId)
			}
		}

		fun isStreamable(game: CloudGame): Boolean
		{
			for (p in listOf(game.productId, game.storeProductId, game.entitlementId))
			{
				if (p.isEmpty()) continue
				if (p in productKeys) return true
				val stable = productIdStableKey(p)
				if (stable != null && stable in productKeys) return true
			}
			return game.conceptId.isNotEmpty() && game.conceptId in streamableConceptIds
		}
	}

	/**
	 * Drop owned titles with no streamable path (native mode only). Non-owned rows already come
	 * straight from the streamable catalog, so they are never gated.
	 */
	fun applyStreamabilityGate(games: List<CloudGame>, index: StreamabilityIndex): List<CloudGame>
	{
		val kept = mutableListOf<CloudGame>()
		var dropped = 0
		for (game in games)
		{
			if (!game.isOwned || index.isStreamable(game))
				kept.add(game)
			else
			{
				dropped++
				Log.i(TAG, "streamability gate: dropped owned non-streamable '${game.name}' (${game.productId})")
			}
		}
		if (dropped > 0)
			Log.i(TAG, "streamability gate: dropped $dropped owned non-streamable titles")
		return kept
	}
}
