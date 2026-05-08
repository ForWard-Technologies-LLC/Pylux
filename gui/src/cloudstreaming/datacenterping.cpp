// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudstreaming/datacenterping.h"
#include "settings.h"
#include "chiaki/senkusha.h"
#include "chiaki/session.h"
#include "chiaki/log.h"
#include "chiaki/time.h"
#include "chiaki/common.h"

#include <QHostAddress>
#include <QHostInfo>
#include <QThread>
#include <QDebug>
#include <QSharedPointer>
#include <QCoreApplication>
#include <QTimer>
#include <QObject>

#include <string.h>
#include <stdlib.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#ifndef gai_strerror
#define gai_strerror gai_strerrorA
#endif
#else
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#endif

// Helper to set port in sockaddr
static ChiakiErrorCode set_port(struct sockaddr *sa, uint16_t port)
{
	if(sa->sa_family == AF_INET)
		((struct sockaddr_in *)sa)->sin_port = port;
	else if(sa->sa_family == AF_INET6)
		((struct sockaddr_in6 *)sa)->sin6_port = port;
	else
		return CHIAKI_ERR_INVALID_DATA;
	return CHIAKI_ERR_SUCCESS;
}

PingResult DatacenterPing::performPingHandshake(const QString &publicIp, int port, const QString &sessionKey,
                                                 const QString &serviceType, Settings *settings)
{
    Q_UNUSED(settings);

    // Create a minimal logger
    ChiakiLog log;
    chiaki_log_init(&log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, chiaki_log_cb_print, nullptr);

    // Resolve hostname to IP
    QHostAddress addr;
    if(!addr.setAddress(publicIp)) {
        struct addrinfo hints_resolve;
        memset(&hints_resolve, 0, sizeof(hints_resolve));
        hints_resolve.ai_family = AF_INET;
        hints_resolve.ai_socktype = SOCK_DGRAM;

        struct addrinfo *result_resolve = nullptr;
        int err_resolve = getaddrinfo(publicIp.toUtf8().constData(), nullptr, &hints_resolve, &result_resolve);
        if(err_resolve != 0 || !result_resolve) {
            qWarning() << "Failed to resolve hostname:" << publicIp << "error:" << gai_strerror(err_resolve);
            PingResult failResult;
            failResult.rtt_us = -1;
            failResult.mtu_in = 0;
            failResult.mtu_out = 0;
            return failResult;
        }

        if(result_resolve->ai_family == AF_INET) {
            struct sockaddr_in *sin = (struct sockaddr_in *)result_resolve->ai_addr;
            char ip_str[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &sin->sin_addr, ip_str, INET_ADDRSTRLEN);
            addr.setAddress(QString::fromUtf8(ip_str));
        } else {
            qWarning() << "No IPv4 address found for:" << publicIp;
            freeaddrinfo(result_resolve);
            PingResult failResult;
            failResult.rtt_us = -1;
            failResult.mtu_in = 0;
            failResult.mtu_out = 0;
            return failResult;
        }
        freeaddrinfo(result_resolve);
    }

    // Create addrinfo structure for the datacenter
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_protocol = IPPROTO_UDP;

    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);

    struct addrinfo *addrinfo_result = nullptr;
    int err = getaddrinfo(addr.toString().toUtf8().constData(), portStr, &hints, &addrinfo_result);
    if(err != 0 || !addrinfo_result) {
        qWarning() << "Failed to create addrinfo for" << publicIp << ":" << port;
        PingResult failResult;
        failResult.rtt_us = -1;
        failResult.mtu_in = 0;
        failResult.mtu_out = 0;
        return failResult;
    }

    // Allocate a buffer large enough for ChiakiSession and zero it
    size_t session_size = sizeof(ChiakiSession);
    char *session_buffer = (char *)calloc(1, session_size);
    if(!session_buffer) {
        qWarning() << "Failed to allocate session buffer";
        freeaddrinfo(addrinfo_result);
        PingResult failResult;
        failResult.rtt_us = -1;
        failResult.mtu_in = 0;
        failResult.mtu_out = 0;
        return failResult;
    }

    ChiakiSession *session = (ChiakiSession *)session_buffer;
    session->log = &log;
    session->connect_info.host_addrinfo_selected = addrinfo_result;
    session->connect_info.enable_dualsense = false;
    session->target = CHIAKI_TARGET_PS5_1;
    
    // Set service type for cloud ping
    session->cloud_port = port;
    if(serviceType == "pscloud") {
        session->cloud_psn_wrapper_type = 0; // No PSN wrapper for PSCloud
        session->service_type = CHIAKI_SERVICE_TYPE_PSCLOUD;
    } else if(serviceType == "psnow") {
        session->cloud_psn_wrapper_type = 0x01; // PSN wrapper for PSNOW
        session->service_type = CHIAKI_SERVICE_TYPE_PSNOW;
    } else {
        // Fallback to PSNOW behavior for compatibility
        session->cloud_psn_wrapper_type = 0x01;
        session->service_type = CHIAKI_SERVICE_TYPE_PSNOW;
    }

    // Initialize senkusha
    ChiakiSenkusha senkusha;
    ChiakiErrorCode chiakiErr = chiaki_senkusha_init(&senkusha, session);
    if(chiakiErr != CHIAKI_ERR_SUCCESS) {
        qWarning() << "Failed to initialize senkusha:" << chiakiErr;
        freeaddrinfo(addrinfo_result);
        free(session_buffer);
        PingResult failResult;
        failResult.rtt_us = -1;
        failResult.mtu_in = 0;
        failResult.mtu_out = 0;
        return failResult;
    }

    // Force protocol version to 9 for cloud ping (unified handling)
    senkusha.protocol_version = 9;
    
    // Set session key (x-gaikai-session) for cloud mode BIG message
    QByteArray sessionKeyBytes = sessionKey.toUtf8();
    senkusha.cloud_launch_spec = (char *)malloc(sessionKeyBytes.size() + 1);
    if(!senkusha.cloud_launch_spec) {
        qWarning() << "Failed to allocate session key string";
        chiaki_senkusha_fini(&senkusha);
        freeaddrinfo(addrinfo_result);
        free(session_buffer);
        PingResult failResult;
        failResult.rtt_us = -1;
        failResult.mtu_in = 0;
        failResult.mtu_out = 0;
        return failResult;
    }
    memcpy(senkusha.cloud_launch_spec, sessionKeyBytes.constData(), sessionKeyBytes.size());
    senkusha.cloud_launch_spec[sessionKeyBytes.size()] = '\0';

    // Run senkusha (this will do the full handshake + echo/ping test)
    uint32_t mtu_in = 0;
    uint32_t mtu_out = 0;
    uint64_t rtt_us = 0;
    
    chiakiErr = chiaki_senkusha_run(&senkusha, &mtu_in, &mtu_out, &rtt_us, nullptr);
    
    // Free the session key string we allocated
    if(senkusha.cloud_launch_spec) {
        free(senkusha.cloud_launch_spec);
        senkusha.cloud_launch_spec = NULL;
    }
    
    chiaki_senkusha_fini(&senkusha);
    freeaddrinfo(addrinfo_result);
    free(session_buffer);

    PingResult pingResult;
    
    if(chiakiErr != CHIAKI_ERR_SUCCESS) {
        pingResult.rtt_us = -1;
        pingResult.mtu_in = 0;
        pingResult.mtu_out = 0;
        return pingResult;
    }
    
    pingResult.rtt_us = rtt_us > 0 ? (int64_t)rtt_us : -1;
    pingResult.mtu_in = mtu_in;
    pingResult.mtu_out = mtu_out;
    return pingResult;
}

void DatacenterPing::pingAllDatacentersWithTimeout(const QJsonArray &datacenters, const QString &sessionKey,
                                                    const QString &serviceType, Settings *settings,
                                                    std::function<void(QJsonArray pingResults)> callback)
{
    if(datacenters.isEmpty()) {
        callback(QJsonArray());
        return;
    }

    // Shared state for ping results
    struct PingState {
        QJsonArray results;
        QJsonArray allDatacenters;
        int completed = 0;
        int total;
        bool timeoutFired = false;
        bool callbackInvoked = false;
        QTimer *timer = nullptr;
        std::function<void(QJsonArray)> callback;
    };

    QSharedPointer<PingState> state(new PingState);
    state->total = datacenters.size();
    state->allDatacenters = datacenters;
    state->callback = callback;

    // Create timeout timer - 15 seconds
    state->timer = new QTimer();
    state->timer->setSingleShot(true);
    state->timer->setInterval(15000);

    QObject::connect(state->timer, &QTimer::timeout, [state]() {
        state->timeoutFired = true;

        if(state->callbackInvoked) {
            state->timer->deleteLater();
            return;
        }

        state->callbackInvoked = true;

        // Filter to only include successfully completed pings (RTT > 0 and < 999)
        QJsonArray successfulResults;
        for(const QJsonValue &val : state->results) {
            QJsonObject result = val.toObject();
            int rtt = result["rtt"].toInt();
            // Only include successful pings (valid RTT, not dummy 999)
            if(rtt > 0 && rtt < 999) {
                successfulResults.append(result);
            }
        }

        qWarning() << "DatacenterPing: Timeout -" << state->completed << "of" << state->total << "pings completed, returning" << successfulResults.size() << "successful results";

        // Return only successfully completed pings - caller will pick the best one
        state->callback(successfulResults);
        state->timer->deleteLater();
    });

    // Start the timeout timer
    state->timer->start();

    // Launch ping threads for each datacenter
    for(const QJsonValue &dcValue : datacenters) {
        QJsonObject dc = dcValue.toObject();
        QString publicIp = dc["publicIp"].toString();
        int port = dc["port"].toInt();
        QString dataCenter = dc["dataCenter"].toString();
        int maxBandwidth = dc["maxBandwidth"].toInt();

        // Create a background thread for this ping
        QThread *thread = new QThread();
        QObject *worker = new QObject();
        worker->moveToThread(thread);

        QObject::connect(thread, &QThread::started, [=, sessionKey=sessionKey, serviceType=serviceType]() {
            PingResult pingResult = performPingHandshake(publicIp, port, sessionKey, serviceType, settings);
            int rtt_ms = pingResult.rtt_us > 0 ? (int)(pingResult.rtt_us / 1000) : -1;

            // Build result
            QJsonObject result;
            result["dataCenter"] = dataCenter;
            result["port"] = port;
            result["publicIp"] = publicIp;
            result["maxBandwidth"] = maxBandwidth;

            if(rtt_ms > 0) {
                result["rtt"] = rtt_ms;
                result["rtts"] = QJsonArray::fromVariantList({rtt_ms});
                result["mtu_in"] = (int)pingResult.mtu_in;
                result["mtu_out"] = (int)pingResult.mtu_out;
            } else {
                result["rtt"] = 999;
                result["rtts"] = QJsonArray::fromVariantList({999});
                result["mtu_in"] = 0;
                result["mtu_out"] = 0;
            }

            // Post result to main thread
            QMetaObject::invokeMethod(qApp, [state, result, dataCenter]() {
                if(state->timeoutFired || state->callbackInvoked) {
                    return;
                }

                state->results.append(result);
                state->completed++;

                // Check if all pings completed
                if(state->completed >= state->total) {
                    if(state->callbackInvoked) {
                        return;
                    }

                    state->callbackInvoked = true;
                    state->timer->stop();
                    state->callback(state->results);
                    state->timer->deleteLater();
                }
            }, Qt::QueuedConnection);

            worker->deleteLater();
            thread->quit();
        });

        QObject::connect(thread, &QThread::finished, thread, &QThread::deleteLater);
        thread->start();
    }
}
