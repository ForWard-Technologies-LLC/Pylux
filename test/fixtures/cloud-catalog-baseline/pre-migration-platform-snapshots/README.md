# Pre-migration cloud catalog snapshots (frozen reference)

These are **exact, immutable copies** of the cloud catalog cache files produced by the
current per-platform implementations, captured **before** the libchiaki consolidation
(plan: `.cursor/plans/libchiaki_cloud_catalog_95ab8494.plan.md`).

They define **exactly what the new lib output must reproduce**. Do not edit. Verify with
`shasum -a 256 -c SHA256SUMS.txt` (paths relative to the baseline dir).

Captured: 2026-06-25 (HEAD at commit `0063eec2` — includes the dedup + device-based
parity fixes). All three platforms are confirmed **functionally identical**: **4930 games
— 97 owned / 780 streamable / 4053 purchaseable**, `nativeMode=true`, `fallbackRegion=""`.

## Canonical golden file (Qt)

Lives in the sibling `qt-current/` baseline (symlink → `qt-20260625T005114Z`). This is the
authoritative target for the lib port and `compare-cloud-catalog-baseline.py`.

| File | Role |
|------|------|
| `qt-current/cache/unified_catalog_v2.json` | **Primary golden output** (object envelope: `{games,total,nativeMode,...}`) |
| `qt-current/cache/ps5_cloud_catalog_v6.json` | imagic intermediate |
| `qt-current/cache/ps5_cloud_library.json` | owned entitlements |

## Platform cross-checks (this dir)

Snapshots of the live iOS simulator and Android device caches, proving cross-platform
parity. Note the per-platform structural quirks the lib will normalize away:

- **iOS** caches the games **array directly** (no envelope); current key `unified_catalog_v5.json`.
  Older `v3`/`v4` and the legacy `psnow_catalog`/`pscloud_*` files are stale leftovers from
  prior builds — ignore; only `unified_catalog_v5.json` is current.
- **Android** also caches a games array; current key `unified_catalog_v5.json`,
  imagic intermediate `ps5_cloud_catalog_v3.json` (Android's own key name).

## Important

- Exact byte/SHA equality across platforms is **not** expected (different file structure,
  field ordering, and iOS/Android array-vs-envelope). The invariant is **functional**: same
  productId set, same per-game `category`/`serviceType`/`isOwned`/platform, same totals.
- Live catalog drifts as Sony adds/removes titles, so byte-exact `unified_catalog` compares
  only hold for a same-day re-fetch. Durable invariants live in the merge munit fixtures.
