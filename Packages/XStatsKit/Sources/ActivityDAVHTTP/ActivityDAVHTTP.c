// SPDX-License-Identifier: AGPL-3.0-or-later

#include "ActivityDAVHTTP.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>

typedef bool (^ActivityDAVReceive)(const unsigned char *, size_t);
typedef bool (^ActivityDAVCancelled)(void);

struct ActivityDAVResponse {
    CURL *handle;
    long bodyStatus;
    ActivityDAVReceive receive;
    bool ignoredBody;
};

struct ActivityDAVTunnel {
    const char *name;
    const char *localAddress;
};

static size_t receiveDAVBody(char *bytes, size_t size, size_t count, void *context) {
    struct ActivityDAVResponse *response = context;
    long status = 0;
    curl_easy_getinfo(response->handle, CURLINFO_RESPONSE_CODE, &status);
    if (status != response->bodyStatus || response->bodyStatus == 0) {
        response->ignoredBody = true;
        return 0;
    }
    size_t length = size * count;
    return response->receive((const unsigned char *)bytes, length) ? length : 0;
}

static int cancelDAVRequest(void *context, curl_off_t total, curl_off_t downloaded,
                            curl_off_t uploadTotal, curl_off_t uploaded) {
    return (*(ActivityDAVCancelled *)context)();
}

static int bindDAVTunnel(void *context, curl_socket_t socket, curlsocktype purpose) {
    struct ActivityDAVTunnel *tunnel = context;
    if (purpose != CURLSOCKTYPE_IPCXN || strncmp(tunnel->name, "utun", 4) != 0) {
        return CURL_SOCKOPT_ERROR;
    }
    unsigned int index = if_nametoindex(tunnel->name);
    if (index == 0) return CURL_SOCKOPT_ERROR;
    struct sockaddr_in local4 = {.sin_len = sizeof(local4), .sin_family = AF_INET};
    struct sockaddr_in6 local6 = {.sin6_len = sizeof(local6), .sin6_family = AF_INET6};
    // 同时约束套接字路由与 Tailscale 确认的本地源地址。
    if (inet_pton(AF_INET, tunnel->localAddress, &local4.sin_addr) == 1
        && setsockopt(socket, IPPROTO_IP, IP_BOUND_IF, &index, sizeof(index)) == 0
        && bind(socket, (const struct sockaddr *)&local4, sizeof(local4)) == 0) {
        return CURL_SOCKOPT_OK;
    }
    if (inet_pton(AF_INET6, tunnel->localAddress, &local6.sin6_addr) == 1
        && setsockopt(socket, IPPROTO_IPV6, IPV6_BOUND_IF, &index, sizeof(index)) == 0
        && bind(socket, (const struct sockaddr *)&local6, sizeof(local6)) == 0) {
        return CURL_SOCKOPT_OK;
    }
    return CURL_SOCKOPT_ERROR;
}

static bool addDAVHeader(struct curl_slist **headers, const char *line) {
    struct curl_slist *updated = curl_slist_append(*headers, line);
    if (!updated) return false;
    *headers = updated;
    return true;
}

bool ActivityDAVHTTPPerform(const char *numericURL, const char *method, const char *hostHeader,
                            const char *authorizationHeader, const unsigned char *body,
                            size_t bodyLength, const char *tunnel, const char *localAddress,
                            long *status, bool *connectionFailed,
                            ActivityDAVReceive receive, ActivityDAVCancelled cancelled) {
    *status = 0;
    *connectionFailed = false;
    if (cancelled()) return false;
    CURL *handle = curl_easy_init();
    if (!handle) return false;
    struct curl_slist *headers = NULL;
    bool propfind = strcmp(method, "PROPFIND") == 0;
    bool get = strcmp(method, "GET") == 0;
    bool put = strcmp(method, "PUT") == 0;
    struct ActivityDAVResponse response = {handle, get ? 200 : propfind ? 207 : 0, receive, false};
    struct ActivityDAVTunnel binding = {tunnel, localAddress};
    bool configured = (get || propfind || put || strcmp(method, "MKCOL") == 0)
        && addDAVHeader(&headers, hostHeader)
        && addDAVHeader(&headers, authorizationHeader)
        && addDAVHeader(&headers, "Expect:")
        && (!propfind || (addDAVHeader(&headers, "Depth: 1")
                         && addDAVHeader(&headers, "Content-Type: application/xml; charset=utf-8")))
        && (!put || (addDAVHeader(&headers, "If-None-Match: *")
                    && addDAVHeader(&headers, "Content-Type: application/json")))
        && curl_easy_setopt(handle, CURLOPT_URL, numericURL) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_PROTOCOLS_STR, "http") == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_PROXY, "") == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_NOPROXY, "*") == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_NETRC, (long)CURL_NETRC_IGNORED) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_CUSTOMREQUEST, method) == CURLE_OK
        && (!(propfind || put)
            || (curl_easy_setopt(handle, CURLOPT_POSTFIELDS, bodyLength ? (const char *)body : "") == CURLE_OK
                && curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)bodyLength) == CURLE_OK))
        && (!tunnel[0] || (localAddress[0]
                           && curl_easy_setopt(handle, CURLOPT_SOCKOPTFUNCTION, bindDAVTunnel) == CURLE_OK
                           && curl_easy_setopt(handle, CURLOPT_SOCKOPTDATA, &binding) == CURLE_OK))
        && curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT, 6L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_TIMEOUT, 45L) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, receiveDAVBody) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, cancelDAVRequest) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_XFERINFODATA, &cancelled) == CURLE_OK
        && curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L) == CURLE_OK;
    CURLcode result = configured ? curl_easy_perform(handle) : CURLE_FAILED_INIT;
    curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, status);
    *connectionFailed = result == CURLE_COULDNT_CONNECT;
    curl_easy_cleanup(handle);
    curl_slist_free_all(headers);
    return result == CURLE_OK || (result == CURLE_WRITE_ERROR && response.ignoredBody);
}
