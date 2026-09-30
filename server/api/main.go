// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"crypto/subtle"
	"embed"
	"errors"
	"html/template"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/limiter"
	"github.com/libtnb/sqlite"
	"gorm.io/gorm"
	gormlogger "gorm.io/gorm/logger"
)

var installationIDPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

// 发布脚本端到端核验更新源时使用的保留标识；清单照常校验返回，但不计入安装统计。
var releaseProbeInstallationID = strings.Repeat("0", 64)

func validHTTPS(raw string, optional bool) bool {
	if raw == "" {
		return optional
	}
	parsed, err := url.Parse(raw)
	return err == nil && parsed.Scheme == "https" && parsed.Host != ""
}

//go:embed dashboard.html
var dashboardFiles embed.FS

var dashboardTemplate = template.Must(template.ParseFS(dashboardFiles, "dashboard.html"))

type release struct {
	ID            uint      `json:"-" gorm:"primaryKey"`
	Version       string    `json:"version" gorm:"uniqueIndex;size:64;not null"`
	Build         string    `json:"build" gorm:"size:64;not null"`
	Date          string    `json:"date" gorm:"size:32;not null"`
	MinimumSystem string    `json:"minimumSystem" gorm:"size:32;not null"`
	URL           string    `json:"url" gorm:"not null"`
	SHA256        string    `json:"sha256" gorm:"size:64;not null"`
	Size          int64     `json:"size" gorm:"not null"`
	DMG           string    `json:"dmg,omitempty"`
	Notes         []string  `json:"notes" gorm:"serializer:json"`
	Changelog     string    `json:"changelog,omitempty"`
	IsCurrent     bool      `json:"-" gorm:"index;not null"`
	CreatedAt     time.Time `json:"-"`
	UpdatedAt     time.Time `json:"-"`
}

type installation struct {
	ID             string    `gorm:"primaryKey;size:64"`
	CurrentVersion string    `gorm:"size:64;not null"`
	Checks         uint64    `gorm:"not null"`
	FirstSeenAt    time.Time `gorm:"not null"`
	LastSeenAt     time.Time `gorm:"index;not null"`
}

type updateCheck struct {
	CurrentVersion string `json:"current_version"`
	InstallationID string `json:"installation_id"`
}

type versionStat struct {
	Version string
	Count   int64
	Percent int
}

type dashboardData struct {
	GeneratedAt         string
	TotalInstallations  int64
	ActiveInstallations int64
	TotalChecks         int64
	CurrentVersion      string
	Versions            []versionStat
}

type config struct {
	Listen       string
	Database     string
	ReleaseToken string
}

func loadConfig(getenv func(string) string) (config, error) {
	configuration := config{
		Listen:       getenv("XSTATS_LISTEN"),
		Database:     getenv("XSTATS_DATABASE"),
		ReleaseToken: strings.TrimSpace(getenv("XSTATS_RELEASE_TOKEN")),
	}
	if configuration.Listen == "" {
		configuration.Listen = ":8080"
	}
	if configuration.Database == "" {
		configuration.Database = "xstats-api.sqlite"
	}
	if configuration.ReleaseToken == "" {
		return config{}, errors.New("XSTATS_RELEASE_TOKEN is required")
	}
	return configuration, nil
}

func newApplication(databasePath string, releaseToken string) (*fiber.App, error) {
	return newApplicationWithFeedClient(databasePath, releaseToken, &http.Client{
		Timeout:       10 * time.Second,
		CheckRedirect: feedRedirectPolicy,
	})
}

// 更新清单只允许有限次 HTTPS 跳转，降级到 HTTP 或跳转过多都视为上游故障。
func feedRedirectPolicy(request *http.Request, via []*http.Request) error {
	if request.URL.Scheme != "https" || len(via) >= 5 {
		return errors.New("invalid feed redirect")
	}
	return nil
}

func newApplicationWithFeedClient(databasePath string, releaseToken string, feedClient *http.Client) (*fiber.App, error) {
	databaseLogger := gormlogger.New(log.Default(), gormlogger.Config{
		SlowThreshold:             500 * time.Millisecond,
		LogLevel:                  gormlogger.Warn,
		IgnoreRecordNotFoundError: true,
		Colorful:                  false,
	})
	database, err := gorm.Open(
		sqlite.Open(databasePath+"?_txlock=immediate&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)"),
		&gorm.Config{Logger: databaseLogger},
	)
	if err != nil {
		return nil, err
	}
	if err := database.AutoMigrate(&release{}, &installation{}); err != nil {
		return nil, err
	}
	sqlDatabase, err := database.DB()
	if err != nil {
		return nil, err
	}
	sqlDatabase.SetMaxOpenConns(1)
	sqlDatabase.SetMaxIdleConns(1)

	app := fiber.New(fiber.Config{
		BodyLimit:    64 * 1024,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	})
	app.Use(func(c fiber.Ctx) error {
		c.Set(fiber.HeaderLink, `<https://github.com/ysicing/xstats>; rel="source"`)
		return c.Next()
	})
	app.Put("/api/v1/releases/current", func(c fiber.Ctx) error {
		provided := strings.TrimPrefix(c.Get(fiber.HeaderAuthorization), "Bearer ")
		if provided == "" || subtle.ConstantTimeCompare([]byte(provided), []byte(releaseToken)) != 1 {
			return c.Status(http.StatusUnauthorized).JSON(fiber.Map{"error": "unauthorized"})
		}
		var candidate release
		if err := c.Bind().Body(&candidate); err != nil {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid request"})
		}
		if candidate.Version == "" || candidate.Build == "" || candidate.Date == "" ||
			candidate.MinimumSystem == "" || !validHTTPS(candidate.URL, false) || !validHTTPS(candidate.DMG, true) ||
			!validHTTPS(candidate.Changelog, true) || !installationIDPattern.MatchString(candidate.SHA256) ||
			candidate.Size <= 0 || len(candidate.Notes) == 0 {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid release"})
		}
		err := database.Transaction(func(transaction *gorm.DB) error {
			if err := transaction.Model(&release{}).Where("is_current = ?", true).Update("is_current", false).Error; err != nil {
				return err
			}
			candidate.IsCurrent = true
			return transaction.Where("version = ?", candidate.Version).Assign(candidate).FirstOrCreate(&candidate).Error
		})
		if err != nil {
			return c.Status(http.StatusInternalServerError).JSON(fiber.Map{"error": "could not publish release"})
		}
		return c.SendStatus(http.StatusNoContent)
	})
	checkLimiter := limiter.New(limiter.Config{Max: 30, Expiration: time.Minute})
	app.Post("/api/v1/update/check", checkLimiter, func(c fiber.Ctx) error {
		var check updateCheck
		if err := c.Bind().Body(&check); err != nil || check.CurrentVersion == "" || len(check.CurrentVersion) > 64 ||
			!installationIDPattern.MatchString(check.InstallationID) {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid request"})
		}
		if err := recordUpdateCheck(database, check); err != nil {
			return c.Status(http.StatusInternalServerError).JSON(fiber.Map{"error": "could not record update check"})
		}

		var current release
		if err := database.Where("is_current = ?", true).First(&current).Error; err != nil {
			return c.Status(http.StatusServiceUnavailable).JSON(fiber.Map{"error": "no release published"})
		}
		return c.JSON(current)
	})
	// 固定入口选择当前发布对应的不可变 XML；校验后原样返回，不重写或持有私钥。
	// 统计与本次 GET 合并，Sparkle 客户端无需再发一份 JSON POST。
	app.Get("/api/v1/update/appcast.xml", checkLimiter, func(c fiber.Ctx) error {
		c.Set(fiber.HeaderCacheControl, "no-store")
		check := updateCheck{CurrentVersion: c.Query("current_version"), InstallationID: c.Query("installation_id")}
		if check.CurrentVersion == "" || len(check.CurrentVersion) > 64 || !installationIDPattern.MatchString(check.InstallationID) {
			return c.Status(http.StatusBadRequest).JSON(fiber.Map{"error": "invalid request"})
		}
		var current release
		if err := database.Where("is_current = ?", true).First(&current).Error; err != nil {
			return c.SendStatus(http.StatusServiceUnavailable)
		}
		asset, err := url.Parse(current.URL)
		if err != nil || asset.Scheme != "https" || asset.Host == "" || !strings.HasSuffix(asset.Path, ".zip") {
			return c.SendStatus(http.StatusServiceUnavailable)
		}
		asset.Path = strings.TrimSuffix(asset.Path, ".zip") + ".xml"
		asset.RawPath, asset.RawQuery, asset.Fragment = "", "", ""
		request, err := http.NewRequestWithContext(c.Context(), http.MethodGet, asset.String(), nil)
		if err != nil {
			return c.SendStatus(http.StatusBadGateway)
		}
		response, err := feedClient.Do(request)
		if err != nil {
			return c.SendStatus(http.StatusBadGateway)
		}
		defer response.Body.Close()
		// 单版本清单有界读取；CDN 错误页、大响应和重定向降级不能成为更新源。
		const maximumFeedBytes = 256 * 1024
		if response.StatusCode != http.StatusOK || response.Request.URL.Scheme != "https" {
			return c.SendStatus(http.StatusBadGateway)
		}
		data, err := io.ReadAll(io.LimitReader(response.Body, maximumFeedBytes+1))
		if err != nil || len(data) == 0 || len(data) > maximumFeedBytes {
			return c.SendStatus(http.StatusBadGateway)
		}
		if err := validateSparkleFeed(data, current); err != nil {
			return c.SendStatus(http.StatusBadGateway)
		}
		if check.InstallationID != releaseProbeInstallationID {
			if err := recordUpdateCheck(database, check); err != nil {
				return c.SendStatus(http.StatusInternalServerError)
			}
		}
		c.Type("xml", "utf-8")
		return c.Send(data)
	})
	app.Get("/stats", func(c fiber.Ctx) error {
		var data dashboardData
		data.GeneratedAt = time.Now().Format("2006-01-02 15:04:05 MST")
		if err := database.Model(&installation{}).Count(&data.TotalInstallations).Error; err != nil {
			return c.SendStatus(http.StatusInternalServerError)
		}
		if err := database.Model(&installation{}).Where("last_seen_at >= ?", time.Now().UTC().Add(-24*time.Hour)).
			Count(&data.ActiveInstallations).Error; err != nil {
			return c.SendStatus(http.StatusInternalServerError)
		}
		if err := database.Model(&installation{}).Select("COALESCE(SUM(checks), 0)").Scan(&data.TotalChecks).Error; err != nil {
			return c.SendStatus(http.StatusInternalServerError)
		}
		var current release
		if err := database.Where("is_current = ?", true).First(&current).Error; err == nil {
			data.CurrentVersion = current.Version
		}
		if err := database.Model(&installation{}).
			Select("current_version AS version, COUNT(*) AS count").
			Group("current_version").Order("count DESC, current_version DESC").Scan(&data.Versions).Error; err != nil {
			return c.SendStatus(http.StatusInternalServerError)
		}
		for index := range data.Versions {
			if data.TotalInstallations > 0 {
				data.Versions[index].Percent = int(data.Versions[index].Count * 100 / data.TotalInstallations)
			}
		}

		c.Type("html", "utf-8")
		return dashboardTemplate.ExecuteTemplate(c.Response().BodyWriter(), "dashboard.html", data)
	})
	return app, nil
}

func recordUpdateCheck(database *gorm.DB, check updateCheck) error {
	now := time.Now().UTC()
	return database.Transaction(func(transaction *gorm.DB) error {
		var item installation
		result := transaction.First(&item, "id = ?", check.InstallationID)
		if result.Error != nil && result.Error != gorm.ErrRecordNotFound {
			return result.Error
		}
		if result.Error == gorm.ErrRecordNotFound {
			item = installation{ID: check.InstallationID, CurrentVersion: check.CurrentVersion, Checks: 1, FirstSeenAt: now, LastSeenAt: now}
			return transaction.Create(&item).Error
		}
		return transaction.Model(&item).Updates(map[string]any{
			"current_version": check.CurrentVersion,
			"last_seen_at":    now,
			"checks":          gorm.Expr("checks + 1"),
		}).Error
	})
}

func main() {
	configuration, err := loadConfig(os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	app, err := newApplication(configuration.Database, configuration.ReleaseToken)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("XStats API listening on %s", configuration.Listen)
	if err := app.Listen(configuration.Listen, fiber.ListenConfig{DisableStartupMessage: true}); err != nil {
		log.Fatal(err)
	}
}
