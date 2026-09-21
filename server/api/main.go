// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"crypto/subtle"
	"embed"
	"errors"
	"html/template"
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
		now := time.Now().UTC()
		if err := database.Transaction(func(transaction *gorm.DB) error {
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
		}); err != nil {
			return c.Status(http.StatusInternalServerError).JSON(fiber.Map{"error": "could not record update check"})
		}

		var current release
		if err := database.Where("is_current = ?", true).First(&current).Error; err != nil {
			return c.Status(http.StatusServiceUnavailable).JSON(fiber.Map{"error": "no release published"})
		}
		return c.JSON(current)
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
