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
import com.pylux.stream.databinding.ItemCloudGameBinding

class CloudGameAdapter(
	private val onGameClick: (CloudGame) -> Unit,
	private val onFavoriteClick: (CloudGame, Boolean) -> Unit,
	private val isFavorite: (String) -> Boolean
) : RecyclerView.Adapter<CloudGameAdapter.CloudGameViewHolder>()
{
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
		return CloudGameViewHolder(binding)
	}

	override fun onBindViewHolder(holder: CloudGameViewHolder, position: Int)
	{
		holder.bind(games[position])
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

		fun bind(game: CloudGame)
		{
			binding.gameNameTextView.text = game.name
			binding.gamePlatformTextView.text = when (game.platform.lowercase()) {
				"ps4" -> "4"
				"ps5" -> "5"
				else -> game.platform.takeLast(1)
			}

			if (showOwnershipBadge && game.serviceType == "pscloud") {
				binding.ownershipBadge.visibility = android.view.View.VISIBLE
				if (game.isOwned) {
					binding.ownershipBadge.text = "Owned"
					binding.ownershipBadge.setBackgroundColor(0xCC4CAF50.toInt())
				} else {
					binding.ownershipBadge.text = "Not Owned"
					binding.ownershipBadge.setBackgroundColor(0xCCFF9800.toInt())
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
			else if (isScrollingFast)
			{
				binding.gameImageView.load(game.imageUrl) {
					memoryCachePolicy(CachePolicy.ENABLED)
					diskCachePolicy(CachePolicy.DISABLED)
					networkCachePolicy(CachePolicy.DISABLED)
				}
			}
			else
			{
				binding.gameImageView.load(game.imageUrl) {
					crossfade(true)
				}
			}

			binding.root.setOnClickListener {
				onGameClick(game)
			}

			binding.favoriteButton.setOnClickListener {
				val newFavoriteState = !isFavorite(game.productId)
				onFavoriteClick(game, newFavoriteState)
				binding.favoriteButton.setImageResource(
					if (newFavoriteState) R.drawable.ic_star_filled else R.drawable.ic_star_outline
				)
			}
		}
	}
}

