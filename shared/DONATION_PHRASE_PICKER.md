# Donation paywall & phrase picker (cross-platform spec)

This document describes the **shared JSON**, the **phrase-rotation algorithm**, and the **Android support paywall UX** (animations, orientation, focus) so another client (e.g. iOS) can reimplement the same behavior.

**Canonical data file:** `shared/donation_prompt_phrases.json`  
- **Android:** Gradle task `syncDonationPhrases` copies this file into `app/build/generated/donation-phrases-res/raw/` before resources merge; `R.raw.donation_prompt_phrases` is generated from that copy. Do not commit a duplicate under `android/app/src/main/res/raw/`.  
- **iOS:** Add the same JSON to the app bundle (e.g. copy build phase) and load by filename `donation_prompt_phrases.json`.

---

## 1. JSON schema (phrases)

Top-level object:

| Field | Required | Meaning |
|--------|----------|---------|
| `schema_version` | No | Integer for your own migrations. |
| `product_name` | No | Display / tooling only. |
| `description` | No | Authoring notes. |
| `category_order` | No | String array of category keys. If missing, default `["mild", "playful", "mean"]`. |
| `categories` | Yes | Object map: key → `{ "label", "tone", "phrases": [ strings ] }`. |

**Flattening to a single list `flat`:**

1. Read `category_order` (or default above).
2. For each category id in order, read `categories[id].phrases` (array of strings) and append each string to `flat` in order.
3. Skip unknown category ids. Empty or missing arrays add nothing.

---

## 2. Phrase selection (rotation)

**Constant:** `PAYWALL_BULLET_SHOWS_BEFORE_PHRASES = 3` (first **3** paywall opens use static bullet copy, not rotating phrases).

**Inputs:**

- `show_count` — 1-based total number of times the donation paywall was **shown** (increment once per presentation).
- `flat` — flattened phrase list from §1 (may be empty).

**Rules:**

1. If `show_count <= 3`: show **default trust bullets** (static strings in UI resources). Do **not** show a rotating phrase.
2. If `show_count > 3`: hide the default bullet block and show **one** rotating phrase.
   - Define `phrase_call_id = show_count - 3` (so the 4th open uses `phrase_call_id == 1`).
   - 0-based index: `i = floor_mod(phrase_call_id - 1, flat.length)` where `floor_mod` is mathematical modulo (non-negative).
   - Phrase: `flat[i]`.
3. If `flat` is empty when you need a phrase: fall back to default bullets or a single static line.

**General “call id” API (1-based):**  
For any monotonic `call_id >= 1`, index `(call_id - 1) mod flat.length` (with floor-mod) selects a phrase. The paywall maps `show_count` to `phrase_call_id` as above.

**Android reference:** `DonationPhrasePicker.kt` — `phraseForPaywallShowCount`, `phraseForCallId`, `PAYWALL_BULLET_SHOWS_BEFORE_PHRASES`.

---

## 3. Paywall UI modes (Android → iOS parity)

Two offer modes:

| Mode | When | Main content |
|------|------|----------------|
| **Play Store tiers** | Billing loads INAPP product details | Vertical list of tier rows (product order = app config order, e.g. bronze → …). Restore purchases + “Maybe later”. |
| **External PayPal** | Billing unavailable / no SKUs | QR code + “Open PayPal link” text action; no tier list; no restore. Trust line string differs. |

**Product order (Android):** `res/values/donation_iap_ids.xml` → `donation_iap_product_ids` string-array. First id = first tier row (bronze).

---

## 4. Layout: portrait vs landscape

**Two layout resources** (same view IDs):

- **Portrait:** `layout/dialog_support_paywall.xml` — centered header (larger logo), story + tiers in a vertical `NestedScrollView`, weighted spacers to vertically center short content (`fillViewport` + `layout_weight` spacers).
- **Landscape:** `layout-land/dialog_support_paywall.xml` — horizontal split: story block left (`NestedScrollView` weight 1), tier column right (tiers in a scroll region). Header is a horizontal strip (smaller logo).

**Runtime visibility (Play tiers, portrait only):**  
`supportPaywallPickTitle` and `supportPaywallPickHint` are **visible** in portrait; in landscape they stay **gone** (hint text is in `values-land/strings.xml` for the story area instead).

**Landscape footer (Play tiers only):**  
`configureSupportPaywallFooterForOrientation`: footer becomes **horizontal** — trust line on the left (`weight = 1`, smaller text), “Restore purchases” and “Maybe later” on the right (compact text sizes and min heights). Portrait keeps stacked footer.

---

## 5. Rotating phrase vs bullets (story block)

- Views: `supportPaywallStoryBullets` (bullet list), `supportPaywallStoryPhrase` (single rotating line).
- If `phraseForPaywallShowCount(...) == null`: show bullets, hide phrase view.
- Else: hide bullets, show phrase view; run a **typewriter-style reveal** (see §6).
- **Landscape strings:** `values-land/strings.xml` can shorten story lead / bullets; logic is the same.

---

## 6. Phrase “typed” reveal animation

When showing a rotating phrase:

- Start with empty text and low alpha (~0.2).
- Animate character count from `0` to `fullText.length` over a duration:
  - `durationMs = clamp(320 + len * 16, 320, 720)` milliseconds (min / per-char / max).
- Each frame: set text to `fullText.take(n)` and alpha `0.2 + 0.8 * (n / len)`.
- On end/cancel: full text, alpha `1f`.

**Android:** `startPaywallPhraseReveal` in `DonationPromptCoordinator.kt`.

---

## 7. Sheet-level “blue frame” pulse (opening highlight)

On the bottom sheet’s root `FrameLayout` (`design_bottom_sheet`):

- Add a **full-bleed overlay** `View` with `background` = `ClipDrawable` wrapping a **transparent `GradientDrawable` with colored stroke** (horizontal clip, level 0 → 10000).
- Animate clip level 0 → max over ~720 ms (horizontal sweep).
- On completion: fade overlay alpha to 0 over ~480 ms, then **remove** the overlay.

This is purely decorative; it does not carry focus.

---

## 8. Tier row reveal (staggered entrance)

Each tier is a `MaterialCardView` (clickable row: name, blurb, price, chevron).

**Per card, on add:**

- Initial: `alpha = 0`, slight `translationY` (e.g. 8dp up), stroke wide + blue, then animate to default thin neutral stroke.
- **Stagger:** `delay = index * 90 ms`.
- **Duration:** `420 ms` for alpha, translation, and stroke animations (same easing, e.g. fast-out slow-in).

**Constants (Android):** `TIER_REVEAL_STAGGER_MS = 90`, `TIER_REVEAL_DURATION_MS = 420`.

---

## 9. Per-tier border sweep (after all reveals)

After **all** tier fade-ins finish:

- `all_fades_done_ms = (n - 1) * 90 + 420` (for `n` tiers).
- Then run a **sequential** sweep on each card: card 0, then after a gap card 1, … (Android cycles index with modulo for repeating pattern — see coordinator).

**Per card sweep:**

- Save `previousForeground` on the card.
- Set `foreground` to a `ClipDrawable` (horizontal) over a stroked rounded rect (blue stroke, transparent fill), corner radius matching the card.
- Animate clip level ~`1000 ms`.
- Then fade clip alpha to 0 over ~`400 ms`.
- Restore `foreground = previousForeground` and invalidate.

**Constants:** `TIER_CARD_SWEEP_MS = 1000`, `TIER_CARD_SWEEP_FADE_MS = 400`, `TIER_CARD_SWEEP_GAP_MS = 1000`.

**Important:** Sweep **replaces `foreground`**. If the card uses `foreground` for focus highlight, re-apply focus styling after restore (see §10).

---

## 10. Focus & keyboard / TV (Play tiers)

**Goals:**

- Initial focus on the **first tier** (bronze) for D-pad / keyboard.
- Reveal **stroke animators** must not overwrite focused stroke (they animate to neutral stroke).
- **Border sweep** must not permanently clear focus styling.

**Android behavior:**

- **`applySupportTierCardFocusVisual(card, focused)`**  
  - Unfocused: default 1dp stroke, neutral color, `foreground = null`.  
  - Focused: thicker gold stroke, semi-transparent gold `foreground` rounded rect (match card corner radius).
- **`OnFocusChangeListener`** on each tier card calls the above.
- **Reveal stroke `ValueAnimator`s:** if `card.isFocused`, skip neutral stroke updates and re-apply focus visual instead.
- **Initial focus:** `postDelayed(requestFocus, TIER_REVEAL_DURATION_MS)` on first card so reveal finishes first; skip if user already focused another tier.
- **After sweep `emitFinished`:** if `card.isFocused`, call `applySupportTierCardFocusVisual(card, true)` again after restoring `previousForeground`.

**PayPal mode:** Focus primary action (`Open PayPal link`); TV may `requestFocus` on that view after bind.

---

## 11. PayPal fallback (external mode)

- URL from string resource `donation_paypal_fallback_url`.
- QR: encode URL (e.g. ZXing), display in `ImageView`; tap opens URL.
- “Open PayPal link” opens `ACTION_VIEW`; catch no browser and toast `donation_paywall_external_no_browser`.

---

## 12. Billing (Android reference only)

- Play Billing 8: `queryProductDetailsAsync` for INAPP ids in order; filter to products with a one-time offer; build UI rows from that order.
- Purchase: `launchBillingFlow` with offer token; acknowledge one-time purchases as required.
- Restore: `queryPurchasesAsync` INAPP, filter donation SKUs, acknowledge if needed, toast outcomes.

---

## 13. iOS checklist (minimal)

1. Bundle `shared/donation_prompt_phrases.json`; implement §1–§2 exactly (including `show_count` persistence).
2. Implement two offer modes (StoreKit tiers vs Safari/PayPal fallback).
3. Match portrait/landscape structure and footer behavior (§4).
4. Optional but recommended: sheet pulse (§7), tier stagger (§8), tier sweep (§9), phrase typewriter (§6).
5. Match focus rules for first tier and post-sweep re-highlight (§10).
6. Keep **one** JSON file in repo; iOS copy phase from `shared/` like Android Gradle sync.
