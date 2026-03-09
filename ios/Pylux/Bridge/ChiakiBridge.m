// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Bridge to Chiaki C library

#import "ChiakiBridge.h"
#include <chiaki/common.h>

const char *chiaki_get_test_string(void)
{
    return chiaki_error_string(CHIAKI_ERR_SUCCESS);
}
