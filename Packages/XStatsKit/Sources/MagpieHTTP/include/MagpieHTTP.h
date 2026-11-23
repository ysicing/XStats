// SPDX-License-Identifier: AGPL-3.0-or-later

#pragma once
#include <stdbool.h>
#include <stddef.h>

bool MagpieHTTPGet(const char *url, const char *authorizationHeader, long *status,
                   bool (^receive)(const unsigned char *, size_t), bool (^cancelled)(void));
