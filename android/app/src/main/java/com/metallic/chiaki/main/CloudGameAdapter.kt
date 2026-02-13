// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.util.Log
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import coil.load
import coil.request.ErrorResult
import coil.request.SuccessResult
import com.pylux.stream.R
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.pylux.stream.databinding.ItemCloudGameBinding

class CloudGameAdapter(
	private val onGameClick: (CloudGame) -> Unit,
	private val onFavoriteClick: (CloudGame, Boolean) -> Unit,
	private val isFavorite: (String) -> Boolean
) : RecyclerView.Adapter<CloudGameAdapter.CloudGameViewHolder>()
{
	companion object {
		private const val TAG = "CloudGameAdapter"
	}
	
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

	override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): CloudGameViewHolder
	{
		val binding = ItemCloudGameBinding.inflate(
			LayoutInflater.from(parent.context),
			parent,
			false
		)
		return CloudGameViewHolder(binding)
	}

	override fun onBindViewHolder(holder: CloudGameViewHolder, position: Int)
	{
		holder.bind(games[position])
	}

	override fun getItemCount(): Int = games.size

	inner class CloudGameViewHolder(
		private val binding: ItemCloudGameBinding
	) : RecyclerView.ViewHolder(binding.root)
	{
		fun bind(game: CloudGame)
		{
			binding.gameNameTextView.text = game.name
			// Show only generation number (4 or 5) instead of full platform name
			binding.gamePlatformTextView.text = when (game.platform.lowercase()) {
				"ps4" -> "4"
				"ps5" -> "5"
				else -> game.platform.takeLast(1) // Fallback to last character
			}

			// Show ownership badge only in Game Library section
			if (showOwnershipBadge && game.serviceType == "pscloud") {
				binding.ownershipBadge.visibility = android.view.View.VISIBLE
				if (game.isOwned) {
					binding.ownershipBadge.text = "Owned"
					binding.ownershipBadge.setBackgroundColor(0xCC4CAF50.toInt()) // Green
				} else {
					binding.ownershipBadge.text = "Not Owned"
					binding.ownershipBadge.setBackgroundColor(0xCCFF9800.toInt()) // Orange
				}
			} else {
				binding.ownershipBadge.visibility = android.view.View.GONE
			}

			// Set favorite icon state
			val isFav = isFavorite(game.productId)
			binding.favoriteButton.setImageResource(
				if (isFav) R.drawable.ic_star_filled else R.drawable.ic_star_outline
			)

		// Load game image using Coil with error logging
		if (game.imageUrl.isEmpty())
		{
			Log.w(TAG, "Empty imageUrl for game: ${game.name}")
			binding.gameImageView.setImageResource(android.R.drawable.ic_menu_gallery)
			binding.loadingSpinner?.visibility = android.view.View.GONE
		}
		else
		{
			binding.loadingSpinner?.visibility = android.view.View.VISIBLE
			binding.gameImageView.load(game.imageUrl) {
				crossfade(true)
				listener(
					onStart = {
						binding.loadingSpinner?.visibility = android.view.View.VISIBLE
					},
					onError = { request, result ->
						binding.loadingSpinner?.visibility = android.view.View.GONE
						Log.e(TAG, "Failed to load image for '${game.name}': ${result.throwable.message}")
						Log.e(TAG, "  URL: ${game.imageUrl}")
					},
					onSuccess = { request, result ->
						binding.loadingSpinner?.visibility = android.view.View.GONE
						Log.v(TAG, "Successfully loaded image for: ${game.name}")
					}
				)
			}
		}

			// No focus handling needed - game name is always visible

			binding.root.setOnClickListener {
				onGameClick(game)
			}

			// Handle favorite button click
			binding.favoriteButton.setOnClickListener {
				val newFavoriteState = !isFavorite(game.productId)
				onFavoriteClick(game, newFavoriteState)
				// Update icon immediately
				binding.favoriteButton.setImageResource(
					if (newFavoriteState) R.drawable.ic_star_filled else R.drawable.ic_star_outline
				)
			}
		}
	}
}

