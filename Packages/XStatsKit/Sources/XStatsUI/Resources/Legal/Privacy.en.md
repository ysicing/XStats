# XStats Privacy Policy

Effective date: October 6, 2026

This policy explains what XStats processes on your Mac and which features contact external services. XStats-operated services retain only the update-statistics aggregates described in section 2; the app's other persisted data stays on your Mac and is not uploaded to XStats-operated servers. Network tests send requests needed for the test to independent providers, as described in section 3. Contact: i@xiai.me.

## 1. Data processed on your Mac

CPU, GPU, memory, network, temperature, fan, and process metrics come from local system interfaces. Those metrics, their history, and process lists are processed on your Mac and are not uploaded to the XStats update service. Preferences are stored locally.

Calendar events and due reminders are off by default. After you explicitly grant access, XStats reads the visible month range from your selected lists through macOS calendar APIs while the panel is open. It displays the contents locally without creating, modifying, deleting, or uploading records, and does not include them in settings backups or widget summaries. Closing the panel clears its displayed list. List selections stay on this Mac. You can turn reading off in calendar settings or revoke access in System Settings.

The AI feature is off by default. When enabled, XStats reads account quotas, token usage and costs only from the local Magpie interface (127.0.0.1) and shows them on this Mac. It does not scan Codex / Claude Code session logs, read login credentials, or contact model providers or pricing services directly. Quotas and usage are not uploaded to XStats servers; disabling the feature stops reading. Apple Intelligence process explanations run on-device and do not send process information to another AI service.

You choose whether and where to export diagnostics; they are not uploaded automatically. An exported archive may contain a settings summary, the last three days of system logs, cleanup records, and crash reports. Review it before sharing.

Audio controls are disabled by default. System volume, mute and output/input device switching use local Core Audio interfaces; unsupported controls are unavailable. On macOS 14.4 or later, app volume requires explicit system audio capture authorization. Audio is processed locally in real time and is never recorded, saved or uploaded. App volume and independent output preferences are stored locally by app identifier. Adjustments remain active when the interface closes; disabling the feature or sleeping stops processing and releases audio objects. Authorization can be revoked in System Settings.

Network Monitor requires macOS 15 or later and is disabled by default. After you explicitly enable the viewer and approve its system extension, it records app, destination, port, protocol time and closure metadata for new connections only while the viewer is visible. All connections are allowed; communication content is not read. Up to 512 display records are held in memory, never written to history, backups or widgets and never uploaded. On first use and updates, the country map downloads a public IP-to-country database from `c.ysicing.net` and caches it locally for offline lookup. Downloads include no installation identifier, destination IPs or observed records, and positions do not represent precise device locations. Pausing freezes the view and stops reading. Hiding the viewer, locking or sleeping stops observation; disabling the module clears display records and disables its filter configuration.

## 2. Update checks and installation statistics

When automatic update checks are enabled, XStats sends its current version and the SHA-256 hash of an installation identifier to the XStats update service according to the schedule selected in Settings → About: quietly while running, at launch, daily, weekly, or monthly. Choosing Never limits these requests to manual checks. Quiet checks still contact the service but do not show an update prompt. China-region devices try `apps.china.12306.work`, `apps.12306.work`, then `apps-api.xiai.me`; other devices try `apps.12306.work`, `apps-api.xiai.me`, then `apps.china.12306.work`. Each subsequent endpoint is tried serially only if the previous one fails. Checks stop after the first success or the final failure. The identifier is derived locally from a random value or the Mac's serial number; the raw serial number is not sent.

The update service's application database stores the hash, current version, first and most recent check times, and cumulative check count. These aggregate records support deduplicated installation counts, version distribution, and activity statistics. They have no automatic expiry. The update service does not create a separate record for every request or store request IP addresses in its application database. It uses IP addresses in memory for one-minute rate limiting. Network infrastructure may process connection metadata under its own rules.

You can set automatic checks to Never in Settings → About. You decide whether to download and install an available update. To request access to or deletion of an associated aggregate record, email us below; we may need the hash of your local installation identifier to locate it.

## 3. Other network features

- When you open network details with public-IP lookup enabled, XStats contacts Cloudflare `1.1.1.1`, falling back to ipify. It sends your public IP address to `cleanip.io` for location, ASN, network type, and cleanliness information. Results are cached locally.
- WebRTC checks in Egress & Routing send the detected HTTP and STUN public IP addresses to `ipwho.is` for country/region, city, organization, ISP, and provider domain information. Each IP's location is cached locally for seven days and refreshed on demand after expiry. Failed refreshes retain older data; the cache holds up to 256 IP addresses. Closing the window or system suspension cancels lookups.
- Connection probing sends ICMP packets to your selected target when enabled. Speed tests, egress checks, and DNS lookups contact selected test nodes, websites, or DNS services only when you use those features. Those services can observe connection metadata and the data needed for the test.
- Globalping receives the target domain you enter. Measurement parameters and results can be retrieved by anyone with the measurement ID; do not enter a target you want to keep private.

These third-party services operate independently and process requests under their own policies. Except for update checks, these requests are not relayed through XStats servers.

## 4. Retention, controls, and contact

You and macOS control local data. Uninstalling the app may leave local preferences, logs, or diagnostic archives you exported. You can disable optional features to stop future requests and delete local data yourself.

The update service retains hashed aggregate records without automatic expiry, as described in section 2. If you email us, we use your message to handle the request and keep it only as long as needed for that purpose and applicable obligations. Contact i@xiai.me to ask about, correct, or delete an associated record we can locate, or to raise a privacy concern.

If our processing changes materially, we will update this policy and its effective date and make the new version available in the app or project page.
