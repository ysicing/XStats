// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
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

func trackedInstallations(t *testing.T, databasePath string) int64 {
	t.Helper()
	database, err := gorm.Open(sqlite.Open(databasePath), &gorm.Config{})
	if err != nil {
		t.Fatal(err)
	}
	connection, err := database.DB()
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	var count int64
	if err := database.Model(&installation{}).Count(&count).Error; err != nil {
		t.Fatal(err)
	}
	return count
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
		if count := trackedInstallations(t, databasePath); count != 0 {
			t.Fatalf("invalid feed tracked %d", count)
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

// 生产客户端的跳转策略与上游故障都必须返回 502，且不计入检查统计。
func TestSparkleFeedUpstreamFailuresUseProductionRedirectPolicy(t *testing.T) {
	feed := signedSparkleFixture(t, "0.14.1")
	respond := func(r *http.Request, status int, location, body string) *http.Response {
		header := make(http.Header)
		if location != "" {
			header.Set("Location", location)
		}
		return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(body)), Header: header, Request: r}
	}
	cases := []struct {
		name     string
		status   int
		tracked  int64
		requests int
		reply    func(*http.Request) (*http.Response, error)
	}{
		{"https redirect", 200, 1, 2, func(r *http.Request) (*http.Response, error) {
			if r.URL.Path == "/final.xml" {
				return respond(r, 200, "", feed), nil
			}
			return respond(r, 302, "https://cdn.example.test/final.xml", ""), nil
		}},
		{"http downgrade", 502, 0, 1, func(r *http.Request) (*http.Response, error) {
			return respond(r, 302, "http://example.test/XStats-0.14.1.xml", ""), nil
		}},
		{"redirect loop", 502, 0, 5, func(r *http.Request) (*http.Response, error) {
			return respond(r, 302, "https://example.test/loop", ""), nil
		}},
		{"not found", 502, 0, 1, func(r *http.Request) (*http.Response, error) {
			return respond(r, 404, "", feed), nil
		}},
		{"transport error", 502, 0, 1, func(r *http.Request) (*http.Response, error) {
			return nil, errors.New("connection reset")
		}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			var requests []string
			transport := feedTransport(func(r *http.Request) (*http.Response, error) {
				requests = append(requests, r.URL.String())
				return test.reply(r)
			})
			client := &http.Client{Transport: transport, CheckRedirect: feedRedirectPolicy}
			databasePath := t.TempDir() + "/xstats.sqlite"
			app, err := newApplicationWithFeedClient(databasePath, "release-secret", client)
			if err != nil {
				t.Fatal(err)
			}
			publishSparkleFixture(t, app, "0.14.1", "126")
			res, err := app.Test(httptest.NewRequest(http.MethodGet, "/api/v1/update/appcast.xml?current_version=0.14.0&installation_id="+strings.Repeat("c", 64), nil))
			if err != nil {
				t.Fatal(err)
			}
			res.Body.Close()
			if res.StatusCode != test.status {
				t.Fatalf("status %d, want %d", res.StatusCode, test.status)
			}
			if count := trackedInstallations(t, databasePath); count != test.tracked {
				t.Fatalf("tracked %d, want %d", count, test.tracked)
			}
			// 策略必须在发出 HTTP 请求或超过 5 次跳转之前拦截，而不只依赖处理函数兜底。
			if len(requests) != test.requests {
				t.Fatalf("upstream requests %v, want %d", requests, test.requests)
			}
		})
	}
}

// 服务端验签公钥必须与客户端内置公钥一致，轮换时漏改会让所有 Sparkle 检查返回 502。
func TestSparklePublicKeyMatchesClient(t *testing.T) {
	sources := map[string]*regexp.Regexp{
		"../../App/Info.plist": regexp.MustCompile(`<key>SUPublicEDKey</key>\s*<string>([^<]+)</string>`),
		"../../project.yml":    regexp.MustCompile(`SUPublicEDKey:\s*"([^"]+)"`),
	}
	for path, pattern := range sources {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		match := pattern.FindSubmatch(data)
		if match == nil {
			t.Fatalf("%s: SUPublicEDKey not found", path)
		}
		if string(match[1]) != sparklePublicKey {
			t.Fatalf("%s: SUPublicEDKey %s != server %s", path, match[1], sparklePublicKey)
		}
	}
}

func TestSparkleReleaseProbeReturnsFeedWithoutTracking(t *testing.T) {
	feed := signedSparkleFixture(t, "0.14.1")
	client := &http.Client{Transport: feedTransport(func(r *http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(feed)), Header: make(http.Header), Request: r}, nil
	})}
	databasePath := t.TempDir() + "/xstats.sqlite"
	app, err := newApplicationWithFeedClient(databasePath, "release-secret", client)
	if err != nil {
		t.Fatal(err)
	}
	publishSparkleFixture(t, app, "0.14.1", "126")
	res, err := app.Test(httptest.NewRequest(http.MethodGet, "/api/v1/update/appcast.xml?current_version=0.14.1&installation_id="+releaseProbeInstallationID, nil))
	if err != nil {
		t.Fatal(err)
	}
	data, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || string(data) != feed {
		t.Fatalf("probe: %d", res.StatusCode)
	}
	if count := trackedInstallations(t, databasePath); count != 0 {
		t.Fatalf("release probe tracked %d", count)
	}
}
