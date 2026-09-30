// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gofiber/fiber/v3"
	"github.com/libtnb/sqlite"
	"gorm.io/gorm"
)

type feedTransport func(*http.Request) (*http.Response, error)

func (f feedTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// 已签名的固定夹具避免在 CI 中读取发布私钥；安装包签名只作结构测试。
func signedSparkleFixture(t *testing.T, version string) string {
	t.Helper()
	data, err := os.ReadFile("testdata/sparkle-" + version + ".xml")
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

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
	bytes := signedSparkleFixture(t, "0.14.1")
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
		bytes = signedSparkleFixture(t, version)
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
	for _, body := range []string{"", strings.Repeat("x", 256*1024+1), "<html>CDN error</html>", "<rss>", "<rss/>", strings.Replace(signedSparkleFixture(t, "0.14.1"), "XStats updates", "tampered", 1), signedSparkleFixture(t, "0.14.2")} {
		calls := 0
		client := &http.Client{Transport: feedTransport(func(r *http.Request) (*http.Response, error) {
			calls++
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body)), Header: make(http.Header), Request: r}, nil
		})}
		databasePath := t.TempDir() + "/xstats.sqlite"
		app, err := newApplicationWithFeedClient(databasePath, "release-secret", client)
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
		db, err := gorm.Open(sqlite.Open(databasePath), &gorm.Config{})
		if err != nil {
			t.Fatal(err)
		}
		connection, err := db.DB()
		if err != nil {
			t.Fatal(err)
		}
		var count int64
		err = db.Model(&installation{}).Count(&count).Error
		connection.Close()
		if err != nil || count != 0 {
			t.Fatalf("invalid feed tracked %d: %v", count, err)
		}
		legacy := httptest.NewRequest(http.MethodPost, "/api/v1/update/check", strings.NewReader(`{"current_version":"0.12.1","installation_id":"`+strings.Repeat("a", 64)+`"}`))
		legacy.Header.Set("Content-Type", "application/json")
		res, err = app.Test(legacy)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != 200 {
			t.Fatalf("legacy update: %d", res.StatusCode)
		}
	}
}

// 保持同一份有效签名，改变发布指针的各项元数据必须被拒绝。
func TestSparkleFeedValidatesPublishedMetadataAndSignature(t *testing.T) {
	feed := signedSparkleFixture(t, "0.14.1")
	published := release{Version: "0.14.1", Build: "126", MinimumSystem: "14.0", URL: "https://example.test/XStats-0.14.1.zip", Size: 1000, SHA256: strings.Repeat("a", 64)}
	if err := validateSparkleFeed([]byte(feed), published); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"version", "build", "minimumSystem", "url", "size", "sha256"} {
		t.Run(field, func(t *testing.T) {
			altered := published
			switch field {
			case "version":
				altered.Version = "0.14.2"
			case "build":
				altered.Build = "127"
			case "minimumSystem":
				altered.MinimumSystem = "15.0"
			case "url":
				altered.URL = "https://example.test/other.zip"
			case "size":
				altered.Size++
			case "sha256":
				altered.SHA256 = strings.Repeat("b", 64)
			}
			if validateSparkleFeed([]byte(feed), altered) == nil {
				t.Fatal("mismatch accepted")
			}
		})
	}
	signatureStart := strings.LastIndex(feed, "<!-- sparkle-signatures:")
	unsigned := feed[:signatureStart]
	for _, broken := range []string{unsigned, feed + "<rss/>", strings.Replace(feed, "length:", "invalid:", 1), strings.Replace(feed, "edSignature:", "edSignature:broken", 1), strings.Replace(feed, "XStats updates", "tampered", 1)} {
		if validateSparkleFeed([]byte(broken), published) == nil {
			t.Fatal("invalid signature accepted")
		}
	}
}
