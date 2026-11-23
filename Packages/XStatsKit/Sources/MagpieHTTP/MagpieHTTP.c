// SPDX-License-Identifier: AGPL-3.0-or-later

#include "MagpieHTTP.h"
#include <curl/curl.h>

typedef bool (^Receive)(const unsigned char *, size_t);
typedef bool (^Cancelled)(void);

static size_t receiveBody(char *bytes, size_t size, size_t count, void *context) {
    size_t length = size * count;
    return (*(Receive *)context)((const unsigned char *)bytes, length) ? length : 0;
}

static int checkCancellation(void *context, curl_off_t total, curl_off_t downloaded,
                             curl_off_t uploadTotal, curl_off_t uploaded) {
    return (*(Cancelled *)context)();
}

bool MagpieHTTPGet(const char *url, const char *authorizationHeader, long *status,
                   Receive receive, Cancelled cancelled) {
    CURL *handle = curl_easy_init();
    if (!handle) return false;
    struct curl_slist *headers = curl_slist_append(NULL, "Accept: application/json");
    struct curl_slist *authenticated = headers ? curl_slist_append(headers, authorizationHeader) : NULL;
    bool ok = authenticated
        && curl_easy_setopt(handle, CURLOPT_URL, url) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_PROTOCOLS_STR, "http") == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_HTTPHEADER, authenticated) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, 15L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_TIMEOUT, 20L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, receiveBody) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_WRITEDATA, &receive) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, checkCancellation) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_XFERINFODATA, &cancelled) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L) == CURLE_OK
        && curl_easy_perform(handle) == CURLE_OK;
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, status);
    curl_easy_cleanup(handle);
    curl_slist_free_all(headers);
    return ok;
}
