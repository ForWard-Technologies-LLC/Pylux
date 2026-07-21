// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Unified catalog merge/assembly. Faithful C/json-c port of the anonymous
// namespace + assembleUnifiedCatalog in gui/src/cloudcatalogbackend.cpp
// (HEAD >= commit 0063eec2 — device-based isPs5PlatformGame, apollo-skip browse
// dedup, serviceType-first categoryForGame). Emits every contract field the
// clients used to derive (platform, streamServiceType, streamIdentifier,
// entitlementId, storeProductId) and pre-sorts owned-first then by name.

#include "cloudcatalog_internal.h"

#include <chiaki/cloudcatalog.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

// ---------------------------------------------------------------------------
// Tiny string-keyed maps backed by json_object (last-write-wins like QMap):
//   set:   key -> 1            (membership)
//   index: key -> int (idx)    (catalog index)
// json_object_object_add overwrites an existing key, matching QMap::insert.
// ---------------------------------------------------------------------------

static void set_add(struct json_object *set, const char *key)
{
	if(key && *key)
		json_object_object_add(set, key, json_object_new_int(1));
}

static bool set_has(struct json_object *set, const char *key)
{
	struct json_object *v = NULL;
	return key && *key && json_object_object_get_ex(set, key, &v);
}

static void idx_put(struct json_object *map, const char *key, int idx)
{
	if(key && *key)
		json_object_object_add(map, key, json_object_new_int(idx));
}

static int idx_get(struct json_object *map, const char *key)
{
	struct json_object *v = NULL;
	if(key && *key && json_object_object_get_ex(map, key, &v))
		return json_object_get_int(v);
	return -1;
}

// ---------------------------------------------------------------------------
// Field accessors (mirror gameProductId / gameEntitlementId / concept helpers)
// ---------------------------------------------------------------------------

static const char *game_product_id(struct json_object *g)
{
	const char *pid = cc_json_str(g, "productId");
	if(*pid)
		return pid;
	return cc_json_str(g, "product_id");
}

// Returns id if non-empty and != productId, else "".
static const char *game_entitlement_id(struct json_object *g)
{
	const char *id = cc_json_str(g, "id");
	const char *pid = game_product_id(g);
	if(*id && strcmp(id, pid) != 0)
		return id;
	return "";
}

// conceptId may be a JSON number or string; normalize to decimal string.
// Writes into out (>=24). Returns out, empty string if none/<=0.
static const char *concept_id_string(struct json_object *g, const char *key, char *out, size_t out_sz)
{
	out[0] = 0;
	struct json_object *v = NULL;
	if(!g || !json_object_object_get_ex(g, key, &v) || !v)
		return out;
	enum json_type t = json_object_get_type(v);
	if(t == json_type_int || t == json_type_double)
	{
		long long c = json_object_get_int64(v);
		if(c > 0)
			snprintf(out, out_sz, "%lld", c);
	}
	else if(t == json_type_string)
	{
		const char *s = json_object_get_string(v);
		if(s)
			snprintf(out, out_sz, "%s", s);
	}
	return out;
}

// pscloud == ps5 (cronos), psnow == ps4 (Kamaji); "" when serviceType absent.
static const char *platform_structured(struct json_object *g)
{
	const char *st = cc_json_str(g, "serviceType");
	if(cc_ieq(st, "pscloud"))
		return "ps5";
	if(cc_ieq(st, "psnow"))
		return "ps4";
	return "";
}

static const char *platform_token(const char *product_id)
{
	if(cc_contains(product_id, "PPSA"))
		return "ps5";
	if(cc_contains(product_id, "CUSA"))
		return "ps4";
	return "";
}

static bool is_cloud_device_game(struct json_object *g)
{
	struct json_object *devs = cc_json_arr(g, "device");
	if(!devs)
		return false;
	size_t n = json_object_array_length(devs);
	for(size_t i = 0; i < n; i++)
	{
		const char *d = json_object_get_string(json_object_array_get_idx(devs, i));
		if(d && (strcmp(d, "PS5") == 0 || strcmp(d, "PS4") == 0))
			return true;
	}
	return false;
}

static bool device_has(struct json_object *g, const char *want)
{
	struct json_object *devs = cc_json_arr(g, "device");
	if(!devs)
		return false;
	size_t n = json_object_array_length(devs);
	for(size_t i = 0; i < n; i++)
	{
		const char *d = json_object_get_string(json_object_array_get_idx(devs, i));
		if(d && strcmp(d, want) == 0)
			return true;
	}
	return false;
}

static bool is_cloud_streaming_game(struct json_object *g)
{
	if(!cc_json_bool(g, "streamingSupported"))
		return false;
	return is_cloud_device_game(g);
}

// concept|platform edition key. Writes into out (>=96). Returns out (empty if no concept).
static const char *edition_key(struct json_object *g, char *out, size_t out_sz)
{
	out[0] = 0;
	// Big enough for a full product id (36+ chars), not just a numeric conceptId:
	// truncating the productId fallback would collide distinct SKUs sharing a prefix
	// and silently drop/mis-alias one of them.
	char concept[80];
	concept_id_string(g, "conceptId", concept, sizeof(concept));
	if(!*concept)
	{
		// ps5CloudConceptKey falls back to productId when no conceptId
		const char *pid = game_product_id(g);
		if(!*pid)
			return out;
		snprintf(concept, sizeof(concept), "%s", pid);
	}
	const char *platform = platform_structured(g);
	if(!*platform)
		platform = platform_token(game_product_id(g));
	snprintf(out, out_sz, "%s|%s", concept, platform);
	return out;
}

// concept|platform key using storeProductId fallback (conceptPlatformKey).
static const char *concept_platform_key(struct json_object *g, char *out, size_t out_sz)
{
	out[0] = 0;
	char concept[24];
	concept_id_string(g, "conceptId", concept, sizeof(concept));
	if(!*concept)
		return out;
	const char *platform = platform_structured(g);
	if(!*platform)
	{
		const char *pid = cc_json_str(g, "storeProductId");
		if(!*pid)
			pid = game_product_id(g);
		platform = platform_token(pid);
	}
	snprintf(out, out_sz, "%s|%s", concept, platform);
	return out;
}

static bool is_plus_catalog_list(const char *list)
{
	return list && (strcmp(list, "plus-games-list") == 0
		|| strcmp(list, "plus-classics-list") == 0
		|| strcmp(list, "ubisoft-classics-list") == 0
		|| strcmp(list, "plus-monthly-games-list") == 0);
}

// productId stable key: drop last token of the dash/underscore split, join with '|'.
// Writes into out (>=128). Returns out (empty if <2 tokens).
const char *cc_stable_key(const char *product_id, char *out, size_t out_sz)
{
	out[0] = 0;
	if(!product_id || !*product_id)
		return out;
	char tokens[16][64];
	int ntok = 0;
	char buf[256];
	snprintf(buf, sizeof(buf), "%s", product_id);
	// Manual scan, NOT strtok: strtok's process-wide save-pointer is also used by
	// holepunch.c on session threads, and a catalog fetch can run concurrently with
	// a remote-play connect — the two parses would cross-corrupt.
	for(char *p = buf; *p && ntok < 16;)
	{
		while(*p == '-' || *p == '_')
			p++;
		if(!*p)
			break;
		char *start = p;
		while(*p && *p != '-' && *p != '_')
			p++;
		if(*p)
			*p++ = 0;
		snprintf(tokens[ntok++], 64, "%s", start);
	}
	if(ntok < 2)
		return out;
	ntok--; // drop last token
	size_t off = 0;
	for(int i = 0; i < ntok && off < out_sz - 1; i++)
		off += (size_t)snprintf(out + off, out_sz - off, i ? "|%s" : "%s", tokens[i]);
	return out;
}

static const char *stream_service_type(struct json_object *g)
{
	const char *st = cc_json_str(g, "serviceType");
	if(cc_ieq(st, "psnow") || cc_ieq(st, "pscloud"))
		return cc_ieq(st, "psnow") ? "psnow" : "pscloud";
	const char *p = cc_json_str(g, "storeProductId");
	if(!*p)
		p = game_product_id(g);
	if(!*p)
		p = game_entitlement_id(g);
	if(cc_contains(p, "CUSA"))
		return "psnow";
	return "pscloud";
}

static const char *category_for(struct json_object *g)
{
	// PS Now (PS3/PS4) is a subscription catalog: you stream these without owning the
	// game -- an "owned" entitlement here only means the streaming license is already in
	// your library (acquired on a prior stream), not that you bought the game. So always
	// badge PS Now titles "streamable". PS5 (pscloud) you must own to stream, so it stays
	// "owned" (in library) / "purchaseable" (must add). NB: this is display/filtering only;
	// the owned fast-path keys on the separate isOwned flag, which is untouched.
	if(strcmp(stream_service_type(g), "psnow") == 0)
		return "streamable";
	if(cc_json_bool(g, "isOwned"))
		return "owned";
	return "purchaseable";
}

static bool is_ps5_platform(struct json_object *g)
{
	const char *p = game_product_id(g);
	if(!*p)
		p = game_entitlement_id(g);
	if(cc_contains(p, "PPSA"))
		return true;
	return device_has(g, "PS5");
}

// Badge platform from device list + id token only (NOT serviceType, so PS Now
// PS3 classics — psnow, no PS4/PS5 marker — correctly badge as ps3):
//   ps5: PPSA id or device PS5;  ps4: CUSA id or device PS4;  else ps3.
static const char *platform_badge(struct json_object *g)
{
	if(is_ps5_platform(g))
		return "ps5";
	const char *p = game_product_id(g);
	if(!*p)
		p = game_entitlement_id(g);
	if(device_has(g, "PS4") || cc_contains(p, "CUSA"))
		return "ps4";
	return "ps3";
}

// ---------------------------------------------------------------------------
// normalizeApolloGame
// ---------------------------------------------------------------------------

static struct json_object *normalize_apollo_game(struct json_object *raw)
{
	struct json_object *g = cc_json_clone(raw);
	if(!g)
		return NULL;
	if(!cc_json_has(g, "productId"))
	{
		const char *id = cc_json_str(g, "id");
		if(*id)
			cc_json_set_str(g, "productId", id);
	}
	cc_json_set_str(g, "serviceType", "psnow");
	return g;
}

// ---------------------------------------------------------------------------
// Catalog index (byProductId / byConceptId), borrowed games array
// ---------------------------------------------------------------------------

typedef struct
{
	struct json_object *by_product; // key -> int idx
	struct json_object *by_concept; // concept|platform -> int idx
} CatalogIndex;

static void register_in_index(struct json_object *game, int idx, CatalogIndex *ix)
{
	idx_put(ix->by_product, game_product_id(game), idx);
	char ck[64];
	concept_platform_key(game, ck, sizeof(ck));
	if(*ck)
		idx_put(ix->by_concept, ck, idx);
	const char *ent = game_entitlement_id(game);
	if(*ent)
		idx_put(ix->by_product, ent, idx);
}

static int find_index_for_owned(struct json_object *owned, CatalogIndex *ix)
{
	const char *pid = game_product_id(owned);
	int m = idx_get(ix->by_product, pid);
	if(m >= 0)
		return m;
	const char *ent = game_entitlement_id(owned);
	m = idx_get(ix->by_product, ent);
	if(m >= 0)
		return m;
	const char *store = cc_json_str(owned, "storeProductId");
	m = idx_get(ix->by_product, store);
	if(m >= 0)
		return m;
	char ck[64];
	concept_platform_key(owned, ck, sizeof(ck));
	if(*ck)
		return idx_get(ix->by_concept, ck);
	return -1;
}

// ---------------------------------------------------------------------------
// mergeOwnedIntoBrowseCatalog
// ---------------------------------------------------------------------------

static const char *game_name(struct json_object *g)
{
	const char *n = cc_json_str(g, "name");
	if(*n)
		return n;
	struct json_object *meta = cc_json_obj(g, "game_meta");
	return meta ? cc_json_str(meta, "name") : "";
}

static int sort_owned_then_name(const void *a, const void *b)
{
	struct json_object *ao = *(struct json_object *const *)a;
	struct json_object *bo = *(struct json_object *const *)b;
	bool aown = cc_json_bool(ao, "isOwned");
	bool bown = cc_json_bool(bo, "isOwned");
	if(aown != bown)
		return aown ? -1 : 1;
	return strcasecmp(game_name(ao), game_name(bo));
}

// Exact productId duplicates can be created after ownership stamping: two source
// rows that started with different catalog ids may both be rewritten to the owned
// product id. Keep the route the UI can actually use now (owned pscloud first,
// otherwise subscription-streamable psnow) and preserve list membership metadata.
static int contract_game_rank(struct json_object *g)
{
	bool owned = cc_json_bool(g, "isOwned");
	const char *category = cc_json_str(g, "category");
	const char *service = cc_json_str(g, "streamServiceType");
	int rank = owned ? 100 : 0;
	if(strcmp(category, "owned") == 0)
		rank += 40;
	else if(strcmp(category, "streamable") == 0)
		rank += 20;
	if(owned && strcmp(service, "pscloud") == 0)
		rank += 10;
	if(cc_json_int(g, "feature_type") != 1)
		rank += 2; // full game over a trial wrapper for the same exact SKU
	if(cc_json_bool(g, "plusCatalog"))
		rank += 1;
	return rank;
}

// Returns a NEW array and consumes no references from games.
static struct json_object *dedupe_contract_product_ids(struct json_object *games)
{
	struct json_object *out = json_object_new_array();
	struct json_object *index = json_object_new_object();
	size_t n = json_object_array_length(games);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *candidate = json_object_array_get_idx(games, i);
		const char *pid = cc_json_str(candidate, "productId");
		int existing_idx = *pid ? idx_get(index, pid) : -1;
		if(existing_idx < 0)
		{
			if(*pid)
				idx_put(index, pid, (int)json_object_array_length(out));
			json_object_array_add(out, json_object_get(candidate));
			continue;
		}

		struct json_object *existing = json_object_array_get_idx(out, (size_t)existing_idx);
		bool plus_catalog = cc_json_bool(existing, "plusCatalog")
			|| cc_json_bool(candidate, "plusCatalog");
		if(contract_game_rank(candidate) > contract_game_rank(existing))
		{
			cc_json_set_bool(candidate, "plusCatalog", plus_catalog);
			json_object_array_put_idx(out, (size_t)existing_idx, json_object_get(candidate));
		}
		else
		{
			cc_json_set_bool(existing, "plusCatalog", plus_catalog);
		}
	}
	json_object_put(index);
	json_object_array_sort(out, sort_owned_then_name);
	return out;
}

// Returns a NEW array (caller owns). browse and owned are borrowed.
static struct json_object *merge_owned_into_browse(struct json_object *browse,
                                                   struct json_object *owned_cross_ref,
                                                   bool add_unmatched)
{
	struct json_object *games = json_object_new_array();
	if(browse)
	{
		size_t n = json_object_array_length(browse);
		for(size_t i = 0; i < n; i++)
			json_object_array_add(games, cc_json_clone(json_object_array_get_idx(browse, i)));
	}

	CatalogIndex ix = { json_object_new_object(), json_object_new_object() };
	{
		size_t n = json_object_array_length(games);
		for(size_t i = 0; i < n; i++)
			register_in_index(json_object_array_get_idx(games, i), (int)i, &ix);
	}

	// Pre-pass: products fully owned (feature_type != 1) by productId.
	struct json_object *fully_owned = json_object_new_object();
	size_t owned_n = owned_cross_ref ? json_object_array_length(owned_cross_ref) : 0;
	for(size_t i = 0; i < owned_n; i++)
	{
		struct json_object *o = json_object_array_get_idx(owned_cross_ref, i);
		if(!o || cc_json_int(o, "feature_type") == 1)
			continue;
		set_add(fully_owned, game_product_id(o));
	}

	// pscloud-first stable partition.
	struct json_object *ordered = json_object_new_array();
	for(size_t i = 0; i < owned_n; i++)
	{
		struct json_object *o = json_object_array_get_idx(owned_cross_ref, i);
		if(o && cc_ieq(cc_json_str(o, "serviceType"), "pscloud"))
			json_object_array_add(ordered, json_object_get(o));
	}
	for(size_t i = 0; i < owned_n; i++)
	{
		struct json_object *o = json_object_array_get_idx(owned_cross_ref, i);
		if(o && !cc_ieq(cc_json_str(o, "serviceType"), "pscloud"))
			json_object_array_add(ordered, json_object_get(o));
	}

	size_t ord_n = json_object_array_length(ordered);
	for(size_t i = 0; i < ord_n; i++)
	{
		struct json_object *owned_game = json_object_array_get_idx(ordered, i);
		if(!owned_game)
			continue;
		bool is_trial = cc_json_int(owned_game, "feature_type") == 1;
		if(is_trial && set_has(fully_owned, game_product_id(owned_game)))
			continue;
		int match = is_trial ? -1 : find_index_for_owned(owned_game, &ix);

		if(match >= 0)
		{
			struct json_object *existing = json_object_array_get_idx(games, (size_t)match);
			const char *owned_service = cc_json_str(owned_game, "serviceType");
			const char *existing_service = cc_json_str(existing, "serviceType");
			const char *owned_pid = game_product_id(owned_game);
			const char *existing_class = platform_structured(existing);
			if(!*existing_class)
				existing_class = platform_token(game_product_id(existing));

			if(cc_ieq(owned_service, "pscloud"))
			{
				cc_json_set_bool(existing, "isOwned", true);
				const char *owned_id = cc_json_str(owned_game, "id");
				if(*owned_id)
					cc_json_set_str(existing, "id", owned_id);
				if(*owned_pid)
				{
					cc_json_set_str(existing, "product_id", owned_pid);
					cc_json_set_str(existing, "productId", owned_pid);
				}
				cc_json_set_str(existing, "serviceType", "pscloud");
				continue;
			}
			if(cc_ieq(owned_service, "psnow")
				&& !cc_ieq(existing_service, "pscloud")
				&& strcmp(existing_class, "ps5") != 0)
			{
				cc_json_set_bool(existing, "isOwned", true);
				const char *stream_id = game_entitlement_id(owned_game);
				if(*stream_id)
					cc_json_set_str(existing, "id", stream_id);
				cc_json_set_str(existing, "serviceType", "psnow");
				continue;
			}
			if(cc_ieq(owned_service, "psnow"))
				continue; // PS4 cross-buy wrapper on a PS5 card: drop
			// fall through for unstamped owned
		}

		if(!add_unmatched)
			continue;

		struct json_object *entry = cc_json_clone(owned_game);
		cc_json_set_bool(entry, "isOwned", true);
		if(!cc_json_has(entry, "productId") && cc_json_has(entry, "product_id"))
			cc_json_set_str(entry, "productId", cc_json_str(entry, "product_id"));
		register_in_index(entry, (int)json_object_array_length(games), &ix);
		json_object_array_add(games, entry);
	}

	// Cross-buy duplicate suppression. The store can list the same concept under
	// two SKUs on one platform (e.g. a PS1-emulation classic exposed as both a
	// CUSA and a PPSA productId). The imagic edition dedup keys off the productId
	// token (CUSA->ps4, PPSA->ps5), so both survive into browse; once serviceType
	// is stamped they collapse to the same concept|platform. When an owned
	// entitlement claims one SKU, the sibling is left stranded as a purchaseable
	// "Add Game" duplicate of a title you already own (Worms World Party cross-buy).
	// Drop any non-owned row whose concept|platform matches an owned row.
	{
		struct json_object *owned_keys = json_object_new_object();
		size_t n = json_object_array_length(games);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(games, i);
			if(!cc_json_bool(g, "isOwned"))
				continue;
			char ck[64];
			concept_platform_key(g, ck, sizeof(ck));
			if(*ck)
				set_add(owned_keys, ck);
		}
		struct json_object *filtered = json_object_new_array();
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(games, i);
			if(!cc_json_bool(g, "isOwned"))
			{
				char ck[64];
				concept_platform_key(g, ck, sizeof(ck));
				if(*ck && set_has(owned_keys, ck))
					continue; // purchaseable duplicate of an owned title
			}
			json_object_array_add(filtered, json_object_get(g));
		}
		json_object_put(owned_keys);
		json_object_put(games);
		games = filtered;
	}

	// Sort owned-first then name.
	json_object_array_sort(games, sort_owned_then_name);

	json_object_put(fully_owned);
	json_object_put(ordered);
	json_object_put(ix.by_product);
	json_object_put(ix.by_concept);
	return games;
}

// ---------------------------------------------------------------------------
// StreamabilityIndex / applyStreamabilityGate
// ---------------------------------------------------------------------------

typedef struct
{
	struct json_object *product_keys;        // set
	struct json_object *streamable_concepts; // set
} StreamabilityIndex;

static void streamability_add_product(StreamabilityIndex *ix, const char *pid)
{
	if(!pid || !*pid)
		return;
	set_add(ix->product_keys, pid);
	char sk[128];
	cc_stable_key(pid, sk, sizeof(sk));
	if(*sk)
		set_add(ix->product_keys, sk);
}

static StreamabilityIndex streamability_build(struct json_object *apollo,
                                              struct json_object *imagic_browse,
                                              struct json_object *concept_rows)
{
	StreamabilityIndex ix = { json_object_new_object(), json_object_new_object() };
	if(apollo)
	{
		size_t n = json_object_array_length(apollo);
		for(size_t i = 0; i < n; i++)
			streamability_add_product(&ix, game_product_id(json_object_array_get_idx(apollo, i)));
	}
	if(imagic_browse)
	{
		size_t n = json_object_array_length(imagic_browse);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(imagic_browse, i);
			streamability_add_product(&ix, game_product_id(g));
			char concept[24];
			concept_id_string(g, "conceptId", concept, sizeof(concept));
			if(*concept)
				set_add(ix.streamable_concepts, concept);
		}
	}
	if(concept_rows)
	{
		size_t n = json_object_array_length(concept_rows);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *row = json_object_array_get_idx(concept_rows, i);
			char concept[24];
			concept_id_string(row, "conceptId", concept, sizeof(concept));
			if(!*concept)
				continue;
			const char *pid = game_product_id(row);
			char sk[128];
			cc_stable_key(pid, sk, sizeof(sk));
			if(set_has(ix.product_keys, pid) || (*sk && set_has(ix.product_keys, sk)))
				set_add(ix.streamable_concepts, concept);
		}
	}
	return ix;
}

static bool streamability_is_streamable(StreamabilityIndex *ix, struct json_object *g)
{
	const char *ids[3] = { game_product_id(g), cc_json_str(g, "storeProductId"), game_entitlement_id(g) };
	for(int i = 0; i < 3; i++)
	{
		if(!*ids[i])
			continue;
		if(set_has(ix->product_keys, ids[i]))
			return true;
		char sk[128];
		cc_stable_key(ids[i], sk, sizeof(sk));
		if(*sk && set_has(ix->product_keys, sk))
			return true;
	}
	char concept[24];
	concept_id_string(g, "conceptId", concept, sizeof(concept));
	return *concept && set_has(ix->streamable_concepts, concept);
}

static void streamability_fini(StreamabilityIndex *ix)
{
	json_object_put(ix->product_keys);
	json_object_put(ix->streamable_concepts);
}

// ---------------------------------------------------------------------------
// streamIdentifier (contract field): what the streaming layer is handed.
//   pscloud: the entitlement's own id when owned, else the catalog productId.
//   psnow:   the catalog product variant (catalogProductId or productId).
// ---------------------------------------------------------------------------

static const char *stream_identifier(struct json_object *g, const char *stream_service)
{
	if(strcmp(stream_service, "pscloud") == 0)
	{
		const char *id = cc_json_str(g, "id");
		if(cc_json_bool(g, "isOwned") && *id)
			return id;
		return game_product_id(g);
	}
	const char *cat = cc_json_str(g, "catalogProductId");
	if(*cat)
		return cat;
	return game_product_id(g);
}

// ---------------------------------------------------------------------------
// Object maps (string -> borrowed json_object), used by the cross-reference.
// ---------------------------------------------------------------------------

static void objmap_put_first(struct json_object *map, const char *key, struct json_object *obj)
{
	struct json_object *v = NULL;
	if(key && *key && !json_object_object_get_ex(map, key, &v))
		json_object_object_add(map, key, json_object_get(obj));
}

static void objmap_put_last(struct json_object *map, const char *key, struct json_object *obj)
{
	if(key && *key)
		json_object_object_add(map, key, json_object_get(obj));
}

static struct json_object *objmap_get(struct json_object *map, const char *key)
{
	struct json_object *v = NULL;
	if(key && *key && json_object_object_get_ex(map, key, &v))
		return v;
	return NULL;
}

static bool objmap_has(struct json_object *map, const char *key)
{
	return objmap_get(map, key) != NULL;
}

// ---------------------------------------------------------------------------
// cc_extract_cover_image
// ---------------------------------------------------------------------------

const char *cc_extract_cover_image(struct json_object *game_obj, char *out, size_t out_sz)
{
	out[0] = 0;
	struct json_object *imgs = cc_json_arr(game_obj, "images");
	if(imgs)
	{
		size_t n = json_object_array_length(imgs);
		for(size_t i = 0; i < n; i++) // type 10 preferred
		{
			struct json_object *im = json_object_array_get_idx(imgs, i);
			if(cc_json_int(im, "type") == 10)
			{
				const char *u = cc_json_str(im, "url");
				if(*u) { snprintf(out, out_sz, "%s", u); return out; }
			}
		}
		for(size_t i = 0; i < n; i++) // landscape 12/13 fallback
		{
			struct json_object *im = json_object_array_get_idx(imgs, i);
			int t = cc_json_int(im, "type");
			if(t == 12 || t == 13)
			{
				const char *u = cc_json_str(im, "url");
				if(*u) { snprintf(out, out_sz, "%s", u); return out; }
			}
		}
	}
	const char *iu = cc_json_str(game_obj, "imageUrl");
	if(*iu)
		snprintf(out, out_sz, "%s", iu);
	return out;
}

// ---------------------------------------------------------------------------
// cc_merge_imagic_list
// ---------------------------------------------------------------------------

void cc_merge_imagic_list(const char *category_list, struct json_object *list_doc,
                          struct json_object *games_by_edition, struct json_object *supplement,
                          struct json_object *aliases, int *total_seen)
{
	bool plus_catalog = is_plus_catalog_list(category_list);
	if(!list_doc || json_object_get_type(list_doc) != json_type_array)
		return;
	size_t ncat = json_object_array_length(list_doc);
	for(size_t c = 0; c < ncat; c++)
	{
		struct json_object *cat = json_object_array_get_idx(list_doc, c);
		struct json_object *games = cc_json_arr(cat, "games");
		if(!games)
			continue;
		size_t ng = json_object_array_length(games);
		if(total_seen)
			*total_seen += (int)ng;
		for(size_t i = 0; i < ng; i++)
		{
			struct json_object *g = json_object_array_get_idx(games, i);
			if(!g || json_object_get_type(g) != json_type_object)
				continue;
			if(!is_cloud_device_game(g))
				continue;

			if(plus_catalog && !cc_json_bool(g, "streamingSupported"))
			{
				const char *pid = cc_json_str(g, "productId");
				if(*pid)
				{
					struct json_object *gc = cc_json_clone(g);
					cc_json_set_bool(gc, "plusCatalog", true);
					json_object_object_add(supplement, pid, gc);
				}
				continue;
			}

			if(!is_cloud_streaming_game(g))
				continue;

			char key[96];
			edition_key(g, key, sizeof(key));
			const char *pid = cc_json_str(g, "productId");
			if(!*key || !*pid)
				continue;

			struct json_object *existing = objmap_get(games_by_edition, key);
			if(existing)
			{
				const char *canonical = cc_json_str(existing, "productId");
				if(*canonical && strcmp(pid, canonical) != 0 && !cc_json_has(aliases, pid))
					cc_json_set_str(aliases, pid, canonical);
				if(plus_catalog && !cc_json_bool(existing, "plusCatalog"))
					cc_json_set_bool(existing, "plusCatalog", true);
				continue;
			}

			struct json_object *gc = cc_json_clone(g);
			cc_json_set_bool(gc, "plusCatalog", plus_catalog);
			json_object_object_add(games_by_edition, key, gc);
		}
	}
}

// ---------------------------------------------------------------------------
// Cross-reference helpers (owned entitlement ranking / matching)
// ---------------------------------------------------------------------------

static bool is_full_game_entitlement(struct json_object *o)
{
	if(cc_json_int(o, "feature_type") == 3)
		return true;
	struct json_object *gm = cc_json_obj(o, "game_meta");
	return cc_ends_with(gm ? cc_json_str(gm, "package_type") : "", "GD");
}

static bool is_streaming_package(struct json_object *o)
{
	struct json_object *gm = cc_json_obj(o, "game_meta");
	return cc_ends_with(gm ? cc_json_str(gm, "package_type") : "", "GS");
}

static int owned_stream_rank(struct json_object *o)
{
	const char *id = cc_json_str(o, "id");
	const char *pid = cc_json_str(o, "product_id");
	int rank = 0;
	if(*pid && strcmp(pid, id) == 0)
		rank += 4;
	if(is_full_game_entitlement(o))
		rank += 2;
	if(*id)
		rank += 1;
	return rank;
}

static bool owned_better(struct json_object *cand, struct json_object *cur)
{
	int rc = owned_stream_rank(cand), ru = owned_stream_rank(cur);
	if(rc != ru)
		return rc > ru;
	bool gc = is_streaming_package(cand), gu = is_streaming_package(cur);
	if(gc != gu)
		return gc;
	int c = strcmp(cc_json_str(cand, "sku_id"), cc_json_str(cur, "sku_id"));
	if(c != 0)
		return c < 0;
	c = strcmp(cc_json_str(cand, "product_id"), cc_json_str(cur, "product_id"));
	if(c != 0)
		return c < 0;
	return strcmp(cc_json_str(cand, "id"), cc_json_str(cur, "id")) < 0;
}

static const char *owned_concept_id(struct json_object *o, char *out, size_t out_sz)
{
	concept_id_string(o, "conceptId", out, out_sz);
	if(!*out)
		concept_id_string(o, "concept_id", out, out_sz);
	if(!*out)
	{
		struct json_object *gm = cc_json_obj(o, "game_meta");
		if(gm)
		{
			concept_id_string(gm, "conceptId", out, out_sz);
			if(!*out)
				concept_id_string(gm, "concept_id", out, out_sz);
		}
	}
	return out;
}

static void build_stable_index(struct json_object *arr, struct json_object *map)
{
	if(!arr)
		return;
	size_t n = json_object_array_length(arr);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *g = json_object_array_get_idx(arr, i);
		char sk[128];
		cc_stable_key(game_product_id(g), sk, sizeof(sk));
		if(*sk)
			objmap_put_first(map, sk, g);
	}
}

static void build_concept_index(struct json_object *arr, struct json_object *map)
{
	if(!arr)
		return;
	size_t n = json_object_array_length(arr);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *g = json_object_array_get_idx(arr, i);
		char c[24];
		concept_id_string(g, "conceptId", c, sizeof(c));
		if(*c)
			objmap_put_first(map, c, g);
	}
}

void cc_sanitize_owned_service_type(struct json_object *ent)
{
	json_object_object_del(ent, "serviceType");
	struct json_object *attrs = cc_json_arr(ent, "entitlement_attributes");
	if(!attrs)
		return;
	size_t n = json_object_array_length(attrs);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *a = json_object_array_get_idx(attrs, i);
		if(!a || json_object_get_type(a) != json_type_object)
			continue;
		const char *pid = cc_json_str(a, "platform_id");
		if(cc_ieq(pid, "ps5")) { cc_json_set_str(ent, "serviceType", "pscloud"); return; }
		if(cc_ieq(pid, "ps4") || cc_ieq(pid, "ps3")) { cc_json_set_str(ent, "serviceType", "psnow"); return; }
	}
}

// emitOwned: enrich `ow` with `meta`, dedupe into owned_by_key (ranked).
static void emit_owned(struct json_object *ow, struct json_object *meta, bool from_supplement,
                       const char *product_id, const char *entitlement_id,
                       struct json_object *owned_by_key)
{
	struct json_object *entry = cc_json_clone(ow);

	const char *mname = cc_json_str(meta, "name");
	if(*mname)
		cc_json_set_str(entry, "name", mname);
	const char *mimg = cc_json_str(meta, "imageUrl");
	if(*mimg)
		cc_json_set_str(entry, "imageUrl", mimg);
	struct json_object *mcu = NULL;
	if(json_object_object_get_ex(meta, "conceptUrl", &mcu) && mcu)
		json_object_object_add(entry, "conceptUrl", cc_json_clone(mcu));
	struct json_object *mdev = cc_json_arr(meta, "device");
	if(mdev)
		json_object_object_add(entry, "device", cc_json_clone(mdev));
	const char *meta_pid = cc_json_str(meta, "productId");
	if(*meta_pid)
		cc_json_set_str(entry, "catalogProductId", meta_pid);
	cc_json_set_str(entry, "productId", product_id);
	cc_json_set_bool(entry, "streamingSupported", !from_supplement);

	char concept[24];
	concept_id_string(meta, "conceptId", concept, sizeof(concept));
	if(*concept)
		cc_json_set_str(entry, "conceptId", concept);

	const char *platform = platform_structured(entry);
	if(!*platform)
		platform = platform_token(product_id);

	char key[96];
	if(*concept)
		snprintf(key, sizeof(key), "c:%s:%s", concept, platform);
	else if(*product_id)
		snprintf(key, sizeof(key), "p:%s", product_id);
	else if(*entitlement_id)
		snprintf(key, sizeof(key), "e:%s", entitlement_id);
	else
		snprintf(key, sizeof(key), "u:%s:%s", product_id, entitlement_id);

	struct json_object *existing = objmap_get(owned_by_key, key);
	if(!existing || owned_better(entry, existing))
		objmap_put_last(owned_by_key, key, entry);
	json_object_put(entry);
}

// normalizeTitle: lowercase, strip TM/R/SM glyphs, collapse whitespace.
static void normalize_title(const char *raw, char *out, size_t out_sz)
{
	out[0] = 0;
	if(!raw)
		return;
	size_t o = 0;
	bool prev_space = true; // trims leading
	for(size_t i = 0; raw[i] && o < out_sz - 1;)
	{
		unsigned char ch = (unsigned char)raw[i];
		// strip UTF-8 ™ (E2 84 A2), ℠ (E2 84 A0), ® (C2 AE). Bounds-check each
		// continuation byte before reading so a truncated multibyte tail at EOS
		// (lone 0xE2/0xC2) never reads past the terminating NUL.
		if(ch == 0xE2 && (unsigned char)raw[i + 1] == 0x84
			&& ((unsigned char)raw[i + 2] == 0xA2 || (unsigned char)raw[i + 2] == 0xA0))
		{
			i += 3;
			continue;
		}
		if(ch == 0xC2 && raw[i + 1] && (unsigned char)raw[i + 1] == 0xAE)
		{
			i += 2;
			continue;
		}
		if(ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')
		{
			if(!prev_space)
			{
				out[o++] = ' ';
				prev_space = true;
			}
			i++;
			continue;
		}
		out[o++] = (char)tolower(ch);
		prev_space = false;
		i++;
	}
	while(o > 0 && out[o - 1] == ' ') // trim trailing
		o--;
	out[o] = 0;
}

static bool strlist_contains(char list[][128], int n, const char *s)
{
	for(int i = 0; i < n; i++)
		if(strcmp(list[i], s) == 0)
			return true;
	return false;
}

struct json_object *cc_build_owned_cross_ref(ChiakiLog *log,
	struct json_object *psnow_catalog, struct json_object *imagic_browse,
	struct json_object *imagic_supplement, struct json_object *product_id_aliases,
	struct json_object *owned_games, struct json_object *component_ids)
{
	struct json_object *cloud_map = json_object_new_object();
	struct json_object *supp_map = json_object_new_object();
	struct json_object *browse_stable = json_object_new_object();
	struct json_object *supp_stable = json_object_new_object();
	struct json_object *browse_concept = json_object_new_object();
	struct json_object *supp_concept = json_object_new_object();
	struct json_object *owned_by_key = json_object_new_object();

	// cloudCatalogMap: normalized psnow (first-wins by productId), then imagic (last-wins).
	if(psnow_catalog)
	{
		size_t n = json_object_array_length(psnow_catalog);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *norm = normalize_apollo_game(json_object_array_get_idx(psnow_catalog, i));
			if(!norm)
				continue;
			objmap_put_first(cloud_map, game_product_id(norm), norm);
			json_object_put(norm);
		}
	}
	if(imagic_browse)
	{
		size_t n = json_object_array_length(imagic_browse);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(imagic_browse, i);
			objmap_put_last(cloud_map, cc_json_str(g, "productId"), g);
		}
	}
	// aliases: alias -> canonical (only when canonical already mapped and alias not).
	if(product_id_aliases)
	{
		json_object_object_foreach(product_id_aliases, alias, canonical_v)
		{
			const char *canonical = json_object_get_string(canonical_v);
			if(objmap_has(cloud_map, alias))
				continue;
			struct json_object *c = objmap_get(cloud_map, canonical);
			if(c)
				objmap_put_last(cloud_map, alias, c);
		}
	}
	if(imagic_supplement)
	{
		size_t n = json_object_array_length(imagic_supplement);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(imagic_supplement, i);
			objmap_put_last(supp_map, cc_json_str(g, "productId"), g);
		}
	}

	// combinedBrowse = raw psnow + imagic browse (for stable/concept indexes).
	build_stable_index(psnow_catalog, browse_stable);
	build_stable_index(imagic_browse, browse_stable);
	build_concept_index(psnow_catalog, browse_concept);
	build_concept_index(imagic_browse, browse_concept);
	build_stable_index(imagic_supplement, supp_stable);
	build_concept_index(imagic_supplement, supp_concept);

	size_t owned_n = owned_games ? json_object_array_length(owned_games) : 0;
	for(size_t i = 0; i < owned_n; i++)
	{
		struct json_object *raw = json_object_array_get_idx(owned_games, i);
		if(!raw || json_object_get_type(raw) != json_type_object)
			continue;
		struct json_object *ow = cc_json_clone(raw);
		cc_sanitize_owned_service_type(ow);

		const char *product_id = cc_json_str(ow, "product_id");
		const char *entitlement_id = cc_json_str(ow, "id");
		struct json_object *gm = cc_json_obj(ow, "game_meta");
		const char *ent_name = gm ? cc_json_str(gm, "name") : "";
		char ent_name_lc[256];
		normalize_title(ent_name, ent_name_lc, sizeof(ent_name_lc));
		bool skip_demo = cc_contains(ent_name_lc, "demo");

		char stable_k[128], ent_stable_k[128], owned_concept[24];
		cc_stable_key(product_id, stable_k, sizeof(stable_k));
		cc_stable_key(entitlement_id, ent_stable_k, sizeof(ent_stable_k));
		owned_concept_id(ow, owned_concept, sizeof(owned_concept));

		struct json_object *meta = NULL;
		bool from_supp = false;

		if(*product_id && (meta = objmap_get(cloud_map, product_id))) { }
		else if(*entitlement_id && (meta = objmap_get(cloud_map, entitlement_id))) { }
		else if(*owned_concept && (meta = objmap_get(browse_concept, owned_concept))) { }
		else if(*owned_concept && (meta = objmap_get(supp_concept, owned_concept))) { from_supp = true; }
		else if(*product_id && *entitlement_id && strcmp(entitlement_id, product_id) == 0
			&& (meta = objmap_get(supp_map, product_id))) { from_supp = true; }
		else if(*stable_k && !skip_demo && (meta = objmap_get(browse_stable, stable_k))) { }
		else if(*stable_k && !skip_demo && (meta = objmap_get(supp_stable, stable_k))) { from_supp = true; }
		else if(*ent_stable_k && !skip_demo && (meta = objmap_get(browse_stable, ent_stable_k))) { }
		else if(*ent_stable_k && !skip_demo && (meta = objmap_get(supp_stable, ent_stable_k))) { from_supp = true; }

		if(meta)
		{
			emit_owned(ow, meta, from_supp, product_id, entitlement_id, owned_by_key);
			json_object_put(ow);
			continue;
		}

		// Bundle-sibling expansion.
		struct json_object *siblings = component_ids ? cc_json_arr(component_ids, product_id) : NULL;
		if(siblings)
		{
			char seen[64][128];
			int nseen = 0;
			size_t ns = json_object_array_length(siblings);
			for(size_t s = 0; s < ns; s++)
			{
				const char *sibling_id = json_object_get_string(json_object_array_get_idx(siblings, s));
				if(!sibling_id)
					continue;
				struct json_object *sibling_meta = NULL;
				bool sibling_supp = false;
				if((sibling_meta = objmap_get(cloud_map, sibling_id))) { }
				else if((sibling_meta = objmap_get(supp_map, sibling_id))) { sibling_supp = true; }
				else
				{
					char sk[128];
					cc_stable_key(sibling_id, sk, sizeof(sk));
					if(*sk && !skip_demo)
					{
						if((sibling_meta = objmap_get(browse_stable, sk))) { }
						else if((sibling_meta = objmap_get(supp_stable, sk))) { sibling_supp = true; }
					}
				}
				if(!sibling_meta)
					continue;
				const char *sibling_pid = cc_json_str(sibling_meta, "productId");
				if(!*sibling_pid || strlist_contains(seen, nseen, sibling_pid))
					continue;
				if(nseen < 64)
					snprintf(seen[nseen++], 128, "%s", sibling_pid);
				emit_owned(ow, sibling_meta, sibling_supp, product_id, entitlement_id, owned_by_key);
			}
		}
		json_object_put(ow);
	}

	// Disc-upgrade rescue (feature_type 5).
	json_object_object_foreach(owned_by_key, dkey, entry)
	{
		(void)dkey;
		if(cc_json_int(entry, "feature_type") != 5)
			continue;
		const char *disc_pid = cc_json_str(entry, "product_id");
		const char *disc_platform = platform_token(disc_pid);
		struct json_object *egm = cc_json_obj(entry, "game_meta");
		char disc_name[256];
		normalize_title(egm ? cc_json_str(egm, "name") : "", disc_name, sizeof(disc_name));
		if(!*disc_name)
			continue;
		char canonical[32][128];
		char other[32][128];
		int nc = 0, no = 0;
		size_t cn = owned_games ? json_object_array_length(owned_games) : 0;
		for(size_t c = 0; c < cn; c++)
		{
			struct json_object *cand = json_object_array_get_idx(owned_games, c);
			if(!cand || cc_json_int(cand, "feature_type") != 3)
				continue;
			struct json_object *cgm = cc_json_obj(cand, "game_meta");
			char cand_name[256];
			normalize_title(cgm ? cc_json_str(cgm, "name") : "", cand_name, sizeof(cand_name));
			if(strcmp(cand_name, disc_name) != 0)
				continue;
			const char *cand_pid = cc_json_str(cand, "product_id");
			if(!*cand_pid || strcmp(cand_pid, disc_pid) == 0)
				continue;
			if(strcmp(platform_token(cand_pid), disc_platform) != 0)
				continue;
			const char *cand_id = cc_json_str(cand, "id");
			if(strcmp(cand_pid, cand_id) == 0)
			{
				if(!strlist_contains(canonical, nc, cand_pid) && nc < 32)
					snprintf(canonical[nc++], 128, "%s", cand_pid);
			}
			else
			{
				if(!strlist_contains(other, no, cand_pid) && no < 32)
					snprintf(other[no++], 128, "%s", cand_pid);
			}
		}
		const char *replacement = NULL;
		if(nc == 1)
			replacement = canonical[0];
		else if(nc == 0 && no == 1)
			replacement = other[0];
		if(!replacement)
			continue;
		cc_json_set_str(entry, "product_id", replacement);
		cc_json_set_str(entry, "productId", replacement);
		cc_json_set_str(entry, "catalogProductId", replacement);
		CHIAKI_LOGI(log, "[CROSS-REF] disc-upgrade rescue: %s -> %s", disc_name, replacement);
	}

	// Emit filteredGames (clones; order re-sorted in assemble).
	struct json_object *out = json_object_new_array();
	json_object_object_foreach(owned_by_key, k2, v2)
	{
		(void)k2;
		json_object_array_add(out, cc_json_clone(v2));
	}

	json_object_put(cloud_map);
	json_object_put(supp_map);
	json_object_put(browse_stable);
	json_object_put(supp_stable);
	json_object_put(browse_concept);
	json_object_put(supp_concept);
	json_object_put(owned_by_key);
	return out;
}

// ---------------------------------------------------------------------------
// assembleUnifiedCatalog -> contract envelope
// ---------------------------------------------------------------------------

struct json_object *cc_assemble_unified_catalog(ChiakiLog *log, const CCAssembleInput *in)
{
	// 1. Normalize apollo rows + collect their productIds.
	struct json_object *apollo_norm = json_object_new_array();
	struct json_object *apollo_pids = json_object_new_object();
	if(in->apollo_games)
	{
		size_t n = json_object_array_length(in->apollo_games);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = normalize_apollo_game(json_object_array_get_idx(in->apollo_games, i));
			if(!g)
				continue;
			json_object_array_add(apollo_norm, g);
			set_add(apollo_pids, game_product_id(g));
		}
	}

	// 2. PS5 browse rows: device-based filter, skip apollo dups, stamp pscloud.
	struct json_object *ps5_browse = json_object_new_array();
	if(in->imagic_browse)
	{
		size_t n = json_object_array_length(in->imagic_browse);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *v = json_object_array_get_idx(in->imagic_browse, i);
			if(!v || !is_ps5_platform(v))
				continue;
			if(set_has(apollo_pids, game_product_id(v)))
				continue;
			struct json_object *g = cc_json_clone(v);
			const char *existing = cc_json_str(g, "serviceType");
			if(!cc_ieq(existing, "psnow") && !cc_ieq(existing, "pscloud"))
				cc_json_set_str(g, "serviceType", "pscloud");
			json_object_array_add(ps5_browse, g);
		}
	}

	// 3. universe = apollo + ps5Browse
	struct json_object *universe = json_object_new_array();
	{
		size_t n = json_object_array_length(apollo_norm);
		for(size_t i = 0; i < n; i++)
			json_object_array_add(universe, cc_json_clone(json_object_array_get_idx(apollo_norm, i)));
		n = json_object_array_length(ps5_browse);
		for(size_t i = 0; i < n; i++)
			json_object_array_add(universe, cc_json_clone(json_object_array_get_idx(ps5_browse, i)));
	}

	// 4. merge owned
	struct json_object *games = merge_owned_into_browse(universe, in->owned_cross_ref, true);

	// 5. streamability gate (native mode only)
	if(in->native_mode)
	{
		struct json_object *concept_rows = json_object_new_array();
		if(in->imagic_browse)
		{
			size_t n = json_object_array_length(in->imagic_browse);
			for(size_t i = 0; i < n; i++)
				json_object_array_add(concept_rows, json_object_get(json_object_array_get_idx(in->imagic_browse, i)));
		}
		if(in->imagic_supplement)
		{
			size_t n = json_object_array_length(in->imagic_supplement);
			for(size_t i = 0; i < n; i++)
				json_object_array_add(concept_rows, json_object_get(json_object_array_get_idx(in->imagic_supplement, i)));
		}
		StreamabilityIndex ix = streamability_build(apollo_norm, in->imagic_browse, concept_rows);

		struct json_object *kept = json_object_new_array();
		size_t n = json_object_array_length(games);
		int dropped = 0;
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(games, i);
			if(!cc_json_bool(g, "isOwned") || streamability_is_streamable(&ix, g))
				json_object_array_add(kept, json_object_get(g));
			else
				dropped++;
		}
		if(dropped > 0)
			CHIAKI_LOGI(log, "[UNIFIED] streamability gate dropped %d owned non-streamable", dropped);
		json_object_put(games);
		games = kept;
		streamability_fini(&ix);
		json_object_put(concept_rows);
	}

	// 6. tag every game with the full contract.
	size_t n = json_object_array_length(games);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *g = json_object_array_get_idx(games, i);
		const char *svc = stream_service_type(g);
		cc_json_set_str(g, "category", category_for(g));
		cc_json_set_str(g, "streamServiceType", svc);
		cc_json_set_str(g, "platform", platform_badge(g));
		cc_json_set_str(g, "streamIdentifier", stream_identifier(g, svc));
		// Always-present contract booleans/strings (clients never branch on absence).
		cc_json_set_bool(g, "isOwned", cc_json_bool(g, "isOwned"));
		cc_json_set_bool(g, "plusCatalog", cc_json_bool(g, "plusCatalog"));
		// conceptId may arrive as a JSON number (imagic browse) or string (owned
		// cross-ref). Normalize to a decimal string so it is always present and the
		// integer form is never dropped (reading it as a string blanks ints).
		char concept_norm[24];
		concept_id_string(g, "conceptId", concept_norm, sizeof(concept_norm));
		cc_json_set_str(g, "conceptId", concept_norm);
		// normalize identity fields the clients read
		if(!cc_json_has(g, "productId") && cc_json_has(g, "product_id"))
			cc_json_set_str(g, "productId", cc_json_str(g, "product_id"));
		const char *ent = game_entitlement_id(g);
		if(*ent)
			cc_json_set_str(g, "entitlementId", ent);
		const char *store = cc_json_str(g, "catalogProductId");
		if(!*store)
			store = cc_json_str(g, "storeProductId");
		if(*store)
			cc_json_set_str(g, "storeProductId", store);
	}

	// Ownership stamping can converge formerly distinct source ids onto one canonical
	// productId. Enforce the public contract's uniqueness invariant after every routing
	// and category field has been computed, then invalidate pre-v4 caches via the schema.
	struct json_object *deduped = dedupe_contract_product_ids(games);
	json_object_put(games);
	games = deduped;
	n = json_object_array_length(games);

	// 7. envelope
	struct json_object *out = json_object_new_object();
	json_object_object_add(out, "schemaVersion", json_object_new_int(CHIAKI_CLOUDCATALOG_SCHEMA_VERSION));
	json_object_object_add(out, "total", json_object_new_int((int)n));
	json_object_object_add(out, "nativeMode", json_object_new_boolean(in->native_mode));
	cc_json_set_str(out, "fallbackRegion", in->fallback_region ? in->fallback_region : "");
	cc_json_set_str(out, "resolvedStoreLang", in->resolved_store_lang ? in->resolved_store_lang : "");
	if(in->settled_locale && *in->settled_locale)
		cc_json_set_str(out, "settledLocale", in->settled_locale);
	cc_json_set_str(out, "warning", in->warning ? in->warning : "");
	json_object_object_add(out, "games", games); // transfers ownership

	json_object_put(apollo_norm);
	json_object_put(apollo_pids);
	json_object_put(ps5_browse);
	json_object_put(universe);
	return out;
}
