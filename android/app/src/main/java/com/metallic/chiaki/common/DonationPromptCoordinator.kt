// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ArgbEvaluator
import android.animation.ValueAnimator
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.res.ColorStateList
import android.app.Dialog
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.graphics.drawable.ClipDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.util.Log
import android.util.TypedValue
import android.widget.Toast
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.widget.TextView
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.coordinatorlayout.widget.CoordinatorLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.interpolator.view.animation.FastOutSlowInInterpolator
import com.android.billingclient.api.*
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import com.google.android.material.bottomsheet.BottomSheetBehavior
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.card.MaterialCardView
import com.metallic.chiaki.stream.StreamViewModel
import com.pylux.stream.R
import com.pylux.stream.databinding.DialogSupportPaywallBinding
import com.pylux.stream.databinding.ItemSupportTierBinding

/**
 * Optional donation UI (stream auto-prompt or Settings). Multiple INAPP tiers;
 * order follows [R.array.donation_iap_product_ids].
 *
 * Stream auto-prompt after connect when:
 * - cumulative play time ≥ [MIN_STREAM_MS], and
 * - at least [STREAM_AUTO_PROMPT_MIN_INTERVAL_MS] wall time has passed since [Preferences.lastDonationPromptWallClockMs]
 *   (no prompt in the current hour since the last check / show).
 * Settings uses [openSupportFromSettings] with no playtime gate.
 *
 * Uses Play Billing Library 8 callback APIs ([queryPurchasesAsync], [queryProductDetailsAsync]).
 */
class DonationPromptCoordinator private constructor(
	private val activity: AppCompatActivity,
	private val preferences: Preferences,
	/** In-stream auto offer path (vs Settings). */
	private val streamAutoOffer: Boolean,
	private val onBillingDisconnected: (() -> Unit)?,
	/** Settings: skip Play ownership query, open product dialog directly. */
	private val settingsAlwaysOpen: Boolean,
)
{
	private val handler = android.os.Handler(android.os.Looper.getMainLooper())
	private var pendingOfferRunnable: Runnable? = null
	/** Bumped on paywall dismiss so in-flight tier animations and delayed runnables no-op. */
	private var supportPaywallUiSession = 0
	private var activeTierSweepAnimator: ValueAnimator? = null
	private var paywallPhraseRevealAnimator: ValueAnimator? = null
	private val tierSweepScheduledRunnables = mutableListOf<Runnable>()
	private var billingClient: BillingClient? = null
	private var activeDialog: Dialog? = null
	private var productIdsForAck: Set<String> = emptySet()
	private var retainBillingForPurchaseFlow: Boolean = false
	private var suppressDisconnectCallback: Boolean = false

	private sealed interface PaywallOffer
	{
		data class PlayStoreTiers(val details: List<ProductDetails>) : PaywallOffer
		data object ExternalPayPal : PaywallOffer
	}

	private val purchasesUpdatedListener = PurchasesUpdatedListener { billingResult, purchases ->
		when (billingResult.responseCode)
		{
			BillingClient.BillingResponseCode.OK ->
			{
				val list = purchases.orEmpty()
				val donation = list.firstOrNull { purchase ->
					purchase.purchaseState == Purchase.PurchaseState.PURCHASED &&
						purchase.products.any { it in productIdsForAck }
				}
				if (donation != null)
					handlePurchase(donation)
				else
					finishPurchaseFlowCleanup()
			}
			BillingClient.BillingResponseCode.USER_CANCELED -> finishPurchaseFlowCleanup()
			else ->
			{
				Log.w(TAG, "Purchase update: ${billingResult.responseCode} ${billingResult.debugMessage}")
				finishPurchaseFlowCleanup()
			}
		}
	}

	companion object
	{
		private const val TAG = "DonationPrompt"
		private const val SHOW_DELAY_MS = 1_500L
		/** Cumulative remote play time before the stream connect auto-prompt may run. */
		const val MIN_STREAM_MS = 3_600_000L
		/** Min wall-clock spacing between stream auto-prompts (dialog or ownership toast). */
		private const val STREAM_AUTO_PROMPT_MIN_INTERVAL_MS = 3_600_000L

		private const val TIER_REVEAL_STAGGER_MS = 90L
		private const val TIER_REVEAL_DURATION_MS = 420L
		/** Per-card border sweep after all tier rows have faded in. */
		private const val TIER_CARD_SWEEP_MS = 1_000L
		private const val TIER_CARD_SWEEP_GAP_MS = 1_000L
		private const val TIER_CARD_SWEEP_FADE_MS = 400L

		private const val PHRASE_REVEAL_MS_MIN = 320L
		private const val PHRASE_REVEAL_MS_PER_CHAR = 16L
		private const val PHRASE_REVEAL_MS_MAX = 720L

		fun forStream(activity: AppCompatActivity, viewModel: StreamViewModel) = DonationPromptCoordinator(
			activity,
			viewModel.preferences,
			streamAutoOffer = true,
			onBillingDisconnected = null,
			settingsAlwaysOpen = false,
		)

		/** [onBillingDisconnected] runs after each [endBilling] (flow finished or error); use to clear UI holder refs. */
		fun forSettings(activity: AppCompatActivity, preferences: Preferences, onBillingDisconnected: () -> Unit) =
			DonationPromptCoordinator(
				activity,
				preferences,
				streamAutoOffer = false,
				onBillingDisconnected = onBillingDisconnected,
				settingsAlwaysOpen = true,
			)

		fun donationProductIds(activity: AppCompatActivity): List<String> =
			activity.resources.getStringArray(R.array.donation_iap_product_ids)
				.map { it.trim() }
				.filter { it.isNotEmpty() }
	}

	private fun statusBarHeightFallbackPx(): Int
	{
		val resId = activity.resources.getIdentifier("status_bar_height", "dimen", "android")
		return if (resId > 0) activity.resources.getDimensionPixelSize(resId) else 0
	}

	/** Status / cutout top; BottomSheetBehavior ignores [CoordinatorLayout.LayoutParams.topMargin] when expanded. */
	private fun paywallTopInsetPx(insets: WindowInsetsCompat): Int
	{
		val sys = insets.getInsets(WindowInsetsCompat.Type.systemBars())
		val status = insets.getInsets(WindowInsetsCompat.Type.statusBars())
		val cut = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
		val top = maxOf(sys.top, status.top, cut.top)
		return if (top > 0) top else statusBarHeightFallbackPx()
	}

	/** One-shot blue frame: sweeps start→end, then fades out (no permanent border). */
	private fun startSupportPaywallBorderPulse(sheet: FrameLayout)
	{
		val strokePx = activity.resources.getDimensionPixelSize(R.dimen.support_paywall_frame_stroke)
		val blue = ContextCompat.getColor(activity, R.color.pylux_blue)
		val border = GradientDrawable().apply {
			shape = GradientDrawable.RECTANGLE
			setColor(0)
			setStroke(strokePx, blue)
		}
		val clip = ClipDrawable(border, Gravity.START, ClipDrawable.HORIZONTAL).apply { level = 0 }
		val overlay = View(activity).apply {
			layoutParams = FrameLayout.LayoutParams(
				ViewGroup.LayoutParams.MATCH_PARENT,
				ViewGroup.LayoutParams.MATCH_PARENT,
			)
			background = clip
			isClickable = false
			importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
		}
		sheet.addView(overlay, 0)

		ValueAnimator.ofInt(0, 10_000).apply {
			duration = 720L
			addUpdateListener { clip.level = it.animatedValue as Int }
			addListener(object : AnimatorListenerAdapter() {
				override fun onAnimationEnd(animation: Animator)
				{
					overlay.animate()
						.alpha(0f)
						.setDuration(480L)
						.withEndAction {
							sheet.removeView(overlay)
						}
						.start()
				}
			})
			start()
		}
	}

	private fun clearTierBorderSweepScheduling()
	{
		tierSweepScheduledRunnables.forEach { handler.removeCallbacks(it) }
		tierSweepScheduledRunnables.clear()
		activeTierSweepAnimator?.cancel()
		activeTierSweepAnimator = null
	}

	private fun cancelPaywallPhraseReveal()
	{
		paywallPhraseRevealAnimator?.cancel()
		paywallPhraseRevealAnimator = null
	}

	/** Left-to-right “typed” reveal + alpha ramp so rotating copy reads clearly. */
	private fun startPaywallPhraseReveal(textView: TextView, fullText: String)
	{
		cancelPaywallPhraseReveal()
		if (fullText.isEmpty())
		{
			textView.text = ""
			textView.alpha = 1f
			return
		}
		textView.text = ""
		textView.alpha = 0.2f
		val len = fullText.length
		val durationMs = (PHRASE_REVEAL_MS_MIN + len * PHRASE_REVEAL_MS_PER_CHAR)
			.coerceIn(PHRASE_REVEAL_MS_MIN, PHRASE_REVEAL_MS_MAX)
		val anim = ValueAnimator.ofInt(0, len).apply {
			duration = durationMs
			interpolator = LinearInterpolator()
			addUpdateListener { a ->
				val n = a.animatedValue as Int
				textView.text = fullText.take(n)
				val frac = if (len <= 0) 1f else n.toFloat() / len
				textView.alpha = 0.2f + 0.8f * frac
			}
			addListener(object : AnimatorListenerAdapter() {
				override fun onAnimationEnd(animation: Animator)
				{
					textView.text = fullText
					textView.alpha = 1f
					paywallPhraseRevealAnimator = null
				}

				override fun onAnimationCancel(animation: Animator)
				{
					textView.text = fullText
					textView.alpha = 1f
					paywallPhraseRevealAnimator = null
				}
			})
		}
		paywallPhraseRevealAnimator = anim
		anim.start()
	}

	/** Gold stroke + tint overlay so focus survives tier reveal/sweep animations that touch stroke/foreground. */
	private fun applySupportTierCardFocusVisual(card: MaterialCardView, focused: Boolean)
	{
		val dm = activity.resources.displayMetrics
		val defaultStrokePx = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 1f, dm).toInt()
		val defaultColor = ContextCompat.getColor(activity, R.color.support_tier_card_stroke)
		if (!focused)
		{
			card.strokeWidth = defaultStrokePx
			card.setStrokeColor(ColorStateList.valueOf(defaultColor))
			card.foreground = null
			return
		}
		val focusStrokePx = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 3f, dm).toInt()
		card.strokeWidth = focusStrokePx
		card.setStrokeColor(ColorStateList.valueOf(Color.parseColor("#FFFFD700")))
		val cornerPx = if (card.radius > 0f) card.radius else activity.resources.getDimension(R.dimen.support_tier_card_corner_radius)
		card.foreground = GradientDrawable().apply {
			shape = GradientDrawable.RECTANGLE
			cornerRadius = cornerPx
			setColor(0x22FFD700.toInt())
		}
	}

	/**
	 * Horizontal sweep highlight on one tier card (same ClipDrawable idea as [startSupportPaywallBorderPulse]),
	 * then brief fade-out. Uses [MaterialCardView.foreground] instead of a MATCH_PARENT child so portrait
	 * paywall layout (NestedScrollView + fillViewport + weighted spacers) does not measure the card at ~full height.
	 */
	private fun startSupportTierCardBorderSweep(card: MaterialCardView, uiSession: Int, onFinished: () -> Unit)
	{
		if (uiSession != supportPaywallUiSession || !card.isAttachedToWindow)
		{
			onFinished()
			return
		}

		val res = activity.resources
		val strokePx = res.getDimensionPixelSize(R.dimen.support_tier_sweep_stroke)
		val blue = ContextCompat.getColor(activity, R.color.pylux_blue)
		val cornerPx = when {
			card.radius > 0f -> card.radius
			else -> res.getDimension(R.dimen.support_tier_card_corner_radius)
		}
		val border = GradientDrawable().apply {
			shape = GradientDrawable.RECTANGLE
			setColor(0)
			cornerRadius = cornerPx
			setStroke(strokePx, blue)
		}
		val clip = ClipDrawable(border, Gravity.START, ClipDrawable.HORIZONTAL).apply {
			level = 0
			alpha = 255
		}

		val previousForeground = card.foreground
		card.foreground = clip

		var ended = false
		fun emitFinished()
		{
			if (ended) return
			ended = true
			activeTierSweepAnimator = null
			clip.alpha = 255
			card.foreground = previousForeground
			if (card.isFocused)
				applySupportTierCardFocusVisual(card, true)
			card.invalidate()
			onFinished()
		}

		val sweepAnimator = ValueAnimator.ofInt(0, 10_000).apply {
			duration = TIER_CARD_SWEEP_MS
			addUpdateListener {
				if (uiSession != supportPaywallUiSession)
				{
					cancel()
					return@addUpdateListener
				}
				clip.level = it.animatedValue as Int
				card.invalidate()
			}
			addListener(object : AnimatorListenerAdapter() {
				override fun onAnimationEnd(animation: Animator)
				{
					if (ended) return
					if (uiSession != supportPaywallUiSession || !card.isAttachedToWindow)
					{
						emitFinished()
						return
					}
					val fadeAnimator = ValueAnimator.ofInt(255, 0).apply {
						duration = TIER_CARD_SWEEP_FADE_MS
						addUpdateListener { anim ->
							if (ended) return@addUpdateListener
							clip.alpha = anim.animatedValue as Int
							card.invalidate()
						}
						addListener(object : AnimatorListenerAdapter() {
							override fun onAnimationEnd(animation: Animator) = emitFinished()

							override fun onAnimationCancel(animation: Animator) = emitFinished()
						})
					}
					activeTierSweepAnimator = fadeAnimator
					fadeAnimator.start()
				}

				override fun onAnimationCancel(animation: Animator)
				{
					emitFinished()
				}
			})
		}
		activeTierSweepAnimator?.cancel()
		activeTierSweepAnimator = sweepAnimator
		sweepAnimator.start()
	}

	/** After the staggered fade-in, run a border sweep on each card one-by-one. */
	private fun scheduleTierCardBorderSweepsAfterReveal(cards: List<MaterialCardView>, uiSession: Int)
	{
		if (cards.isEmpty()) return
		val n = cards.size
		val allFadesDoneMs = (n - 1).coerceAtLeast(0) * TIER_REVEAL_STAGGER_MS + TIER_REVEAL_DURATION_MS

		fun postSweepFromIndex(index: Int): Runnable
		{
			lateinit var runnable: Runnable
			runnable = Runnable {
				tierSweepScheduledRunnables.remove(runnable)
				if (uiSession != supportPaywallUiSession) return@Runnable
				if (index >= cards.size) return@Runnable
				startSupportTierCardBorderSweep(cards[index], uiSession) {
					if (uiSession != supportPaywallUiSession) return@startSupportTierCardBorderSweep
					val nextIndex = (index + 1) % cards.size
					val next = postSweepFromIndex(nextIndex)
					tierSweepScheduledRunnables.add(next)
					handler.postDelayed(next, TIER_CARD_SWEEP_GAP_MS)
				}
			}
			return runnable
		}

		val kickoff = postSweepFromIndex(0)
		tierSweepScheduledRunnables.add(kickoff)
		handler.postDelayed(kickoff, allFadesDoneMs)
	}

	private fun streamAutoPreconditionsPass(): Boolean
	{
		if (!streamAutoOffer) return true
		if (preferences.totalStreamTimeMs < MIN_STREAM_MS) return false
		val last = preferences.lastDonationPromptWallClockMs
		val now = System.currentTimeMillis()
		if (last > 0L && now - last < STREAM_AUTO_PROMPT_MIN_INTERVAL_MS) return false
		return true
	}

	fun scheduleOfferIfEligible()
	{
		if (!streamAutoOffer) return
		val orderedProductIds = donationProductIds(activity)
		if (orderedProductIds.isEmpty()) return
		if (!streamAutoPreconditionsPass()) return

		cancelScheduledOffer()
		pendingOfferRunnable = Runnable { beginBillingEvaluation(orderedProductIds) }
		handler.postDelayed(pendingOfferRunnable!!, SHOW_DELAY_MS)
	}

	/**
	 * Settings entry: same tier dialog as stream, with no stream-time or ownership checks.
	 * @return false only if there are no product IDs or the activity is finishing.
	 */
	fun openSupportFromSettings(): Boolean
	{
		val orderedProductIds = donationProductIds(activity)
		if (orderedProductIds.isEmpty()) return false
		if (activity.isFinishing) return false
		beginBillingEvaluation(orderedProductIds)
		return true
	}

	fun cancelScheduledOffer()
	{
		pendingOfferRunnable?.let { handler.removeCallbacks(it) }
		pendingOfferRunnable = null
	}

	fun onDestroy()
	{
		suppressDisconnectCallback = true
		cancelScheduledOffer()
		cancelPaywallPhraseReveal()
		clearTierBorderSweepScheduling()
		activeDialog?.dismiss()
		activeDialog = null
		billingClient?.endConnection()
		billingClient = null
		suppressDisconnectCallback = false
	}

	private fun endBilling()
	{
		billingClient?.endConnection()
		billingClient = null
		if (!suppressDisconnectCallback)
			onBillingDisconnected?.invoke()
	}

	/** Ends Play connection without [onBillingDisconnected] (Settings holder must stay alive until paywall dismiss). */
	private fun endBillingSilently()
	{
		billingClient?.endConnection()
		billingClient = null
	}

	private fun finishPurchaseFlowCleanup()
	{
		retainBillingForPurchaseFlow = false
		endBilling()
	}

	/** When Play Billing cannot load tiers, still show the paywall with PayPal QR (then [endBilling] on dismiss). */
	private fun offerPayPalPaywallAfterBillingFailure()
	{
		activity.runOnUiThread {
			if (activity.isFinishing) return@runOnUiThread
			if (streamAutoOffer && !streamAutoPreconditionsPass()) return@runOnUiThread
			endBillingSilently()
			showPaywallDialog(PaywallOffer.ExternalPayPal)
		}
	}

	private fun beginBillingEvaluation(orderedProductIds: List<String>)
	{
		pendingOfferRunnable = null
		if (activity.isFinishing) return
		if (!streamAutoPreconditionsPass()) return

		productIdsForAck = orderedProductIds.toSet()
		billingClient?.endConnection()
		val client = BillingClient.newBuilder(activity)
			.setListener(purchasesUpdatedListener)
			.enablePendingPurchases(
				PendingPurchasesParams.newBuilder()
					.enableOneTimeProducts()
					.build(),
			)
			.build()
		billingClient = client

		client.startConnection(object : BillingClientStateListener {
			override fun onBillingSetupFinished(billingResult: BillingResult)
			{
				if (billingResult.responseCode != BillingClient.BillingResponseCode.OK)
				{
					Log.w(TAG, "Billing setup failed: ${billingResult.responseCode} ${billingResult.debugMessage}")
					offerPayPalPaywallAfterBillingFailure()
					return
				}
				if (settingsAlwaysOpen)
					queryProductDetailsAndShow(client, orderedProductIds)
				else
					queryOwnedAndMaybeShow(client, productIdsForAck, orderedProductIds)
			}

			override fun onBillingServiceDisconnected()
			{
				Log.w(TAG, "Billing disconnected")
			}
		})
	}

	private fun queryOwnedAndMaybeShow(client: BillingClient, productIds: Set<String>, orderedProductIds: List<String>)
	{
		val params = QueryPurchasesParams.newBuilder()
			.setProductType(BillingClient.ProductType.INAPP)
			.build()
		client.queryPurchasesAsync(params) { billingResult, purchasesList ->
			if (billingResult.responseCode != BillingClient.BillingResponseCode.OK)
			{
				Log.w(TAG, "queryPurchases failed: ${billingResult.responseCode}")
				offerPayPalPaywallAfterBillingFailure()
				return@queryPurchasesAsync
			}
			val ownsAnyDonationTier = purchasesList.any { purchase ->
				purchase.purchaseState == Purchase.PurchaseState.PURCHASED &&
					purchase.products.any { it in productIds }
			}
			if (ownsAnyDonationTier)
			{
				if (streamAutoOffer)
					preferences.lastDonationPromptWallClockMs = System.currentTimeMillis()
				activity.runOnUiThread {
					if (!activity.isFinishing)
						android.widget.Toast.makeText(
							activity,
							R.string.preferences_donate_already_supporting,
							android.widget.Toast.LENGTH_LONG,
						).show()
				}
				endBilling()
				return@queryPurchasesAsync
			}
			queryProductDetailsAndShow(client, orderedProductIds)
		}
	}

	private fun queryProductDetailsAndShow(client: BillingClient, orderedProductIds: List<String>)
	{
		val params = QueryProductDetailsParams.newBuilder()
			.setProductList(
				orderedProductIds.map { id ->
					QueryProductDetailsParams.Product.newBuilder()
						.setProductId(id)
						.setProductType(BillingClient.ProductType.INAPP)
						.build()
				},
			)
			.build()

		client.queryProductDetailsAsync(
			params,
			object : ProductDetailsResponseListener {
				override fun onProductDetailsResponse(
					billingResult: BillingResult,
					productDetailsResult: QueryProductDetailsResult,
				) {
					if (billingResult.responseCode != BillingClient.BillingResponseCode.OK)
					{
						Log.w(TAG, "queryProductDetails failed: ${billingResult.responseCode} ${billingResult.debugMessage}")
						offerPayPalPaywallAfterBillingFailure()
						return
					}
					val detailsList = productDetailsResult.productDetailsList
					val byId = detailsList.associateBy { d -> d.productId }
					val orderedDetails = orderedProductIds.mapNotNull { id ->
						val pd = byId[id] ?: return@mapNotNull null
						if (primaryOneTimeOffer(pd) == null) null else pd
					}
					if (orderedDetails.isEmpty())
					{
						Log.w(TAG, "No donation tiers loaded (check SKUs / Play Console / offers)")
						offerPayPalPaywallAfterBillingFailure()
						return
					}
					activity.runOnUiThread {
						if (activity.isFinishing) {
							endBilling()
							return@runOnUiThread
						}
						if (streamAutoOffer && !streamAutoPreconditionsPass()) {
							endBilling()
							return@runOnUiThread
						}
						showPaywallDialog(PaywallOffer.PlayStoreTiers(orderedDetails))
					}
				}
			},
		)
	}

	private fun paypalSupportUrl(): String =
		activity.getString(R.string.donation_paypal_fallback_url)

	private fun qrCodeBitmapForUrl(url: String, sizePx: Int): Bitmap?
	{
		return try
		{
			val hints = hashMapOf<EncodeHintType, Any>().apply {
				put(EncodeHintType.MARGIN, 2)
				put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M)
			}
			val matrix = QRCodeWriter().encode(url, BarcodeFormat.QR_CODE, sizePx, sizePx, hints)
			val w = matrix.width
			val h = matrix.height
			val pixels = IntArray(w * h)
			for (y in 0 until h)
			{
				val row = y * w
				for (x in 0 until w)
					pixels[row + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
			}
			Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply {
				setPixels(pixels, 0, w, 0, 0, w, h)
			}
		}
		catch (e: Exception)
		{
			Log.w(TAG, "QR generation failed", e)
			null
		}
	}

	private fun bindPayPalFallbackContent(binding: DialogSupportPaywallBinding)
	{
		val url = paypalSupportUrl()
		val qr = binding.supportPaywallQr
		val sizePx = TypedValue.applyDimension(
			TypedValue.COMPLEX_UNIT_DIP,
			240f,
			activity.resources.displayMetrics,
		).toInt().coerceIn(256, 768)
		val bmp = qrCodeBitmapForUrl(url, sizePx)
		if (bmp != null)
			qr.setImageBitmap(bmp)
		else
			qr.setImageDrawable(null)

		fun openPayPal()
		{
			try
			{
				activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
			}
			catch (_: ActivityNotFoundException)
			{
				Toast.makeText(activity, R.string.donation_paywall_external_no_browser, Toast.LENGTH_LONG).show()
			}
		}
		binding.supportPaywallOpenPaypal.setOnClickListener { openPayPal() }
		qr.setOnClickListener { openPayPal() }

		// Android TV: views need focusable+clickable in XML; move focus to an obvious action.
		if (activity.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK))
		{
			binding.supportPaywallOpenPaypal.post {
				binding.supportPaywallOpenPaypal.requestFocus()
			}
		}
	}

	private fun applyPaywallOfferMode(binding: DialogSupportPaywallBinding, offer: PaywallOffer)
	{
		when (offer)
		{
			is PaywallOffer.PlayStoreTiers ->
			{
				binding.supportPaywallExternalFallback.visibility = View.GONE
				binding.supportTierList.visibility = View.VISIBLE
				binding.supportRestorePurchases.visibility = View.VISIBLE
				binding.supportTrustLine.setText(R.string.donation_paywall_trust)
				if (activity.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT)
				{
					binding.supportPaywallPickTitle.visibility = View.VISIBLE
					binding.supportPaywallPickHint.visibility = View.VISIBLE
				}
			}
			PaywallOffer.ExternalPayPal ->
			{
				binding.supportPaywallExternalFallback.visibility = View.VISIBLE
				binding.supportTierList.visibility = View.GONE
				binding.supportPaywallPickTitle.visibility = View.GONE
				binding.supportPaywallPickHint.visibility = View.GONE
				binding.supportRestorePurchases.visibility = View.GONE
				binding.supportTrustLine.setText(R.string.donation_paywall_trust_paypal)
				bindPayPalFallbackContent(binding)
			}
		}
	}

	/** One slim row in landscape: trust + actions, so the footer does not eat vertical space. */
	private fun configureSupportPaywallFooterForOrientation(binding: DialogSupportPaywallBinding)
	{
		if (activity.resources.configuration.orientation != Configuration.ORIENTATION_LANDSCAPE)
			return

		val density = activity.resources.displayMetrics.density
		fun dp(v: Int) = (v * density + 0.5f).toInt()

		val footer = binding.supportPaywallFooter
		val actionsHost = binding.supportPaywallFooterActions
		val restore = binding.supportRestorePurchases
		val later = binding.supportMaybeLater
		val trust = binding.supportTrustLine

		actionsHost.removeView(restore)
		actionsHost.removeView(later)
		footer.removeView(actionsHost)

		footer.orientation = LinearLayout.HORIZONTAL
		footer.gravity = Gravity.CENTER_VERTICAL
		footer.setPaddingRelative(footer.paddingStart, dp(4), footer.paddingEnd, dp(4))

		footer.addView(restore)
		footer.addView(later)

		trust.apply {
			gravity = Gravity.START or Gravity.CENTER_VERTICAL
			setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
			(layoutParams as LinearLayout.LayoutParams).apply {
				width = 0
				weight = 1f
				height = LinearLayout.LayoutParams.WRAP_CONTENT
				marginEnd = dp(8)
			}
		}
		restore.apply {
			setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
			(layoutParams as LinearLayout.LayoutParams).apply {
				width = LinearLayout.LayoutParams.WRAP_CONTENT
				height = LinearLayout.LayoutParams.WRAP_CONTENT
				weight = 0f
				marginEnd = dp(6)
			}
			minimumHeight = dp(36)
		}
		later.apply {
			setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
			(layoutParams as LinearLayout.LayoutParams).apply {
				width = LinearLayout.LayoutParams.WRAP_CONTENT
				height = LinearLayout.LayoutParams.WRAP_CONTENT
				weight = 0f
			}
			minimumHeight = dp(36)
		}
	}

	/**
	 * First tier (bronze) for Play after reveal stroke animation finishes (so animators do not clobber focus stroke).
	 * PayPal: focus link immediately.
	 */
	private fun focusFirstPaywallDonateTarget(
		binding: DialogSupportPaywallBinding,
		offer: PaywallOffer,
		tierCards: List<MaterialCardView>,
		paywallUiSession: Int,
	)
	{
		when (offer)
		{
			is PaywallOffer.PlayStoreTiers ->
			{
				val first = tierCards.firstOrNull() ?: return
				first.isFocusableInTouchMode = true
				handler.postDelayed({
					if (paywallUiSession != supportPaywallUiSession) return@postDelayed
					if (!first.isAttachedToWindow) return@postDelayed
					val cf = activity.currentFocus
					if (cf != null && tierCards.any { it === cf } && cf !== first) return@postDelayed
					first.requestFocus()
					if (first.isFocused)
						applySupportTierCardFocusVisual(first, true)
				}, TIER_REVEAL_DURATION_MS)
			}
			PaywallOffer.ExternalPayPal ->
			{
				val link = binding.supportPaywallOpenPaypal
				link.isFocusableInTouchMode = true
				link.post { link.requestFocus() }
			}
		}
	}

	private fun showPaywallDialog(offer: PaywallOffer)
	{
		if (streamAutoOffer)
			preferences.lastDonationPromptWallClockMs = System.currentTimeMillis()

		val paywallShowCount = preferences.incrementDonationPaywallShowCount()

		val paywallUiSession = supportPaywallUiSession

		cancelPaywallPhraseReveal()

		val binding = DialogSupportPaywallBinding.inflate(activity.layoutInflater)
		applyPaywallOfferMode(binding, offer)
		val rotatingPhrase = DonationPhrasePicker.phraseForPaywallShowCount(activity, paywallShowCount)
		if (rotatingPhrase != null)
		{
			binding.supportPaywallStoryBullets.visibility = View.GONE
			binding.supportPaywallStoryPhrase.visibility = View.VISIBLE
			binding.supportPaywallStoryPhrase.post {
				startPaywallPhraseReveal(binding.supportPaywallStoryPhrase, rotatingPhrase)
			}
		}
		else
		{
			binding.supportPaywallStoryBullets.visibility = View.VISIBLE
			binding.supportPaywallStoryPhrase.visibility = View.GONE
			binding.supportPaywallStoryPhrase.alpha = 1f
		}
		val sheet = BottomSheetDialog(activity, R.style.SupportPaywallBottomSheet)
		sheet.setContentView(binding.root)
		sheet.setCanceledOnTouchOutside(true)
		if (offer is PaywallOffer.PlayStoreTiers)
			configureSupportPaywallFooterForOrientation(binding)

		val tierCards = mutableListOf<MaterialCardView>()

		sheet.setOnShowListener {
			val bottom = sheet.findViewById<FrameLayout>(com.google.android.material.R.id.design_bottom_sheet)
				?: return@setOnShowListener
			// Solid sheet background; blue frame is a brief pulse overlay (see startSupportPaywallBorderPulse).
			bottom.background = ColorDrawable(ContextCompat.getColor(activity, R.color.primary_dark))
			bottom.backgroundTintList = null
			bottom.clipToOutline = false
			val dm = activity.resources.displayMetrics
			val screenW = dm.widthPixels
			val screenH = dm.heightPixels

			// Entire sheet (including blue frame) must sit below the status bar. Coordinator topMargin is ignored
			// for expanded bottom sheets; use expandedOffset = status/cutout top (see Material BottomSheetBehavior).
			bottom.layoutParams.apply {
				width = ViewGroup.LayoutParams.MATCH_PARENT
				height = ViewGroup.LayoutParams.MATCH_PARENT
			}
			sheet.window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)

			val behavior = BottomSheetBehavior.from(bottom)
			behavior.skipCollapsed = true
			behavior.isFitToContents = false
			behavior.peekHeight = screenH
			behavior.maxWidth = screenW
			behavior.isDraggable = false
			behavior.expandedOffset = statusBarHeightFallbackPx()
			behavior.state = BottomSheetBehavior.STATE_EXPANDED

			fun applyPaywallInsets(insets: WindowInsetsCompat)
			{
				val sys = insets.getInsets(WindowInsetsCompat.Type.systemBars())
				val cut = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
				val nav = insets.getInsets(WindowInsetsCompat.Type.navigationBars())
				val topPx = paywallTopInsetPx(insets)
				val bottomPx = maxOf(sys.bottom, cut.bottom, nav.bottom)
				val parent = bottom.parent as? View
				val parentH = parent?.height ?: 0
				when (val lp = bottom.layoutParams)
				{
					is CoordinatorLayout.LayoutParams ->
					{
						lp.leftMargin = maxOf(sys.left, cut.left)
						lp.topMargin = 0
						lp.rightMargin = maxOf(sys.right, cut.right)
						// expandedOffset lowers the top; MATCH_PARENT height still uses full parent height,
						// so the sheet draws past the bottom — fit height between top inset and nav/gesture inset.
						lp.bottomMargin = 0
						if (parentH > 0)
						{
							val h = parentH - topPx - bottomPx
							lp.height = h.coerceAtLeast(1)
						}
						bottom.layoutParams = lp
					}
					else -> { }
				}
				behavior.expandedOffset = topPx
				behavior.state = BottomSheetBehavior.STATE_EXPANDED
				if (parentH <= 0)
				{
					bottom.post {
						if (((bottom.parent as? View)?.height ?: 0) > 0)
							ViewCompat.getRootWindowInsets(bottom)?.let { applyPaywallInsets(it) }
					}
				}
			}

			ViewCompat.setOnApplyWindowInsetsListener(bottom) { _, insets ->
				applyPaywallInsets(insets)
				insets
			}
			ViewCompat.requestApplyInsets(bottom)
			bottom.post {
				ViewCompat.getRootWindowInsets(bottom)?.let { applyPaywallInsets(it) }
				startSupportPaywallBorderPulse(bottom)
				focusFirstPaywallDonateTarget(binding, offer, tierCards, paywallUiSession)
			}
		}

		fun dismissSheet()
		{
			sheet.dismiss()
		}

		binding.supportMaybeLater.setOnClickListener { dismissSheet() }
		binding.supportRestorePurchases.setOnClickListener {
			restoreDonationPurchases(::dismissSheet)
		}

		val tierSpacing = activity.resources.getDimensionPixelSize(R.dimen.support_tier_card_spacing)

		fun inflateTierCard(details: ProductDetails, offer: ProductDetails.OneTimePurchaseOfferDetails, price: String): MaterialCardView
		{
			val itemBinding = ItemSupportTierBinding.inflate(activity.layoutInflater, binding.supportTierList, false)
			val tierName = tierDisplayName(details.productId)
			itemBinding.tierName.text = tierName
			itemBinding.tierBlurb.text = tierBlurb(details.productId)
			itemBinding.tierPrice.text = price
			val card = itemBinding.root as MaterialCardView
			card.contentDescription = activity.getString(R.string.donation_tier_content_description, tierName, price)
			card.onFocusChangeListener = View.OnFocusChangeListener { v, hasFocus ->
				applySupportTierCardFocusVisual(v as MaterialCardView, hasFocus)
			}
			card.setOnClickListener {
				retainBillingForPurchaseFlow = true
				launchPurchaseFlow(details, offer)
				dismissSheet()
			}
			return card
		}

		var tierRevealIndex = 0
		if (offer is PaywallOffer.PlayStoreTiers)
		{
			for (details in offer.details)
			{
				val oneTime = primaryOneTimeOffer(details) ?: continue
				val price = oneTime.formattedPrice
				if (price.isNullOrEmpty()) continue
				val lp = LinearLayout.LayoutParams(
					LinearLayout.LayoutParams.MATCH_PARENT,
					LinearLayout.LayoutParams.WRAP_CONTENT,
				).apply {
					topMargin = if (binding.supportTierList.childCount == 0) 0 else tierSpacing
				}
				val card = inflateTierCard(details, oneTime, price)
				binding.supportTierList.addView(card, lp)
				tierCards.add(card)
				animateSupportTierCardReveal(card, tierRevealIndex++)
			}
		}
		if (tierCards.isNotEmpty())
			scheduleTierCardBorderSweepsAfterReveal(tierCards, paywallUiSession)

		sheet.setOnDismissListener {
			cancelPaywallPhraseReveal()
			clearTierBorderSweepScheduling()
			supportPaywallUiSession++
			activeDialog = null
			if (!retainBillingForPurchaseFlow)
				endBilling()
		}
		activeDialog = sheet
		sheet.show()
	}

	private fun animateSupportTierCardReveal(card: MaterialCardView, staggerIndex: Int)
	{
		val dm = activity.resources.displayMetrics
		val endStrokePx = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 1f, dm).toInt()
		val startStrokePx = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 2.5f, dm).toInt()
		val startColor = ContextCompat.getColor(activity, R.color.pylux_blue)
		val endColor = ContextCompat.getColor(activity, R.color.support_tier_card_stroke)

		card.alpha = 0f
		card.translationY = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 8f, dm)
		card.strokeWidth = startStrokePx
		card.setStrokeColor(ColorStateList.valueOf(startColor))

		val delay = staggerIndex * TIER_REVEAL_STAGGER_MS
		val duration = TIER_REVEAL_DURATION_MS
		val interpolator = FastOutSlowInInterpolator()

		card.post {
			card.animate()
				.alpha(1f)
				.translationY(0f)
				.setStartDelay(delay)
				.setDuration(duration)
				.setInterpolator(interpolator)
				.start()

			ValueAnimator.ofInt(startStrokePx, endStrokePx).apply {
				startDelay = delay
				this.duration = duration
				this.interpolator = interpolator
				addUpdateListener {
					if (card.isFocused)
					{
						applySupportTierCardFocusVisual(card, true)
						return@addUpdateListener
					}
					card.strokeWidth = it.animatedValue as Int
				}
			}.start()

			ValueAnimator.ofObject(ArgbEvaluator(), startColor, endColor).apply {
				startDelay = delay
				this.duration = duration
				this.interpolator = interpolator
				addUpdateListener {
					if (card.isFocused)
					{
						applySupportTierCardFocusVisual(card, true)
						return@addUpdateListener
					}
					card.setStrokeColor(ColorStateList.valueOf(it.animatedValue as Int))
				}
			}.start()
		}
	}

	private fun tierDisplayName(productId: String): String =
		when (productId)
		{
			"pylux_support_bronze" -> activity.getString(R.string.donation_tier_bronze)
			"pylux_support_silver" -> activity.getString(R.string.donation_tier_silver)
			"pylux_support_gold" -> activity.getString(R.string.donation_tier_gold)
			"pylux_support_platinum" -> activity.getString(R.string.donation_tier_platinum)
			else -> productId.substringAfterLast('_').replaceFirstChar { it.uppercaseChar() }
		}

	private fun tierBlurb(productId: String): String
	{
		val res = when (productId)
		{
			"pylux_support_bronze" -> R.string.donation_tier_blurb_bronze
			"pylux_support_silver" -> R.string.donation_tier_blurb_silver
			"pylux_support_gold" -> R.string.donation_tier_blurb_gold
			"pylux_support_platinum" -> R.string.donation_tier_blurb_platinum
			else -> R.string.donation_tier_blurb_default
		}
		return activity.getString(res)
	}

	private fun launchPurchaseFlow(details: ProductDetails, offer: ProductDetails.OneTimePurchaseOfferDetails)
	{
		val client = billingClient ?: return
		val token = offer.offerToken
		if (token.isNullOrEmpty())
		{
			Log.e(TAG, "Missing offer token for ${details.productId}")
			return
		}
		val productParams = BillingFlowParams.ProductDetailsParams.newBuilder()
			.setProductDetails(details)
			.setOfferToken(token)
			.build()
		val flowParams = BillingFlowParams.newBuilder()
			.setProductDetailsParamsList(listOf(productParams))
			.build()
		val launchResult = client.launchBillingFlow(activity, flowParams)
		if (launchResult.responseCode != BillingClient.BillingResponseCode.OK)
		{
			Log.e(TAG, "launchBillingFlow failed: ${launchResult.responseCode} ${launchResult.debugMessage}")
		}
	}

	/**
	 * Re-fetch INAPP purchases from Play, acknowledge any unacknowledged donation SKUs,
	 * and give clear feedback (typical restore flow for one-time products).
	 */
	private fun restoreDonationPurchases(dismissSheet: () -> Unit)
	{
		val client = billingClient
		if (client == null)
		{
			android.widget.Toast.makeText(
				activity,
				R.string.donation_paywall_restore_unavailable,
				android.widget.Toast.LENGTH_SHORT,
			).show()
			return
		}
		val params = QueryPurchasesParams.newBuilder()
			.setProductType(BillingClient.ProductType.INAPP)
			.build()
		client.queryPurchasesAsync(params) { billingResult, purchasesList ->
			val ok = billingResult.responseCode == BillingClient.BillingResponseCode.OK
			val donations = if (ok)
				purchasesList.filter { purchase ->
					purchase.purchaseState == Purchase.PurchaseState.PURCHASED &&
						purchase.products.any { it in productIdsForAck }
				}
			else
				emptyList()
			activity.runOnUiThread {
				if (activity.isFinishing) return@runOnUiThread
				if (!ok)
				{
					android.widget.Toast.makeText(
						activity,
						R.string.donation_paywall_restore_unavailable,
						android.widget.Toast.LENGTH_SHORT,
					).show()
					return@runOnUiThread
				}
				when
				{
					donations.isEmpty() ->
						android.widget.Toast.makeText(
							activity,
							R.string.donation_paywall_restore_none,
							android.widget.Toast.LENGTH_LONG,
						).show()
					donations.all { it.isAcknowledged } ->
					{
						android.widget.Toast.makeText(
							activity,
							R.string.donation_paywall_restore_already,
							android.widget.Toast.LENGTH_LONG,
						).show()
						dismissSheet()
						finishPurchaseFlowCleanup()
					}
					else ->
					{
						val pending = donations.filter { !it.isAcknowledged }
						acknowledgeDonationsSequentially(pending, 0) {
							activity.runOnUiThread {
								if (activity.isFinishing) return@runOnUiThread
								android.widget.Toast.makeText(
									activity,
									R.string.donation_paywall_restore_success,
									android.widget.Toast.LENGTH_LONG,
								).show()
								dismissSheet()
								finishPurchaseFlowCleanup()
							}
						}
					}
				}
			}
		}
	}

	private fun acknowledgeDonationsSequentially(
		purchases: List<Purchase>,
		index: Int,
		onComplete: () -> Unit,
	)
	{
		if (index >= purchases.size)
		{
			onComplete()
			return
		}
		val client = billingClient
		if (client == null)
		{
			onComplete()
			return
		}
		val purchase = purchases[index]
		val ackParams = AcknowledgePurchaseParams.newBuilder()
			.setPurchaseToken(purchase.purchaseToken)
			.build()
		client.acknowledgePurchase(ackParams) { result ->
			Log.i(TAG, "Restore acknowledge ${index + 1}/${purchases.size}: ${result.responseCode}")
			handler.post {
				acknowledgeDonationsSequentially(purchases, index + 1, onComplete)
			}
		}
	}

	private fun handlePurchase(purchase: Purchase)
	{
		if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return
		val isDonation = purchase.products.any { it in productIdsForAck }
		if (!isDonation) return

		if (!purchase.isAcknowledged)
		{
			val ackParams = AcknowledgePurchaseParams.newBuilder()
				.setPurchaseToken(purchase.purchaseToken)
				.build()
			billingClient?.acknowledgePurchase(ackParams) { result ->
				Log.i(TAG, "Acknowledge result: ${result.responseCode}")
			}
		}
		activity.runOnUiThread {
			activeDialog?.dismiss()
		}
		finishPurchaseFlowCleanup()
	}

	private fun primaryOneTimeOffer(details: ProductDetails): ProductDetails.OneTimePurchaseOfferDetails?
	{
		val fromList = details.oneTimePurchaseOfferDetailsList
		if (!fromList.isNullOrEmpty())
			return fromList.first()
		@Suppress("DEPRECATION")
		return details.oneTimePurchaseOfferDetails
	}
}
