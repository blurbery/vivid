<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Diagnostics Relay</h1>
<p align="center">How reports sent from Vivid reach the diagnostics inbox.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Apple TV has no Mail app, and an app can't safely hold an email login. So when someone presses Send in Settings → Diagnostics, Vivid posts the report to a small Cloudflare Worker at `diagnostics.vividapp.co`. The Worker keeps a copy for 30 days and emails it to `diagnostics@vividapp.co`, which is delivered to the iCloud Mail inbox like any other mail to the domain.

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

Mail is sent with Cloudflare Email Service through a `send_email` binding that can only send to `diagnostics@vividapp.co`. The subject carries the reference and a short summary, for example `Playback report VR-7K2M9Q · tvOS 26.0 · AppleTV14,1 · HDMI · 8 ch · 412 dropped frames`, and the report is attached as JSON. Replies can't reach the person who sent it; ask them for the reference instead.

Mail is sent from `reports@diagnostics.vividapp.co`, and Email Sending is enabled for the `diagnostics.vividapp.co` subdomain only. Its bounce, SPF, DKIM and DMARC records then all sit under that subdomain, and the root domain's records, which deliver mail to iCloud+, are left alone. Email Routing stays off for vividapp.co.

> [!WARNING]
> Never enable Email Routing for vividapp.co. It replaces the root MX records and takes incoming mail away from iCloud+.

## Setup

Each step changes the Cloudflare account and needs blurbery's go-ahead. Run them from `diagnostics-relay/` with Wrangler logged in to the account that holds vividapp.co.

1. Record the root domain's mail records, so you can confirm afterwards that nothing changed:
   ```sh
   dig +short MX vividapp.co; dig +short TXT vividapp.co; dig +short TXT _dmarc.vividapp.co
   ```
2. Enable sending for the subdomain only, and check its records:
   ```sh
   npx wrangler email sending enable diagnostics.vividapp.co
   npx wrangler email sending dns get diagnostics.vividapp.co
   ```
3. Verify `diagnostics@vividapp.co` as a destination address (Cloudflare dashboard, Email, Destination addresses) and confirm the link it sends to the inbox. On the free Workers plan, Email Sending can only send to verified addresses; Workers Paid can send anywhere, but the binding only allows this one address anyway. If Cloudflare asks to turn on Email Routing to verify the address, stop: see the warning above.
4. Create the bucket and its 30-day expiry:
   ```sh
   npx wrangler r2 bucket create vivid-diagnostics
   npx wrangler r2 bucket lifecycle add vivid-diagnostics expire-reports reports/ --expire-days 30
   ```
5. Deploy. This also creates the `diagnostics.vividapp.co` custom domain:
   ```sh
   npx wrangler deploy
   ```
6. Send a sample report, then check that the email actually arrived in the iCloud inbox. A `200` alone isn't proof: the relay also answers `200` when only the stored copy succeeded.
   ```sh
   curl -sS -X POST https://diagnostics.vividapp.co/v1/reports/playback -H 'Content-Type: application/json' --data-binary @fixtures/playback.json
   ```
7. Run the `dig` commands from step 1 again and check the root records are unchanged.

The app's Send button must only ship after the relay is live and the privacy text describes it.

## Tests

```sh
npm run test:relay
```

The tests use the sample reports in `diagnostics-relay/fixtures/` and cover acceptance, validation, size limits, rate and daily limits, partial failures, reference format and subject safety. `npx wrangler deploy --dry-run` checks the configuration without deploying.
