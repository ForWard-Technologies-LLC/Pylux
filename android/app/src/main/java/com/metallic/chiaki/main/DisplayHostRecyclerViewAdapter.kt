// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.animation.AnimationUtils
import android.widget.PopupMenu
import androidx.core.view.isGone
import androidx.core.view.isVisible
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import com.pylux.stream.R
import com.metallic.chiaki.common.DiscoveredDisplayHost
import com.metallic.chiaki.common.DisplayHost
import com.metallic.chiaki.common.ManualDisplayHost
import com.metallic.chiaki.common.PsnDisplayHost
import com.metallic.chiaki.common.ext.inflate
import com.pylux.stream.databinding.ItemDisplayHostBinding
import com.metallic.chiaki.lib.DiscoveryHost

class DisplayHostDiffCallback(val old: List<DisplayHost>, val new: List<DisplayHost>): DiffUtil.Callback()
{
	override fun areItemsTheSame(oldItemPosition: Int, newItemPosition: Int) = (old[oldItemPosition] == new[newItemPosition])
	override fun areContentsTheSame(oldItemPosition: Int, newItemPosition: Int) = (old[oldItemPosition] == new[newItemPosition])
	override fun getOldListSize() = old.size
	override fun getNewListSize() = new.size
}

class DisplayHostRecyclerViewAdapter(
	val clickCallback: (DisplayHost) -> Unit,
	val wakeupCallback: (DisplayHost) -> Unit,
	val editCallback: (DisplayHost) -> Unit,
	val deleteCallback: (DisplayHost) -> Unit
): RecyclerView.Adapter<DisplayHostRecyclerViewAdapter.ViewHolder>()
{
	var hosts: List<DisplayHost> = listOf()
		set(value)
		{
			val diff = DiffUtil.calculateDiff(DisplayHostDiffCallback(field, value))
			field = value
			diff.dispatchUpdatesTo(this)
		}

	class ViewHolder(val binding: ItemDisplayHostBinding): RecyclerView.ViewHolder(binding.root)

	override fun onCreateViewHolder(parent: ViewGroup, viewType: Int)
		= ViewHolder(ItemDisplayHostBinding.inflate(LayoutInflater.from(parent.context), parent, false))

	override fun getItemCount() = hosts.count()

	override fun onBindViewHolder(holder: ViewHolder, position: Int)
	{
		val context = holder.itemView.context
		val host = hosts[position]
		holder.binding.also {
			// Set both visible header name and hidden binding name
			it.nameTextView.text = host.name
			it.headerNameTextView.text = host.name
			
			// Platform badge (4 or 5)
			it.platformBadge.text = if(host.isPS5) "5" else "4"
			it.platformTextView.text = if(host.isPS5) "PS5" else "PS4"
			
			// For PSN hosts: just show "Remote Console" and ready icon
			if(host is PsnDisplayHost)
			{
				it.hostTextView.text = "Remote Console"
				it.hostTextView.setTextColor(android.graphics.Color.parseColor("#FFFFFF"))
				it.hostTextView.textSize = 16f
				it.idTextView.visibility = View.GONE
				it.statusLayout.visibility = View.VISIBLE
				it.statusTextView.text = "Ready"
				it.statusIcon.setColorFilter(context.getColor(R.color.psn_blue))
			}
			else
			{
				// For local/manual hosts: show address and MAC on left, state on right
				it.hostTextView.text = context.getString(R.string.display_host_host, host.host)
				it.hostTextView.setTextColor(android.graphics.Color.parseColor("#FFFFFF"))
				it.hostTextView.textSize = 15f
				
				// Device ID (MAC address)
				val id = host.id
				if(id != null)
				{
					// Format MAC address nicely (add colons if needed)
					val formatted = if(id.length == 12 && !id.contains(":"))
						id.chunked(2).joinToString(":")
					else
						id
					it.idTextView.text = "MAC: $formatted"
					it.idTextView.visibility = View.VISIBLE
				}
				else
				{
					it.idTextView.visibility = View.GONE
				}
				
				// State/Status with colored dot on the right
				val stateText = when
				{
					host is DiscoveredDisplayHost && host.discoveredHost.state == DiscoveryHost.State.READY -> "Ready"
					host is DiscoveredDisplayHost && host.discoveredHost.state == DiscoveryHost.State.STANDBY -> "Standby"
					else -> null
				}
				
				if(stateText != null)
				{
					it.statusTextView.text = stateText
					it.statusLayout.visibility = View.VISIBLE
					
					// Set status dot color
					val statusIconTint = when
					{
						host is DiscoveredDisplayHost && host.discoveredHost.state == DiscoveryHost.State.READY -> 
							android.graphics.Color.parseColor("#22C55E") // Green-500
						host is DiscoveredDisplayHost && host.discoveredHost.state == DiscoveryHost.State.STANDBY -> 
							android.graphics.Color.parseColor("#F97316") // Orange-500
						else -> 
							android.graphics.Color.parseColor("#9CA3AF") // Gray-400
					}
					it.statusIcon.setColorFilter(statusIconTint)
				}
				else
				{
					it.statusLayout.visibility = View.GONE
				}
			}
			// Bottom info (app/game running)
			val bottomInfo = (host as? DiscoveredDisplayHost)?.discoveredHost?.let { discoveredHost ->
				if(discoveredHost.runningAppName != null || discoveredHost.runningAppTitleid != null)
					context.getString(R.string.display_host_app_title_id, discoveredHost.runningAppName ?: "", discoveredHost.runningAppTitleid ?: "")
				else
					null
			}
			if(bottomInfo != null)
			{
				it.bottomInfoTextView.text = bottomInfo
				it.bottomInfoTextView.visibility = View.VISIBLE
			}
			else
			{
				it.bottomInfoTextView.visibility = View.GONE
			}
			
			it.stateIndicatorImageView.setImageResource(
				when
				{
					host is PsnDisplayHost -> if(host.isPS5) R.drawable.ic_console_ps5 else R.drawable.ic_console
					host is DiscoveredDisplayHost -> when(host.discoveredHost.state)
					{
						DiscoveryHost.State.STANDBY -> if(host.isPS5) R.drawable.ic_console_ps5_standby else R.drawable.ic_console_standby
						DiscoveryHost.State.READY -> if(host.isPS5) R.drawable.ic_console_ps5_ready else R.drawable.ic_console_ready
						else -> if(host.isPS5) R.drawable.ic_console_ps5 else R.drawable.ic_console
					}
					host.isPS5 -> R.drawable.ic_console_ps5
					else -> R.drawable.ic_console
				}
			)
			it.root.setOnClickListener { clickCallback(host) }

			val canWakeup = host.registeredHost != null
			val canEditDelete = host is ManualDisplayHost
			if(canWakeup || canEditDelete)
			{
				it.menuButton.isVisible = true
				it.menuButton.setOnClickListener { _ ->
					val menu = PopupMenu(context, it.menuButton)
					menu.menuInflater.inflate(R.menu.display_host, menu.menu)
					menu.menu.findItem(R.id.action_wakeup).isVisible = canWakeup
					menu.menu.findItem(R.id.action_edit).isVisible = canEditDelete
					menu.menu.findItem(R.id.action_delete).isVisible = canEditDelete
					menu.setOnMenuItemClickListener { menuItem ->
						when(menuItem.itemId)
						{
							R.id.action_wakeup -> wakeupCallback(host)
							R.id.action_edit -> editCallback(host)
							R.id.action_delete -> deleteCallback(host)
							else -> return@setOnMenuItemClickListener false
						}
						true
					}
					menu.show()
				}
			}
			else
			{
				it.menuButton.isGone = true
				it.menuButton.setOnClickListener(null)
			}
		}
	}
}