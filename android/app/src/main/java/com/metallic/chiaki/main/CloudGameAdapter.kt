// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import coil.dispose
import coil.load
import coil.request.CachePolicy
import com.pylux.stream.R
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.common.ext.enableFocusableInTouchModeForTv
import com.pylux.stream.databinding.ItemCloudGameBinding

class CloudGameAdapter(
	private val onGameClick: (CloudGame) -> Unit,
	private val onFavoriteClick: (CloudGame, Boolean) -> Unit,
	private val isFavorite: (String) -> Boolean,
	val onFavoriteKeyToggled: (() -> Unit)? = null
) : RecyclerView.Adapter<CloudGameAdapter.CloudGameViewHolder>()
{
	companion object {
		const val PAYLOAD_RELOAD_IMAGE = "reload_image"
	}

	init { setHasStableIds(true) }

	var games: List<CloudGame> = emptyList()
		set(value)
		{
			field = value
			notifyDataSetChanged()
		}

	var showOwnershipBadge: Boolean = false
		set(value)
		{
			field = value
			notifyDataSetChanged()
		}

	var isScrollingFast = false

	override fun getItemId(position: Int): Long = games[position].productId.hashCode().toLong()

	override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): CloudGameViewHolder
	{
		val binding = ItemCloudGameBinding.inflate(
			LayoutInflater.from(parent.context),
			parent,
			false
		)
		binding.root.enableFocusableInTouchModeForTv(parent.context)

		// MaterialCardView.drawableStateChanged() only updates ripple, not stroke.
		// Drive the focus stroke imperatively so it works in all Android touch modes.
		val focusedStrokeColor = 0xFF009FE3.toInt()
		val focusedStrokeWidth = (3 * parent.context.resources.displayMetrics.density + 0.5f).toInt()
		binding.root.setOnFocusChangeListener { _, hasFocus ->
			val card = binding.root as? com.google.android.material.card.MaterialCardView ?: return@setOnFocusChangeListener
			if (hasFocus) {
				card.strokeColor = focusedStrokeColor
				card.strokeWidth = focusedStrokeWidth
			} else {
				card.strokeColor = android.graphics.Color.TRANSPARENT
				card.strokeWidth = 0
			}
		}

		return CloudGameViewHolder(binding)
	}

	override fun onBindViewHolder(holder: CloudGameViewHolder, position: Int)
	{
		holder.bind(games[position])
	}

	override fun onBindViewHolder(holder: CloudGameViewHolder, position: Int, payloads: MutableList<Any>)
	{
		if (payloads.contains(PAYLOAD_RELOAD_IMAGE))
			holder.reloadImage(games[position])
		else
			super.onBindViewHolder(holder, position, payloads)
	}

	override fun onViewRecycled(holder: CloudGameViewHolder)
	{
		super.onViewRecycled(holder)
		holder.cancelImage()
	}

	override fun getItemCount(): Int = games.size

	inner class CloudGameViewHolder(
		val binding: ItemCloudGameBinding
	) : RecyclerView.ViewHolder(binding.root)
	{
		fun cancelImage()
		{
			binding.gameImageView.dispose()
		}

		fun reloadImage(game: CloudGame)
		{
			if (game.imageUrl.isNotEmpty()) {
				binding.gameImageView.load(game.imageUrl) {
					memoryCachePolicy(CachePolicy.ENABLED)
					diskCachePolicy(CachePolicy.ENABLED)
					networkCachePolicy(CachePolicy.ENABLED)
					crossfade(false)
				}
			}
		}

		fun bind(game: CloudGame)
		{
			binding.gameNameTextView.text = game.name
			// Reset focus stroke immediately — recycled views may carry stale blue border
			val card = binding.root as? com.google.android.material.card.MaterialCardView
			if (card != null && !card.hasFocus()) {
				card.strokeColor = android.graphics.Color.TRANSPARENT
				card.strokeWidth = 0
			}
			// Platform badge: the lib derives the authoritative platform from the catalog's device[]
			// array (NOT the CUSA/PPSA productId token), so just render it.
			binding.gamePlatformTextView.text = when (game.platform.lowercase()) {
				"ps3" -> "3"
				"ps4" -> "4"
				"ps5" -> "5"
				else -> game.platform.takeLast(1)
			}

			// Acquisition-tag badge (unified page): Owned (green) / Streamable (blue) /
			// Purchaseable (orange). The lib precomputes the category; render it verbatim.
			val category = game.category
			if (showOwnershipBadge) {
				binding.ownershipBadge.visibility = android.view.View.VISIBLE
				when (category) {
					"owned" -> {
						binding.ownershipBadge.text = "Owned"
						binding.ownershipBadge.setBackgroundColor(0xCC4CAF50.toInt())
					}
					"streamable" -> {
						binding.ownershipBadge.text = "Streamable"
						binding.ownershipBadge.setBackgroundColor(0xCC2196F3.toInt())
					}
					else -> {
						binding.ownershipBadge.text = "Add Game"
						binding.ownershipBadge.setBackgroundColor(0xCCFF9800.toInt())
					}
				}
			} else {
				binding.ownershipBadge.visibility = android.view.View.GONE
			}

			val isFav = isFavorite(game.productId)
			binding.favoriteButton.setImageResource(
				if (isFav) R.drawable.ic_star_filled else R.drawable.ic_star_outline
			)

			binding.loadingSpinner?.visibility = android.view.View.GONE
			if (game.imageUrl.isEmpty())
			{
				binding.gameImageView.setImageResource(android.R.drawable.ic_menu_gallery)
			}
			else
			{
				binding.gameImageView.load(game.imageUrl) {
					memoryCachePolicy(CachePolicy.ENABLED)
					diskCachePolicy(if (isScrollingFast) CachePolicy.DISABLED else CachePolicy.ENABLED)
					networkCachePolicy(if (isScrollingFast) CachePolicy.DISABLED else CachePolicy.ENABLED)
					crossfade(false)
				}
			}

			binding.root.setOnClickListener {
				onGameClick(game)
			}

			val toggleFavorite = {
				val newFavoriteState = !isFavorite(game.productId)
				onFavoriteClick(game, newFavoriteState)
				binding.favoriteButton.setImageResource(
					if (newFavoriteState) R.drawable.ic_star_filled else R.drawable.ic_star_outline
				)
			}

			binding.favoriteButton.setOnClickListener { toggleFavorite() }
			binding.root.setOnLongClickListener {
				toggleFavorite()
				true
			}
			binding.root.setOnKeyListener { _, keyCode, event ->
				if (event.action == android.view.KeyEvent.ACTION_DOWN &&
					keyCode == android.view.KeyEvent.KEYCODE_BUTTON_SELECT) {
					toggleFavorite()
					onFavoriteKeyToggled?.invoke()
					true
				} else {
					false
				}
			}
		}
	}
}

