// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gofiber/fiber/v3"
	"github.com/libtnb/sqlite"
	"gorm.io/gorm"
)

type feedTransport func(*http.Request) (*http.Response, error)

func (f feedTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func publishSparkleFixture(t *testing.T, app *fiber.App, version, build string) {
	t.Helper()
	body := fmt.Sprintf(`{"version":%q,"build":%q,"date":"2026-09-30","minimumSystem":"14.0","url":"https://example.test/XStats-%s.zip","sha256":"%s","size":1000,"notes":["test"]}`, version, build, version, strings.Repeat("a", 64))
	req := httptest.NewRequest(http.MethodPut, "/api/v1/releases/current", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer release-secret")
	res, err := app.Test(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusNoContent {
		t.Fatalf("publish: %d", res.StatusCode)
	}
}

func TestSparkleStableFeedPreservesBytesAndTracksOncePerGet(t *testing.T) {
	bytes := "<?xml version=\"1.0\"?>\n<rss/>\n<!-- sparkle:edSignature test -->\n"
	var urls []string
	client := &http.Client{Transport: feedTransport(func(r *http.Request) (*http.Response, error) {
		urls = append(urls, r.URL.String())
		if r.URL.RawQuery != "" {
			t.Fatal("installation identifier forwarded to CDN")
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(bytes)), Header: make(http.Header), Request: r}, nil
	})}
	databasePath := t.TempDir() + "/xstats.sqlite"
	app, err := newApplicationWithFeedClient(databasePath, "release-secret", client)
	if err != nil {
		t.Fatal(err)
	}
	endpoint := "/api/v1/update/appcast.xml?current_version=0.14.0&installation_id=" + strings.Repeat("b", 64)
	for index, version := range []string{"0.14.1", "0.14.2"} {
		publishSparkleFixture(t, app, version, fmt.Sprint(126+index))
		res, err := app.Test(httptest.NewRequest(http.MethodGet, endpoint, nil))
		if err != nil {
			t.Fatal(err)
		}
		data, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != 200 || string(data) != bytes || res.Header.Get("Cache-Control") != "no-store" {
			t.Fatalf("feed: %d %s", res.StatusCode, data)
		}
	}
	if strings.Join(urls, ",") != "https://example.test/XStats-0.14.1.xml,https://example.test/XStats-0.14.2.xml" {
		t.Fatal(urls)
	}
	database, err := gorm.Open(sqlite.Open(databasePath), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	connection, err := database.DB()
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	var record installation
	if err := database.First(&record, "id = ?", strings.Repeat("b", 64)).Error; err != nil {
		t.Fatal(err)
	}
	if record.Checks != 2 {
		t.Fatalf("GET count = %d", record.Checks)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/update/check", strings.NewReader(`{"current_version":"0.14.0","installation_id":"`+strings.Repeat("b", 64)+`"}`))
	req.Header.Set("Content-Type", "application/json")
	res, err := app.Test(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		t.Fatal(res.StatusCode)
	}
	if err := database.First(&record, "id = ?", strings.Repeat("b", 64)).Error; err != nil {
		t.Fatal(err)
	}
	var count int64
	if err := database.Model(&installation{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	if count != 1 || record.Checks != 3 {
		t.Fatalf("legacy/new telemetry: rows %d, checks %d", count, record.Checks)
	}
}

func TestSparkleFeedRejectsInvalidInputsAndBoundedUpstreamFailures(t *testing.T) {
	for _, body := range []string{"", strings.Repeat("x", 256*1024+1)} {
		calls := 0
		client := &http.Client{Transport: feedTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header), Request: r}, nil
		})}
		app, err := newApplicationWithFeedClient(t.TempDir()+"/xstats.sqlite", "release-secret", client)
		if err != nil {
			t.Fatal(err)
		}
		publishSparkleFixture(t, app, "0.14.1", "126")
		for _, query := range []string{"", "?current_version=0.14.0&installation_id=serial"} {
			res, err := app.Test(httptest.NewRequest(http.MethodGet, "/api/v1/update/appcast.xml"+query, nil))
			if err != nil {
				t.Fatal(err)
			}
			res.Body.Close()
			if res.StatusCode != 400 {
				t.Fatal(res.StatusCode)
			}
		}
		if calls != 0 {
			t.Fatal("invalid request reached CDN")
		}
		res, err := app.Test(httptest.NewRequest(http.MethodGet, "/api/v1/update/appcast.xml?current_version=0.14.0&installation_id="+strings.Repeat("a", 64), nil))
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != 502 {
			t.Fatal(res.StatusCode)
		}
	}
}
