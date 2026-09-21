// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublishReleaseRejectsMissingToken(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPut, "/api/v1/releases/current", strings.NewReader(`{"version":"2026.09.21.01"}`))
	request.Header.Set("Content-Type", "application/json")
	response, err := app.Test(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusUnauthorized)
	}
}

func TestPublishReleaseRejectsIncompleteManifest(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPut, "/api/v1/releases/current", strings.NewReader(`{"version":"2026.09.21.03"}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer release-secret")
	response, err := app.Test(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusBadRequest)
	}
}

func TestPublishReleaseRejectsInsecureAssetURL(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}
	body := `{
		"version":"2026.09.21.03","build":"108","date":"2026-09-21","minimumSystem":"14.0",
		"url":"https://getopenstats.com/download/XStats.zip",
		"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"size":123456,"dmg":"http://example.test/XStats.dmg","notes":["新增安装统计"]
	}`
	request := httptest.NewRequest(http.MethodPut, "/api/v1/releases/current", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Authorization", "Bearer release-secret")
	response, err := app.Test(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusBadRequest)
	}
}

func TestPublishedReleaseIsReturnedByUpdateCheck(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}

	publishBody := `{
		"version":"2026.09.21.03",
		"build":"108",
		"date":"2026-09-21",
		"minimumSystem":"14.0",
		"url":"https://getopenstats.com/download/XStats-2026.09.21.03-AppleSilicon.zip",
		"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"size":123456,
		"dmg":"https://getopenstats.com/download/XStats-2026.09.21.03-AppleSilicon.dmg",
		"notes":["新增安装统计"],
		"changelog":"https://getopenstats.com/#changelog"
	}`
	publish := httptest.NewRequest(http.MethodPut, "/api/v1/releases/current", strings.NewReader(publishBody))
	publish.Header.Set("Content-Type", "application/json")
	publish.Header.Set("Authorization", "Bearer release-secret")
	publishResponse, err := app.Test(publish)
	if err != nil {
		t.Fatal(err)
	}
	if publishResponse.StatusCode != http.StatusNoContent {
		t.Fatalf("publish status = %d, want %d", publishResponse.StatusCode, http.StatusNoContent)
	}

	check := httptest.NewRequest(http.MethodPost, "/api/v1/update/check", strings.NewReader(`{
		"current_version":"2026.09.21.02",
		"installation_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	}`))
	check.Header.Set("Content-Type", "application/json")
	checkResponse, err := app.Test(check)
	if err != nil {
		t.Fatal(err)
	}
	if checkResponse.StatusCode != http.StatusOK {
		t.Fatalf("check status = %d, want %d", checkResponse.StatusCode, http.StatusOK)
	}
	var release struct {
		Version string   `json:"version"`
		Build   string   `json:"build"`
		SHA256  string   `json:"sha256"`
		Notes   []string `json:"notes"`
	}
	if err := json.NewDecoder(checkResponse.Body).Decode(&release); err != nil {
		t.Fatal(err)
	}
	if release.Version != "2026.09.21.03" || release.Build != "108" ||
		release.SHA256 != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ||
		len(release.Notes) != 1 || release.Notes[0] != "新增安装统计" {
		t.Fatalf("unexpected release: %#v", release)
	}
}

func TestUpdateCheckRejectsInvalidInstallationID(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}

	request := httptest.NewRequest(http.MethodPost, "/api/v1/update/check", strings.NewReader(`{
		"current_version":"2026.09.21.02",
		"installation_id":"hardware-serial"
	}`))
	request.Header.Set("Content-Type", "application/json")
	response, err := app.Test(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusBadRequest)
	}
}

func TestUpdateCheckRejectsOversizedVersion(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}
	body := `{"current_version":"` + strings.Repeat("9", 65) + `","installation_id":"` + strings.Repeat("a", 64) + `"}`
	request := httptest.NewRequest(http.MethodPost, "/api/v1/update/check", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response, err := app.Test(request)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusBadRequest)
	}
}

func TestDashboardAggregatesInstallationsWithoutExposingIdentifiers(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}

	publish := httptest.NewRequest(http.MethodPut, "/api/v1/releases/current", strings.NewReader(`{
		"version":"2026.09.21.03","build":"108","date":"2026-09-21","minimumSystem":"14.0",
		"url":"https://getopenstats.com/download/XStats.zip",
		"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"size":123456,"notes":["新增安装统计"]
	}`))
	publish.Header.Set("Content-Type", "application/json")
	publish.Header.Set("Authorization", "Bearer release-secret")
	if response, err := app.Test(publish); err != nil || response.StatusCode != http.StatusNoContent {
		t.Fatalf("publish response = %v, err = %v", response, err)
	}

	checks := []string{
		`{"current_version":"2026.09.21.01","installation_id":"1111111111111111111111111111111111111111111111111111111111111111"}`,
		`{"current_version":"2026.09.21.01","installation_id":"1111111111111111111111111111111111111111111111111111111111111111"}`,
		`{"current_version":"2026.09.21.02","installation_id":"2222222222222222222222222222222222222222222222222222222222222222"}`,
	}
	for _, body := range checks {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/update/check", strings.NewReader(body))
		request.Header.Set("Content-Type", "application/json")
		response, err := app.Test(request)
		if err != nil || response.StatusCode != http.StatusOK {
			t.Fatalf("check response = %v, err = %v", response, err)
		}
	}

	response, err := app.Test(httptest.NewRequest(http.MethodGet, "/stats", nil))
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.StatusCode, http.StatusOK)
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	html := string(body)
	for _, want := range []string{`data-total-installations="2"`, "2026.09.21.01", "2026.09.21.02"} {
		if !strings.Contains(html, want) {
			t.Fatalf("dashboard does not contain %q", want)
		}
	}
	if strings.Contains(html, "1111111111111111111111111111111111111111111111111111111111111111") {
		t.Fatal("dashboard exposes an installation identifier")
	}
}

func TestResponsesOfferCorrespondingSource(t *testing.T) {
	app, err := newApplication(t.TempDir()+"/xstats.sqlite", "release-secret")
	if err != nil {
		t.Fatal(err)
	}

	response, err := app.Test(httptest.NewRequest(http.MethodGet, "/stats", nil))
	if err != nil {
		t.Fatal(err)
	}
	want := `<https://github.com/ysicing/xstats>; rel="source"`
	if got := response.Header.Get("Link"); got != want {
		t.Fatalf("Link = %q, want %q", got, want)
	}
}
