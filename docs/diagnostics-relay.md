<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Diagnostics Relay</h1>
<p align="center">How reports sent from Vivid reach the diagnostics inbox.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Apple TV has no Mail app, and an app can't safely hold an email login. So when someone presses Send in Settings → Diagnostics, Vivid posts the report to a small Cloudflare Worker at `diagnostics.vividapp.co`. The Worker keeps a copy in Workers KV for 30 days and emails it to `diagnostics@vividapp.co`, which is delivered to the iCloud Mail inbox like any other mail to the domain.

The source is in [`diagnostics-relay/`](../diagnostics-relay). It is separate from the website Worker.

## What it accepts

| Request | Body | Limit |
| --- | --- | --- |
| `POST /v1/reports/playback` | The latest playback record, exactly as the app shows it | 128 KB |
| `POST /v1/reports/problems` | Problem reports (crashes, freezes, failures, app errors), as exported | 2.5 MB, up to 50 reports |

The body must be `application/json` and match the app's format: known fields only, a supported format version, short printable app details, `VD-` issue IDs and known report kinds. Anything else gets `400`. A successful send returns `200` with `{"reference":"VR-7K2M9Q"}`. The reference is random and different from the `VD-` issue IDs, which identify the problem rather than the send.

| Response | Meaning | What the app should do |
| --- | --- | --- |
| `200` | Stored, emailed, or both | Show Sent with the reference |
| `400`, `404`, `405`, `413`, `415` | Not a valid report | Show an error; retrying won't help |
| `429` | More than 5 sends a minute from one address | Retry after `Retry-After` seconds |
| `503` | Daily limit of 300 reached, or storage and email both failed | Retry later |

> [!NOTE]
> The client address is used only as the rate-limit key. It isn't stored, emailed or logged, and Workers observability is off.

## Email

Mail is sent through [Resend](https://resend.com) to `diagnostics@vividapp.co` only; the address is fixed in `worker.mjs`. It comes from `reports@diagnostics.vividapp.co`, so Resend's DNS records sit under the `diagnostics.vividapp.co` subdomain and the root domain's records, which deliver mail to iCloud+, are left alone. Set `RESEND_FROM` to use another verified sender. The subject carries the reference and a short summary, for example `Playback report VR-7K2M9Q · tvOS 26.0 · AppleTV14,1 · HDMI · 8 ch · 412 dropped frames`, and the report is attached as JSON. Replies can't reach the person who sent it; ask them for the reference instead.

> [!WARNING]
> Never enable Cloudflare Email Routing for vividapp.co. It replaces the root MX records and takes incoming mail away from iCloud+.

## Setup

Run these from `diagnostics-relay/` with Wrangler logged in to the account that holds vividapp.co.

1. In Resend, add the domain `diagnostics.vividapp.co` and add the records it lists (Resend can add them to Cloudflare for you). Wait until it shows as verified.
2. Store the Resend API key as a secret. Wrangler asks for the key; paste it there, never into a file or chat:
   ```sh
   npx wrangler secret put RESEND_API_KEY
   ```
3. The KV namespace `vivid-diagnostics` already exists and its ID is in `wrangler.jsonc`. Each copy is stored with a 30-day expiry, so nothing needs cleaning up. To recreate it on another account, run `npx wrangler kv namespace create vivid-diagnostics` and update the ID.
4. Deploy. This also creates the `diagnostics.vividapp.co` custom domain:
   ```sh
   npx wrangler deploy
   ```
5. Send a sample report, then check that the email actually arrived in the iCloud inbox. A `200` alone isn't proof: the relay also answers `200` when only the stored copy succeeded. Stored copies can be listed with `npx wrangler kv key list --binding REPORTS --remote --prefix reports/`.
   ```sh
   curl -sS -X POST https://diagnostics.vividapp.co/v1/reports/playback -H 'Content-Type: application/json' --data-binary @fixtures/playback.json
   ```
6. Check the root mail records haven't changed: `dig +short MX vividapp.co` should still list `mx01.mail.icloud.com` and `mx02.mail.icloud.com`.

The app's Send button must only ship after the relay is live and the privacy text describes it.

## Tests

```sh
npm run test:relay
```

The tests use the sample reports in `diagnostics-relay/fixtures/` and cover acceptance, validation, size limits, rate and daily limits, partial failures, reference format and subject safety. `npx wrangler deploy --dry-run` checks the configuration without deploying.
