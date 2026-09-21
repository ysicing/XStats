// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import "testing"

func TestLoadConfigRequiresReleaseToken(t *testing.T) {
	_, err := loadConfig(func(string) string { return "" })
	if err == nil {
		t.Fatal("loadConfig accepted an empty release token")
	}
}

func TestLoadConfigRejectsWhitespaceReleaseToken(t *testing.T) {
	_, err := loadConfig(func(key string) string {
		if key == "XSTATS_RELEASE_TOKEN" {
			return "   "
		}
		return ""
	})
	if err == nil {
		t.Fatal("loadConfig accepted a whitespace-only release token")
	}
}

func TestLoadConfigUsesExplicitValues(t *testing.T) {
	values := map[string]string{
		"XSTATS_LISTEN":        "127.0.0.1:9090",
		"XSTATS_DATABASE":      "/var/lib/xstats/stats.sqlite",
		"XSTATS_RELEASE_TOKEN": "secret",
	}
	config, err := loadConfig(func(key string) string { return values[key] })
	if err != nil {
		t.Fatal(err)
	}
	if config.Listen != "127.0.0.1:9090" || config.Database != "/var/lib/xstats/stats.sqlite" || config.ReleaseToken != "secret" {
		t.Fatalf("unexpected config: %#v", config)
	}
}
