// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once
#include <stdbool.h>
#include <stddef.h>

bool ActivityDAVHTTPPerform(const char *numericURL, const char *method, const char *hostHeader,
                            const char *authorizationHeader, const unsigned char *body,
                            size_t bodyLength, const char *tunnel, const char *localAddress,
                            long *status, bool *connectionFailed,
                            bool (^receive)(const unsigned char *, size_t), bool (^cancelled)(void));
