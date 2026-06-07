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
		val activeFlag: Boolean,
		val packageType: String,
		val name: String,
		val conceptId: String,
		val featureType: Int   // PSN feature_type: 3=full game, 1=trial/free, 0=add-on/DLC
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
		return Entitlement(
			id = id,
			productId = obj.optString("product_id", ""),
			activeFlag = obj.optBoolean("active_flag", false),
			packageType = gameMeta.optString("package_type", ""),
			name = name,
			conceptId = conceptId,
			featureType = obj.optInt("feature_type", 0)
		)
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
		val byKeyRank = mutableMapOf<String, Int>()

		// Enrich one matched catalog row into an owned CloudGame and dedupe it into byKey, keeping OUR
		// convention (conceptId+PLATFORM dedupe, canonical-entitlement rank). Called once for a direct
		// match, or once per component for a bundle (upstream PR #15 bundle-sibling matching).
		fun emit(meta: CloudGame, ent: Entitlement)
		{
			val displayName = meta.name.ifEmpty { ent.name }
			val game = meta.copy(
				name = displayName,
				isOwned = true,
				entitlementId = ent.id,
				storeProductId = ent.productId,
				featureType = ent.featureType
			)
			val key = ownedDedupeKey(meta, ent)
			val candidateRank = ownedStreamRank(ent)
			if (byKey[key] == null)
			{
				byKey[key] = game
				byKeyRank[key] = candidateRank
			}
			// Keep the best streaming candidate: the canonical full-game entitlement (its product_id is
			// the real streamable game, not a DLC/bonus product Gaikai rejects).
			else if (candidateRank > (byKeyRank[key] ?: -1))
			{
				byKey[key] = game
				byKeyRank[key] = candidateRank
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

		return byKey.values.toList()
	}

	// Edition identity = conceptId + PLATFORM (matching the catalog's edition key), so a cross-gen
	// title owned on both PS4 and PS5 stays as two separate library entries instead of collapsing
	// into one. Same-platform duplicate SKUs (a remaster's add-ons) still merge.
	private fun ownedDedupeKey(meta: CloudGame, ent: Entitlement): String
	{
		if (meta.conceptId.isNotEmpty()) return "c:${meta.conceptId}:${platformToken(ent.productId)}"
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

	/** conceptId + platform; the owned product id (storeProductId) takes precedence so the owned
	 * edition's platform is used, else the catalog product id. */
	private fun conceptPlatformKey(game: CloudGame): String
	{
		if (game.conceptId.isEmpty()) return ""
		val pid = if (game.storeProductId.isNotEmpty()) game.storeProductId else game.productId
		return "${game.conceptId}|${platformToken(pid)}"
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

		for (owned in ownedCrossRef)
		{
			// Trials / free-to-play (feature_type 1) are kept as their OWN card so the user can Stream
			// the trial/free build, while the full version still shows separately as a not-owned
			// "Add Game" card -- so a trial must NOT collapse into the full-game catalog entry.
			val catalogMatch = if (owned.featureType == 1) -1 else findCatalogIndexForOwned(owned, catalogIndex)
			if (catalogMatch >= 0)
			{
				val existing = games[catalogMatch]
				games[catalogMatch] = existing.copy(
					isOwned = true,
					entitlementId = owned.entitlementId.ifEmpty { existing.entitlementId },
					storeProductId = owned.storeProductId.ifEmpty { existing.storeProductId }
				)
				continue
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
			// Stream the owned PRODUCT id (storeProductId) before the entitlement id: for cross-gen
			// upgrades the entitlement id is the stale original SKU Gaikai has no game for.
			if (game.storeProductId.isNotEmpty()) return game.storeProductId
			if (game.entitlementId.isNotEmpty()) return game.entitlementId
		}
		return game.productId
	}

	// A PlayStation title id encodes its platform: CUSAxxxxx = PS4, PPSAxxxxx = PS5. This is more
	// reliable than the catalog device list and decides the streaming path: PS4 catalog titles go
	// through Kamaji (psnow) to acquire the streaming entitlement, PS5 streams directly (pscloud).
	fun streamPlatform(game: CloudGame): String
	{
		// Prefer the OWNED product id (storeProductId): for a cross-gen title you upgraded, the catalog
		// productId may be the other generation (Alan Wake catalog = PS4 CUSA, but you own the PS5 PPSA).
		val p = game.storeProductId.ifEmpty { game.productId.ifEmpty { game.entitlementId } }
		return when
		{
			p.contains("PPSA") -> "ps5"
			p.contains("CUSA") -> "ps4"
			else -> game.platform.ifEmpty { "ps5" }
		}
	}

	/** Real legacy PS Now games stay psnow; otherwise route by title-id platform. */
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

	private fun findCatalogIndexForOwned(owned: CloudGame, catalogIndex: CatalogIndex): Int
	{
		if (owned.productId.isNotEmpty() && catalogIndex.byProductId.containsKey(owned.productId))
			return catalogIndex.byProductId.getValue(owned.productId)
		if (owned.entitlementId.isNotEmpty() && catalogIndex.byProductId.containsKey(owned.entitlementId))
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
}
