# syntax=docker/dockerfile:1.7
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

FROM --platform=$BUILDPLATFORM golang:1-alpine AS build

ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
COPY server/api/go.mod server/api/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download

COPY server/api/ ./
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w" -o /out/xstats-api . \
    && mkdir -p /out/data

FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /data
COPY --from=build --chown=65532:65532 /out/data /data
COPY --from=build /out/xstats-api /usr/local/bin/xstats-api
COPY LICENSE LICENSING.md ThirdPartyNotices.md /licenses/
COPY LICENSES/XStats-API-Dependencies.txt /licenses/LICENSES/

ENV XSTATS_LISTEN=:8080 \
    XSTATS_DATABASE=/data/xstats-api.sqlite

EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/xstats-api"]
