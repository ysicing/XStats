# XStats Privacy Policy

Effective date: September 23, 2026

This policy explains what XStats processes on your Mac and which features contact external services. XStats-operated services retain only the update-statistics aggregates described in section 2; the app's other persisted data stays on your Mac and is not uploaded to XStats-operated servers. Only if you configure and manually use WebDAV sync is a settings backup stored on the server you configured. Network tests also send requests needed for the test to independent providers, as described in sections 3 and 4. Contact: i@xiai.me.

## 1. Data processed on your Mac

CPU, GPU, memory, network, temperature, fan, and process metrics come from local system interfaces. Those metrics, their history, hardware serial numbers, and process lists are processed on your Mac and are not uploaded to the XStats update service. Preferences are stored locally; selected preferences become a remote backup only when you manually use WebDAV sync.

AI Usage is off by default. When enabled, it reads local Codex / Claude Code session logs to summarize token usage by model. It also checks the corresponding CLI login credentials read-only and directly queries Codex and Claude for five-hour and weekly quota usage. Each request sends the login token to its respective provider; XStats does not save tokens in its preferences or statistics database, and does not send session-log contents with quota requests. A quota request may fail or be rate-limited without affecting local token statistics. Turning the feature off stops subsequent scans and quota requests. Apple Intelligence process explanations run on-device and do not send process information to another AI service.
If you manually configure Sub2API as a backup quota source for Codex or Claude Code, the app contacts the HTTPS server specified for that source only when its automatic quota lookup fails. The two configurations are stored separately, and XStats verifies the queried account's platform. Your admin email and password are sent to the corresponding server to sign in. Passwords are stored separately in this Mac's Keychain; addresses, emails, and account IDs stay in local preferences and are excluded from WebDAV backups. Background quota requests use `force=false` and do not trigger active probes. Removing one source's configuration deletes its locally stored Sub2API password and connection details.

You choose whether and where to export diagnostics; they are not uploaded automatically. An exported archive may contain a settings summary, the last three days of system logs, cleanup records, and crash reports. Review it before sharing.

## 2. Update checks and installation statistics

When automatic update checks are enabled, XStats sends its current version and the SHA-256 hash of a random installation identifier to the XStats update service after launch and approximately daily thereafter. Manual checks send the same information. China-region devices try `x-stats.china.12306.work` first; others try `xstats-apps.12306.work` first. The other endpoint is tried only if the preferred one fails. The original random value stays in local preferences and is excluded from WebDAV backups.

The update service's application database stores the hash, current version, first and most recent check times, and cumulative check count. These aggregate records support deduplicated installation counts, version distribution, and activity statistics. They have no automatic expiry. The update service does not create a separate record for every request or store request IP addresses in its application database. It uses IP addresses in memory for one-minute rate limiting. Network infrastructure may process connection metadata under its own rules.

You can turn off automatic checks in Settings → About. You decide whether to download and install an available update. To request access to or deletion of an associated aggregate record, email us below; we may need the hash of your local installation identifier to locate it.

## 3. Other network features

- When AI Usage is enabled, XStats uses local Codex / Claude Code login credentials to contact the quota endpoints on `chatgpt.com` and `api.anthropic.com` directly. Those providers can observe the login token and connection metadata. Quota results are held only in app memory and are not uploaded to XStats servers.
- With a Codex or Claude Code Sub2API backup configured, a failed automatic lookup for that source causes a direct request to its chosen Sub2API server. That server receives the admin email, password, login token, and account ID being queried. XStats provides no preset Sub2API server and does not upload these values or quota results to XStats servers.
- When you open network details with public-IP lookup enabled, XStats contacts Cloudflare `1.1.1.1`, falling back to ipify. It sends your public IP address to `cleanip.io` for location, ASN, network type, and cleanliness information. Results are cached locally.
- Connection probing sends ICMP packets to your selected target when enabled. Speed tests, egress checks, and DNS lookups contact selected test nodes, websites, or DNS services only when you use those features. Those services can observe connection metadata and the data needed for the test.
- Globalping receives the target domain you enter. Measurement parameters and results can be retrieved by anyone with the measurement ID; do not enter a target you want to keep private.

These third-party services operate independently and process requests under their own policies. Except for update checks, these requests are not relayed through XStats servers.

## 4. WebDAV settings sync

You enter and save the WebDAV server address, username, and password yourself; XStats does not provide or preconfigure a WebDAV sync server. The app contacts that server over HTTPS only when you manually upload or download. The uploaded JSON contains preferences, not monitoring data, history, the original installation identifier, or WebDAV connection details. Your WebDAV password stays in the local Keychain. XStats does not add encryption to the backup file stored on your server. You and your chosen provider control retention and deletion there.

## 5. Retention, controls, and contact

You and macOS control local data. Uninstalling the app may leave local preferences, logs, or diagnostic archives you exported. You can disable optional features to stop future requests and delete local or WebDAV data yourself.

The update service retains hashed aggregate records without automatic expiry, as described in section 2. If you email us, we use your message to handle the request and keep it only as long as needed for that purpose and applicable obligations. Contact i@xiai.me to ask about, correct, or delete an associated record we can locate, or to raise a privacy concern.

If our processing changes materially, we will update this policy and its effective date and make the new version available in the app or project page.
