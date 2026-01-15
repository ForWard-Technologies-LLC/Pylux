// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.util.Log
import android.view.LayoutInflater
import android.view.ViewGroup
import androidx.recyclerview.widget.RecyclerView
import coil.load
import coil.request.ErrorResult
import coil.request.SuccessResult
import com.metallic.chiaki.R
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.databinding.ItemCloudGameBinding

class CloudGameAdapter(
	private val onGameClick: (CloudGame) -> Unit
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
			binding.gamePlatformTextView.text = game.platform.uppercase()

			// Load game image using Coil with error logging
			if (game.imageUrl.isEmpty())
			{
				Log.w(TAG, "Empty imageUrl for game: ${game.name}")
				binding.gameImageView.setImageResource(R.drawable.ic_console_simple)
			}
			else
			{
				binding.gameImageView.load(game.imageUrl) {
					crossfade(true)
					placeholder(R.drawable.ic_console_simple)
					error(R.drawable.ic_console_simple)
					listener(
						onError = { request, result ->
							Log.e(TAG, "Failed to load image for '${game.name}': ${result.throwable.message}")
							Log.e(TAG, "  URL: ${game.imageUrl}")
						},
						onSuccess = { request, result ->
							Log.v(TAG, "Successfully loaded image for: ${game.name}")
						}
					)
				}
			}

			binding.root.setOnClickListener {
				onGameClick(game)
			}
		}
	}
}

