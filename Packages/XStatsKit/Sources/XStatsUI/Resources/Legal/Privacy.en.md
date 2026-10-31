# XStats Privacy Policy

Effective date: October 6, 2026

This policy describes the data, online services and permissions XStats uses. Contact: i@xiai.me.

## 1. Local data and permissions

- **System monitoring**: metrics and process lists are processed on your Mac; history and preferences are stored locally.
- **Calendar**: system events and due reminders are off by default. With permission, XStats reads the visible month from selected lists while the panel is open and clears the displayed list when it closes. List selections are stored locally. You can turn reading off in calendar settings or revoke access in System Settings.
- **AI usage**: off by default; requires Magpie to be installed and running. When enabled, XStats reads account quotas, tokens and costs through the local API. Disabling the feature stops reading. Apple Intelligence process explanations run on-device.
- **Diagnostic exports**: you choose where to save them. Archives may include settings summaries, the last three days of system logs, cleanup records and crash reports. Review the contents before sharing.
- **Audio**: off by default. System volume and device switching run locally. App volume on macOS 14.4 or later requires system audio capture permission. Audio is processed locally in real time; app volume and output preferences are stored locally. Adjustments remain active when the interface closes; disabling the feature or sleeping stops processing. You can revoke permission in System Settings.
- **Network Monitor**: available on macOS 15 or later, off by default, and requires system extension approval. While its page is visible, it records the app, destination, port, protocol, time, closure status and system byte counts of new connections, saving the last 15 minutes of connection and traffic history in a local SQLite database. Expired rows are removed when collecting or viewing history; no background cleanup runs after monitoring or the app stops. The interface loads only the current page and chart data; communication content is never inspected. Pausing, hiding the page, locking or sleeping stops observation. Stopping or disabling the feature stops new collection and disables its filter configuration. Existing history expires under the retention policy and can also be deleted immediately with Clear Records. The map downloads a public IP-to-country database and a pinned ip2region province, city and provider database from `c.ysicing.net`, caching both locally for offline lookups. Destination IPs are not sent to the service. Mainland China connections are grouped by city, falling back to province or country. Coordinates represent areas, not precise device locations. Province, city and provider metadata expires with local connection history.

## 2. Update checks and installation statistics

Update checks send the app version and the SHA-256 hash of an installation identifier to the XStats update service. The identifier is generated locally from a random value or the Mac's serial number. Service endpoints are `apps.china.12306.work`, `apps.12306.work` and `apps-api.xiai.me`.

The service stores the hash, version, first and most recent check times, and cumulative check count for installation, version distribution and activity statistics. These aggregates are retained indefinitely; you can request deletion. Request IPs are used in memory for one-minute rate limiting; network infrastructure may process connection metadata under its own rules.

Choose a check frequency in Settings → About, or select Never for manual checks only. You decide whether to download and install updates. Email us to access or delete a statistics record, providing the installation identifier hash so we can locate it.

## 3. Online features

- **Public IP and location**: public-IP lookup uses Cloudflare `1.1.1.1`, falling back to ipify. Location, ASN, network type and cleanliness queries send your public IP to `cleanip.io`. Results are cached locally.
- **WebRTC checks**: send detected HTTP and STUN public IPs to `ipwho.is` for region, city, organization, ISP and provider domain information. Results are cached locally for seven days, up to 256 IPs. Expired entries refresh on demand; failed refreshes retain old results. Closing the window or system suspension cancels lookups.
- **Network diagnostics**: connection probes, speed tests, egress checks and DNS lookups contact selected targets, test nodes, websites or DNS services. Those services can receive connection metadata and the data needed for the test.
- **Global probes**: submit the target domain to Globalping. Others can retrieve measurement parameters and results using the measurement ID; submit only targets suitable for public disclosure.

Third-party services process requests under their own privacy policies.

## 4. Data controls and contact

You and macOS manage local data. Preferences, logs and exported diagnostic archives may remain after uninstalling and can be deleted manually. Disabling a feature stops its future queries.

Contact i@xiai.me to ask about, correct or delete a server-side record we can locate, or to raise a privacy concern. Emails are used to handle your request and kept for the time needed for that purpose and applicable obligations.

If processing changes materially, we will update this policy and its effective date and provide the new version in the app or project page.
