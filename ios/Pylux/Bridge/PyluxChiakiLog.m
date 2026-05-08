// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#import "PyluxChiakiLog.h"

void pylux_chiaki_log_init(ChiakiLog *log, ChiakiLogCb cb, void *user)
{
#if DEBUG
    chiaki_log_init(log, CHIAKI_LOG_ALL, cb, user);
#else
    /* No INFO/WARNING → no Chiaki lines at syslog Notice from log_cb (only CHIAKI_LOGE). */
    chiaki_log_init(log, CHIAKI_LOG_MASK_ERRORS_ONLY, cb, user);
#endif
}
