# Local Development Setup

This guide explains how to run the `capacitor-updater` project locally, including the updated Supabase database migration steps that reflect recent Supabase CLI changes.

---

## Prerequisites

Before you begin, make sure you have the following installed:

- [Node.js](https://nodejs.org/) >= 18
- [Bun](https://bun.sh/) >= 1.0 (used as the package manager)
- [Docker](https://www.docker.com/) and Docker Compose v2+
- [Supabase CLI](https://supabase.com/docs/guides/cli) >= 1.100.0
- [Xcode](https://developer.apple.com/xcode/) (macOS only, for iOS builds)
- [Android Studio](https://developer.android.com/studio) (for Android builds)

---

## Step 1 — Clone the Repository

```bash
git clone https://github.com/Cap-go/capacitor-updater.git
cd capacitor-updater
```

---

## Step 2 — Install Dependencies

```bash
bun install
```

---

## Step 3 — Start Supabase Locally

The project uses Supabase for its backend. Recent Supabase CLI versions changed how migrations are applied, so follow these steps carefully.

### 3a — Start the Supabase stack

```bash
supabase start
```

This command starts Postgres, Auth, Storage, and the Supabase Studio dashboard locally using Docker. On first run it may take a few minutes to pull images.

Once started, the CLI prints your local credentials:

```
API URL: http://localhost:54321
DB URL: postgresql://postgres:postgres@localhost:54322/postgres
Studio URL: http://localhost:54323
Anon Key: <your-anon-key>
Service Role Key: <your-service-role-key>
```

Copy the **Anon Key** and **Service Role Key** — you will need them in Step 4.

### 3b — Apply database migrations

> **Important:** Recent versions of Supabase CLI deprecated `supabase db reset` for local migration replay. Use `db push` instead:

```bash
supabase db push
```

This applies all pending migrations from `supabase/migrations/` to your local database in order.

If you see an error like `relation already exists`, your local database may be out of sync. Reset it cleanly with:

```bash
supabase db reset
```

Then re-run `supabase db push`.

### 3c — Verify the database

Open Supabase Studio at `http://localhost:54323` and confirm the following tables exist under the `public` schema:

- `apps`
- `channels`
- `channel_devices`
- `devices`
- `bundles` (may appear as `app_versions` in older migrations)
- `stats`

If any tables are missing, check that all migration files in `supabase/migrations/` are present and re-run `supabase db push`.

---

## Step 4 — Configure Environment Variables

Create a `.env` file at the project root:

```bash
cp .env.example .env
```

Open `.env` and fill in the values from Step 3a:

```env
SUPABASE_URL=http://localhost:54321
SUPABASE_ANON_KEY=<your-anon-key>
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>

# For local S3 storage (optional — see Step 5)
S3_ENDPOINT=http://localhost:9000
S3_BUCKET=capgo
S3_ACCESS_KEY=minioadmin
S3_SECRET_KEY=minioadmin
```

---

## Step 5 — (Optional) Start Local S3 Storage

By default the project uses Supabase Storage. For a closer match to production, you can run MinIO locally:

```bash
docker run -d \
  --name minio \
  -p 9000:9000 \
  -p 9001:9001 \
  -e MINIO_ROOT_USER=minioadmin \
  -e MINIO_ROOT_PASSWORD=minioadmin \
  minio/minio server /data --console-address ":9001"
```

Create the bucket:

```bash
# Install mc (MinIO Client) if needed: https://min.io/docs/minio/linux/reference/minio-mc.html
mc alias set local http://localhost:9000 minioadmin minioadmin
mc mb local/capgo
mc anonymous set download local/capgo
```

---

## Step 6 — Run Edge Functions Locally

Capgo's update logic runs as Supabase Edge Functions. Start them locally with:

```bash
supabase functions serve --env-file .env
```

Functions are available at `http://localhost:54321/functions/v1/`.

---

## Step 7 — Run the Plugin in a Local Capacitor App

To test the plugin against your local backend:

### 7a — Link the plugin locally

In your test Capacitor app:

```bash
npm install /path/to/capacitor-updater
npx cap sync
```

### 7b — Configure the plugin

In `capacitor.config.ts`:

```typescript
import { CapacitorConfig } from "@capacitor/cli"

const config: CapacitorConfig = {
  appId: "com.example.test",
  appName: "Test App",
  plugins: {
    CapacitorUpdater: {
      localS3: true,
      localSupa: "http://YOUR_LAN_IP:54321",
      localSupaAnon: "<your-anon-key>",
      updateUrl: "http://YOUR_LAN_IP:54321/functions/v1/updates",
      statsUrl: "http://YOUR_LAN_IP:54321/functions/v1/stats",
      channelUrl: "http://YOUR_LAN_IP:54321/functions/v1/channel_self",
    },
  },
}

export default config
```

> **Tip:** Replace `YOUR_LAN_IP` with your machine's local network IP (e.g. `192.168.1.10`). Simulators and physical devices cannot reach `localhost` on your host machine.

---

## Troubleshooting

**`supabase start` fails with port conflict**

Another process is using port 54321 or 54322. Stop any running Supabase instances:

```bash
supabase stop --no-backup
supabase start
```

**Migration errors: `relation already exists`**

Your local DB has a partial migration state. Reset cleanly:

```bash
supabase db reset
supabase db push
```

**Edge functions return 401 Unauthorized**

Make sure your `SUPABASE_ANON_KEY` in `.env` matches the key printed by `supabase start`. Keys change each time you run `supabase stop --no-backup && supabase start`.

**Plugin can't reach local Supabase from device/simulator**

Use your LAN IP instead of `localhost` in `capacitor.config.ts`. Find your LAN IP:

```bash
# macOS
ipconfig getifaddr en0

# Linux
hostname -I | awk '{print $1}'
```

**`bun install` fails on native modules**

Make sure you have Xcode Command Line Tools installed (macOS):

```bash
xcode-select --install
```

---

## Running Tests

```bash
# Unit tests
bun test

# E2E tests (requires a running Supabase stack)
bun run test:e2e
```

---

## Useful Commands

| Command | Description |
|---------|-------------|
| `supabase start` | Start the local Supabase stack |
| `supabase stop` | Stop the local Supabase stack |
| `supabase db push` | Apply pending migrations |
| `supabase db reset` | Wipe and re-apply all migrations |
| `supabase functions serve --env-file .env` | Serve edge functions locally |
| `bun test` | Run the test suite |
| `bun run build` | Build the plugin |
