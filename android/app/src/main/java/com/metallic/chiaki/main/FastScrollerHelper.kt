// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.widget.TextView
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.metallic.chiaki.cloudplay.model.CloudGame

/**
 * Helper class to manage fast scrolling functionality for a RecyclerView.
 * Attaches a touch listener to a wide touch zone on the right side of the screen.
 * Dragging anywhere in the zone scrolls the list and moves the visible thumb.
 * On TV (D-pad navigation), the scroller is hidden since users navigate with D-pad.
 */
class FastScrollerHelper(
	private val recyclerView: RecyclerView,
	private val thumbView: View,
	private val touchZone: View,
	private val sectionIndicator: TextView,
	private val gameCountText: TextView,
	private val adapter: CloudGameAdapter,
	private val gamesProvider: () -> List<CloudGame>
) {
	private val isTv: Boolean by lazy {
		val uiModeManager = recyclerView.context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
		uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
	}
	private var isDragging = false
	private val idleHandler = Handler(Looper.getMainLooper())
	private val idleRunnable = Runnable {
		adapter.isScrollingFast = false
		// Reload images for visible cards that got a placeholder during fast scroll.
		// Debounced so rapid key presses don't trigger a rebind mid-navigation (which drops focus).
		val lm = recyclerView.layoutManager as? GridLayoutManager ?: return@Runnable
		val first = lm.findFirstVisibleItemPosition()
		val last = lm.findLastVisibleItemPosition()
		if (first >= 0 && last >= first) {
			adapter.notifyItemRangeChanged(first, last - first + 1, PAYLOAD_RELOAD_IMAGE)
		}
	}

	private val scrollListener = object : RecyclerView.OnScrollListener() {
		override fun onScrollStateChanged(recyclerView: RecyclerView, newState: Int) {
			when (newState) {
				RecyclerView.SCROLL_STATE_DRAGGING,
				RecyclerView.SCROLL_STATE_SETTLING -> {
					idleHandler.removeCallbacks(idleRunnable)
					adapter.isScrollingFast = true
					// Transfer focus from the focused card to the RecyclerView itself.
					// This prevents Android from auto-focusing the header when the
					// focused card view is recycled off-screen during scroll.
					if (recyclerView.focusedChild != null) {
						recyclerView.isFocusableInTouchMode = true
						recyclerView.descendantFocusability = android.view.ViewGroup.FOCUS_BEFORE_DESCENDANTS
						recyclerView.requestFocus()
					}
				}
				RecyclerView.SCROLL_STATE_IDLE -> {
					// Restore normal descendant focus so D-pad can navigate into cards again.
					recyclerView.descendantFocusability = android.view.ViewGroup.FOCUS_AFTER_DESCENDANTS
					// Debounce the image reload so rapid key presses don't rebind mid-navigation.
					idleHandler.removeCallbacks(idleRunnable)
					idleHandler.postDelayed(idleRunnable, 250)
				}
			}
		}
		
		override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
			if (isDragging) return
			updateThumbPosition()
			updateGameCountScroll()
		}
	}
	
	private fun setFastScrolling(fast: Boolean) {
		adapter.isScrollingFast = fast
	}

	companion object {
		const val PAYLOAD_RELOAD_IMAGE = "reload_image"
	}
	
	fun setup() {
		recyclerView.isNestedScrollingEnabled = false
		recyclerView.addOnScrollListener(scrollListener)
		setupTouchHandler()
	}
	
	fun cleanup() {
		idleHandler.removeCallbacks(idleRunnable)
		recyclerView.removeOnScrollListener(scrollListener)
		touchZone.setOnTouchListener(null)
	}
	
	fun updateVisibility() {
		val gameCount = gamesProvider().size
		gameCountText.text = "$gameCount ${if (gameCount == 1) "game" else "games"}"
		gameCountText.visibility = if (gameCount > 0) View.VISIBLE else View.GONE
		val show = !isTv && gameCount > 10
		thumbView.visibility = if (show) View.VISIBLE else View.GONE
		touchZone.visibility = if (show) View.VISIBLE else View.GONE
	}
	
	private fun updateThumbPosition() {
		val layoutManager = recyclerView.layoutManager as? GridLayoutManager ?: return
		val firstVisible = layoutManager.findFirstVisibleItemPosition()
		val totalItems = gamesProvider().size
		if (totalItems <= 0 || firstVisible < 0) return
		
		val proportion = firstVisible.toFloat() / (totalItems - 1).coerceAtLeast(1)
		val parent = thumbView.parent as? View ?: return
		val maxY = (parent.height - thumbView.height).coerceAtLeast(0).toFloat()
		thumbView.y = (proportion * maxY).coerceIn(0f, maxY)
	}
	
	private fun updateGameCountScroll() {
		val scrollY = recyclerView.computeVerticalScrollOffset()
		gameCountText.translationY = -scrollY.toFloat()
			.coerceAtLeast(0f)
			.coerceAtMost(gameCountText.height.toFloat())
	}
	
	private fun setupTouchHandler() {
		touchZone.setOnTouchListener { _, event ->
			val parent = thumbView.parent as? View ?: return@setOnTouchListener false
			val maxThumbY = (parent.height - thumbView.height).coerceAtLeast(0).toFloat()
			
			when (event.action) {
				MotionEvent.ACTION_DOWN -> {
					isDragging = true
					setFastScrolling(true)
					recyclerView.stopScroll()
					thumbView.y = event.y.coerceIn(0f, maxThumbY)
					sectionIndicator.visibility = View.VISIBLE
					scrollToThumbPosition(maxThumbY)
					true
				}
				MotionEvent.ACTION_MOVE -> {
					if (!isDragging) return@setOnTouchListener false
					thumbView.y = event.y.coerceIn(0f, maxThumbY)
					scrollToThumbPosition(maxThumbY)
					true
				}
				MotionEvent.ACTION_UP,
				MotionEvent.ACTION_CANCEL -> {
					recyclerView.stopScroll()
					isDragging = false
					setFastScrolling(false)
					sectionIndicator.postDelayed({
						sectionIndicator.visibility = View.GONE
					}, 500)
					true
				}
				else -> false
			}
		}
	}
	
	private fun scrollToThumbPosition(maxThumbY: Float) {
		val proportion = if (maxThumbY > 0) (thumbView.y / maxThumbY).coerceIn(0f, 1f) else 0f
		val games = gamesProvider()
		if (games.isEmpty()) return
		
		val scrollRange = recyclerView.computeVerticalScrollRange()
		val scrollOffset = recyclerView.computeVerticalScrollOffset()
		val scrollExtent = recyclerView.computeVerticalScrollExtent()
		val maxScroll = (scrollRange - scrollExtent).coerceAtLeast(0)
		val targetOffset = (proportion * maxScroll).toInt()
		val scrollDelta = targetOffset - scrollOffset
		
		if (scrollDelta != 0) {
			recyclerView.scrollBy(0, scrollDelta)
		}
		
		val layoutManager = recyclerView.layoutManager as? GridLayoutManager
		val firstVisible = layoutManager?.findFirstVisibleItemPosition() ?: 0
		val pos = firstVisible.coerceIn(0, games.size - 1)
		val firstLetter = games[pos].name.firstOrNull()?.uppercaseChar()?.toString() ?: "#"
		sectionIndicator.text = firstLetter
	}
}
