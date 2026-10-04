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

Receiving mail stays with iCloud+. Email Sending puts its records on `cf-bounce.vividapp.co` and `cf-bounce._domainkey.vividapp.co` and leaves the root MX and SPF records alone. It also adds a DMARC record at `_dmarc.vividapp.co`, which the domain doesn't have today; check its policy before enabling, because DMARC applies to iCloud mail sent from the domain too.

## Setup

Each step changes the Cloudflare account and needs blurbery's go-ahead. Run them from `diagnostics-relay/` with Wrangler logged in to the account that holds vividapp.co.

1. Onboard the domain for sending and check the records:
   ```sh
   npx wrangler email sending enable vividapp.co
   npx wrangler email sending dns get vividapp.co
   ```
2. Verify `diagnostics@vividapp.co` as a destination address in the Cloudflare dashboard (Email → Destination addresses) and confirm the link it sends to the inbox. Sending to a verified address is free on every Workers plan; sending to other addresses would need Workers Paid, and the binding doesn't allow it anyway.
3. Create the bucket and its 30-day expiry:
   ```sh
   npx wrangler r2 bucket create vivid-diagnostics
   npx wrangler r2 bucket lifecycle add vivid-diagnostics expire-reports reports/ --expire-days 30
   ```
4. Deploy. This also creates the `diagnostics.vividapp.co` custom domain:
   ```sh
   npx wrangler deploy
   ```
5. Send the sample reports and check the inbox:
   ```sh
   curl -sS -X POST https://diagnostics.vividapp.co/v1/reports/playback -H 'Content-Type: application/json' --data-binary @fixtures/playback.json
   ```

The app's Send button must only ship after the relay is live and the privacy text describes it.

## Tests

```sh
npm run test:relay
```

The tests use the sample reports in `diagnostics-relay/fixtures/` and cover acceptance, validation, size limits, rate and daily limits, partial failures, reference format and subject safety. `npx wrangler deploy --dry-run` checks the configuration without deploying.
