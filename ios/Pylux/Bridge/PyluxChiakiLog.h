// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#pragma once

#include <chiaki/log.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Wraps chiaki_log_init: Debug → CHIAKI_LOG_ALL; Release → CHIAKI_LOG_MASK_QUIET. */
void pylux_chiaki_log_init(ChiakiLog *log, ChiakiLogCb cb, void *user);

#ifdef __cplusplus
}
#endif
