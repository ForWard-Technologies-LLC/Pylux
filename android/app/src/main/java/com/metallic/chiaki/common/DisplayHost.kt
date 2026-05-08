// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import com.metallic.chiaki.lib.DiscoveryHost

sealed class DisplayHost
{
	abstract val registeredHost: RegisteredHost?
	abstract val host: String
	abstract val name: String?
	abstract val id: String?
	abstract val isPS5: Boolean

	val isRegistered get() = registeredHost != null
}

class DiscoveredDisplayHost(
	override val registeredHost: RegisteredHost?,
	val discoveredHost: DiscoveryHost,
	/** PSN DUID if this host was also found via PSN (enables automatic registration) */
	val psnDuid: String? = null
): DisplayHost()
{
	override val host get() = discoveredHost.hostAddr ?: ""
	override val name get() = discoveredHost.hostName ?: registeredHost?.serverNickname
	override val id get() = discoveredHost.hostId ?: registeredHost?.serverMac?.toString()
	override val isPS5 get() = discoveredHost.isPS5

	override fun equals(other: Any?): Boolean =
		if(other !is DiscoveredDisplayHost)
			false
		else
			other.discoveredHost == discoveredHost && other.registeredHost == registeredHost && other.psnDuid == psnDuid

	override fun hashCode(): Int
	{
		var result = 31 * (registeredHost?.hashCode() ?: 0) + discoveredHost.hashCode()
		result = 31 * result + (psnDuid?.hashCode() ?: 0)
		return result
	}

	override fun toString() = "DiscoveredDisplayHost{${registeredHost}, ${discoveredHost}, psnDuid=${psnDuid?.take(16)}}"
}

class ManualDisplayHost(
	override val registeredHost: RegisteredHost?,
	val manualHost: ManualHost
): DisplayHost()
{
	override val host get() = manualHost.host
	override val name get() = registeredHost?.serverNickname
	override val id get() = registeredHost?.serverMac?.toString()
	override val isPS5: Boolean get() = registeredHost?.target?.isPS5 ?: false

	override fun equals(other: Any?): Boolean =
		if(other !is ManualDisplayHost)
			false
		else
			other.manualHost == manualHost && other.registeredHost == registeredHost

	override fun hashCode() = 31 * (registeredHost?.hashCode() ?: 0) + manualHost.hashCode()

	override fun toString() = "ManualDisplayHost{${registeredHost}, ${manualHost}}"
}

/**
 * A console discovered via PSN (holepunch) rather than local network.
 * These have no direct IP address - connections go through the PSN holepunch mechanism.
 */
class PsnDisplayHost(
	override val registeredHost: RegisteredHost?,
	val psnHost: PsnHost
): DisplayHost()
{
	override val host get() = "" // No direct IP for PSN hosts
	override val name get() = psnHost.name
	override val id get() = psnHost.duid
	override val isPS5 get() = psnHost.isPS5
	val duid get() = psnHost.duid

	override fun equals(other: Any?): Boolean =
		if(other !is PsnDisplayHost)
			false
		else
			other.psnHost == psnHost && other.registeredHost == registeredHost

	override fun hashCode() = 31 * (registeredHost?.hashCode() ?: 0) + psnHost.hashCode()

	override fun toString() = "PsnDisplayHost{${registeredHost}, ${psnHost}}"
}