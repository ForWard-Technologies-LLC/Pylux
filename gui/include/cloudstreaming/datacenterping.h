// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef DATACENTERPING_H
#define DATACENTERPING_H

#include <QString>
#include <QJsonObject>
#include <QJsonArray>
#include <functional>

// Forward declaration
class Settings;

/**
 * Ping result structure containing RTT and MTU measurements
 */
struct PingResult {
    int64_t rtt_us;      // RTT in microseconds, or -1 on failure
    uint32_t mtu_in;     // Inbound MTU (server to client)
    uint32_t mtu_out;    // Outbound MTU (client to server)
    
    PingResult() : rtt_us(-1), mtu_in(0), mtu_out(0) {}
};

/**
 * DatacenterPing - Uses existing senkusha echo/ping functionality for RTT measurement
 *
 * This class reuses the existing chiaki_senkusha_run flow which performs:
 * 1. Takion connect
 * 2. Protocol version exchange (always v9 for cloud ping)
 * 3. BIG/BANG handshake
 * 4. Echo command enable
 * 5. Multiple ping/pong measurements (10 by default)
 * 6. Average RTT calculation
 */
class DatacenterPing {
public:
    /**
     * Ping multiple datacenters using senkusha echo/ping functionality
     *
     * @param datacenters QJsonArray of datacenter objects with "publicIp", "port", "dataCenter", "maxBandwidth"
     * @param sessionKey The session key from x-gaikai-session header (used for BIG message)
     * @param serviceType Service type: "pscloud" or "psnow" (used to determine if PSN wrapper should be added)
     * @param settings Settings object needed for session
     * @param callback Called with QJsonArray of ping results
     *                 Each result has: "dataCenter", "rtt", "rtts", "mtu_in", "mtu_out", "port", "publicIp", "maxBandwidth"
     */
    static void pingAllDatacentersWithTimeout(const QJsonArray &datacenters, const QString &sessionKey,
                                              const QString &serviceType, Settings *settings,
                                              std::function<void(QJsonArray pingResults)> callback);

private:
    /**
     * Ping a single datacenter using senkusha_run
     *
     * @param publicIp The datacenter's public IP address
     * @param port The datacenter's port (typically 40101)
     * @param sessionKey The session key (x-gaikai-session) to use in BIG message launch_spec
     * @param serviceType Service type: "pscloud" or "psnow" (used to determine if PSN wrapper should be added)
     * @param settings Settings object needed for session
     * @return PingResult containing RTT and MTU values, or rtt_us=-1 on failure/timeout
     */
    static PingResult performPingHandshake(const QString &publicIp, int port, const QString &sessionKey,
                                           const QString &serviceType, Settings *settings);
};

#endif // DATACENTERPING_H
