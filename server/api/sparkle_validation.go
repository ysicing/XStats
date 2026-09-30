// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"io"
	"strconv"
	"strings"
)

// 与客户端 App/Info.plist 的 SUPublicEDKey 一致；更换发布密钥时同步更新。
const sparklePublicKey = "j/I8zd8BXz4oPldnhocEySXTMmXPxKMyBRwoA4ewLIk="

type sparkleRSS struct {
	XMLName  xml.Name `xml:"rss"`
	Version  string   `xml:"version,attr"`
	Channels []struct {
		Items []struct {
			Build         string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle version"`
			Version       string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle shortVersionString"`
			MinimumSystem string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle minimumSystemVersion"`
			Hardware      string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle hardwareRequirements"`
			SHA256        string `xml:"https://github.com/ysicing/xstats/appcast sha256"`
			Enclosures    []struct {
				URL              string `xml:"url,attr"`
				Size             int64  `xml:"length,attr"`
				Signature        string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle edSignature,attr"`
				InstallationType string `xml:"http://www.andymatuschak.org/xml-namespaces/sparkle installationType,attr"`
			} `xml:"enclosure"`
		} `xml:"item"`
	} `xml:"channel"`
}

func validateSparkleFeed(data []byte, current release) error {
	// Sparkle 2.10 将整个 XML 正文签名后附加此注释块；必须对原始字节验签。
	prefix := []byte("<!-- sparkle-signatures:\n")
	start := bytes.LastIndex(data, prefix)
	if start < 0 {
		return errors.New("missing feed signature")
	}
	block := data[start+len(prefix):]
	end := bytes.Index(block, []byte("-->"))
	if end < 0 || len(bytes.TrimSpace(block[end+3:])) != 0 {
		return errors.New("invalid signature block")
	}
	lines := strings.Split(strings.TrimSpace(string(block[:end])), "\n")
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "edSignature:") || !strings.HasPrefix(lines[1], "length:") {
		return errors.New("invalid signature fields")
	}
	signature, err := base64.StdEncoding.DecodeString(strings.TrimSpace(strings.TrimPrefix(lines[0], "edSignature:")))
	if err != nil || len(signature) != ed25519.SignatureSize {
		return errors.New("invalid feed signature")
	}
	length, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(lines[1], "length:")))
	if err != nil || length != start {
		return errors.New("invalid signed length")
	}
	key, err := base64.StdEncoding.DecodeString(sparklePublicKey)
	if err != nil || len(key) != ed25519.PublicKeySize || !ed25519.Verify(key, data[:start], signature) {
		return errors.New("feed signature verification failed")
	}
	var rss sparkleRSS
	decoder := xml.NewDecoder(bytes.NewReader(data[:start]))
	if err := decoder.Decode(&rss); err != nil {
		return err
	}
	// Decode 只读第一个元素，拒绝正文末尾的第二个根节点或无效 XML。
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		switch token := token.(type) {
		case xml.Comment:
		case xml.CharData:
			if len(bytes.TrimSpace(token)) != 0 {
				return errors.New("unexpected content after feed")
			}
		default:
			return errors.New("unexpected content after feed")
		}
	}
	if rss.XMLName.Space != "" || rss.Version != "2.0" || len(rss.Channels) != 1 || len(rss.Channels[0].Items) != 1 {
		return errors.New("invalid RSS channel or items")
	}
	item := rss.Channels[0].Items[0]
	if item.Version != current.Version || item.Build != current.Build || item.MinimumSystem != current.MinimumSystem || item.Hardware != "arm64" || item.SHA256 != current.SHA256 || len(item.Enclosures) != 1 {
		return errors.New("feed does not match published release")
	}
	enclosure := item.Enclosures[0]
	archiveSignature, err := base64.StdEncoding.DecodeString(enclosure.Signature)
	if err != nil || len(archiveSignature) != ed25519.SignatureSize || enclosure.InstallationType != "application" || enclosure.URL != current.URL || enclosure.Size != current.Size {
		return errors.New("invalid update enclosure")
	}
	return nil
}
