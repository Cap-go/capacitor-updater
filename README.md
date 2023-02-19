# Capacitor updater
  <a href="https://capgo.app/"><img src='https://raw.githubusercontent.com/Cap-go/capgo/main/assets/capgo_banner.png' alt='Capgo - Instant updates for capacitor'/></a>
[![Discord](https://badgen.net/badge/icon/discord?icon=discord&label)](https://discord.com/invite/VnYRvBfgA6)
<a href="https://discord.com/invite/VnYRvBfgA6"><img src="https://img.shields.io/discord/912707985829163099?color=%237289DA&label=Discord" alt="Discord">
![npm](https://img.shields.io/npm/dm/@capgo/capacitor-updater)
[![GitHub latest commit](https://badgen.net/github/last-commit/Cap-go/capacitor-updater/main)](https://GitHub.com/Cap-go/capacitor-updater/commit/)
[![https://good-labs.github.io/greater-good-affirmation/assets/images/badge.svg](https://good-labs.github.io/greater-good-affirmation/assets/images/badge.svg)](https://good-labs.github.io/greater-good-affirmation)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=bugs)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Technical Debt](https://sonarcloud.io/api/project_badges/measure?project=Cap-go_capacitor-updater&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=Cap-go_capacitor-updater)
[![Open Bounties](https://img.shields.io/endpoint?url=https%3A%2F%2Fconsole.algora.io%2Fapi%2Fshields%2FCapgo%2Fbounties%3Fstatus%3Dopen)](https://console.algora.io/org/Capgo/bounties?status=open)
[![Rewarded Bounties](https://img.shields.io/endpoint?url=https%3A%2F%2Fconsole.algora.io%2Fapi%2Fshields%2FCapgo%2Fbounties%3Fstatus%3Dcompleted)](https://console.algora.io/org/Capgo/bounties?status=completed)

Update Ionic Capacitor apps without App/Play Store review (Code-push / hot-code updates).

You have 3 ways possible :
- Use [capgo.app](https://capgo.app) a full featured auto update system in 5 min Setup, to manage version, update, revert and see stats.
- Use your own server update with auto update system
- Use manual methods to zip, upload, download, from JS to do it when you want.


## Community
Join the [discord](https://discord.gg/VnYRvBfgA6) to get help.

## Documentation
I maintain a more user friendly and complete [documentation here](https://docs.capgo.app/).

## Installation

```bash
npm install @capgo/capacitor-updater
npx cap sync
```

## Auto-update setup

Create account in [capgo.app](https://capgo.app) and get your [API key](https://capgo.app/app/apikeys)
- Login to CLI `npx @capgo/cli@latest  login API_KEY`
- Add app with CLI `npx @capgo/cli@latest add`
- Upload app to channel production `npx @capgo/cli@latest  upload -c production`
- Set channel production public `npx @capgo/cli@latest  set -c production -s public`
- Add to your main code
```javascript
  import { CapacitorUpdater } from '@capgo/capacitor-updater'
  CapacitorUpdater.notifyAppReady()
```
This tells Capacitor Updator that the current update bundle has loaded succesfully. Failing to call this method will cause your application to be rolled back to the previously successful version (or built-in bundle).

- Do `npm run build && npx cap copy` to copy the build to capacitor.
- Run the app and see app auto update after each backgrounding.
- Failed updates will automatically roll back to the last successful version.

See more there in the [Auto update](
https://github.com/Cap-go/capacitor-updater/wiki) documentation.


## Manual setup

Download update distribution zipfiles from a custom url. Manually control the entire update process.

- Edit your `capacitor.config.json` like below, set `autoUpdate` to true.
```json
// capacitor.config.json
{
	"appId": "**.***.**",
	"appName": "Name",
	"plugins": {
		"CapacitorUpdater": {
			"autoUpdate": false,
		}
	}
}
```
- Add to your main code
```javascript
  import { CapacitorUpdater } from '@capgo/capacitor-updater'
  CapacitorUpdater.notifyAppReady()
```
This informs Capacitor Updator that the current update bundle has loaded succesfully. Failing to call this method will cause your application to be rolled back to the previously successful version (or built-in bundle).
- Add this to your application.
```javascript
  const version = await CapacitorUpdater.download({
    url: 'https://github.com/Cap-go/demo-app/releases/download/0.0.4/dist.zip',
  })
  await CapacitorUpdater.set(version); // sets the new version, and reloads the app
```
- Failed updates will automatically roll back to the last successful version.
- Example: Using App-state to control updates, with SplashScreen:
You might also consider performing auto-update when application state changes, and using the Splash Screen to improve user experience.
```javascript
  import { CapacitorUpdater, VersionInfo } from '@capgo/capacitor-updater'
  import { SplashScreen } from '@capacitor/splash-screen'
  import { App } from '@capacitor/app'

  let version: VersionInfo;
  App.addListener('appStateChange', async (state) => {
      if (state.isActive) {
        // Ensure download occurs while the app is active, or download may fail
        version = await CapacitorUpdater.download({
          url: 'https://github.com/Cap-go/demo-app/releases/download/0.0.4/dist.zip',
        })
      }

      if (!state.isActive && version) {
        // Activate the update when the application is sent to background
        SplashScreen.show()
        try {
          await CapacitorUpdater.set(version);
          // At this point, the new version should be active, and will need to hide the splash screen
        } catch () {
          SplashScreen.hide() // Hide the splash screen again if something went wrong
        }
      }
  })

```

TIP: If you prefer a secure and automated way to update your app, you can use [capgo.app](https://capgo.app) - a full-featured, auto update system.

### Packaging `dist.zip` update bundles

Capacitor Updator works by unzipping a compiled app bundle to the native device filesystem. Whatever you choose to name the file you upload/download from your release/update server URL (via either manual or automatic updating), this `.zip` bundle must meet the following requirements:

- The zip file should contain the full contents of your production Capacitor build output folder, usually `{project directory}/dist/` or `{project directory}/www/`. This is where `index.html` will be located, and it should also contain all bundled JavaScript, CSS, and web resources necessary for your app to run.
- Do not password encrypt the bundle zip file, or it will fail to unpack.
- Make sure the bundle does not contain any extra hidden files or folders, or it may fail to unpack.

## API

<docgen-index>

* [`notifyAppReady()`](#notifyappready)
* [`download(...)`](#download)
* [`next(...)`](#next)
* [`set(...)`](#set)
* [`delete(...)`](#delete)
* [`list()`](#list)
* [`reset(...)`](#reset)
* [`current()`](#current)
* [`reload()`](#reload)
* [`setMultiDelay(...)`](#setmultidelay)
* [`setDelay(...)`](#setdelay)
* [`cancelDelay()`](#canceldelay)
* [`getLatest()`](#getlatest)
* [`setChannel(...)`](#setchannel)
* [`getChannel()`](#getchannel)
* [`setCustomId(...)`](#setcustomid)
* [`addListener('download', ...)`](#addlistenerdownload)
* [`addListener('noNeedUpdate', ...)`](#addlistenernoneedupdate)
* [`addListener('updateAvailable', ...)`](#addlistenerupdateavailable)
* [`addListener('downloadComplete', ...)`](#addlistenerdownloadcomplete)
* [`addListener('majorAvailable', ...)`](#addlistenermajoravailable)
* [`addListener('updateFailed', ...)`](#addlistenerupdatefailed)
* [`addListener('downloadFailed', ...)`](#addlistenerdownloadfailed)
* [`addListener('appReloaded', ...)`](#addlistenerappreloaded)
* [`getDeviceId()`](#getdeviceid)
* [`getPluginVersion()`](#getpluginversion)
* [`isAutoUpdateEnabled()`](#isautoupdateenabled)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### notifyAppReady()

```typescript
notifyAppReady() => Promise<BundleInfo>
```

Notify Capacitor Updater that the current bundle is working (a rollback will occur of this method is not called on every app launch)

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


### download(...)

```typescript
download(options: { url: string; version: string; sessionKey?: string; checksum?: string; }) => Promise<BundleInfo>
```

Download a new bundle from the provided URL, it should be a zip file, with files inside or with a unique id inside with all your files

| Param         | Type                                                                                   |
| ------------- | -------------------------------------------------------------------------------------- |
| **`options`** | <code>{ url: string; version: string; sessionKey?: string; checksum?: string; }</code> |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


### next(...)

```typescript
next(options: { id: string; }) => Promise<BundleInfo>
```

Set the next bundle to be used when the app is reloaded.

| Param         | Type                         |
| ------------- | ---------------------------- |
| **`options`** | <code>{ id: string; }</code> |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


### set(...)

```typescript
set(options: { id: string; }) => Promise<void>
```

Set the current bundle and immediately reloads the app.

| Param         | Type                         |
| ------------- | ---------------------------- |
| **`options`** | <code>{ id: string; }</code> |

--------------------


### delete(...)

```typescript
delete(options: { id: string; }) => Promise<void>
```

Delete bundle in storage

| Param         | Type                         |
| ------------- | ---------------------------- |
| **`options`** | <code>{ id: string; }</code> |

--------------------


### list()

```typescript
list() => Promise<{ bundles: BundleInfo[]; }>
```

Get all available bundles

**Returns:** <code>Promise&lt;{ bundles: BundleInfo[]; }&gt;</code>

--------------------


### reset(...)

```typescript
reset(options?: { toLastSuccessful?: boolean | undefined; } | undefined) => Promise<void>
```

Set the `builtin` bundle (the one sent to Apple store / Google play store ) as current bundle

| Param         | Type                                         |
| ------------- | -------------------------------------------- |
| **`options`** | <code>{ toLastSuccessful?: boolean; }</code> |

--------------------


### current()

```typescript
current() => Promise<{ bundle: BundleInfo; native: string; }>
```

Get the current bundle, if none are set it returns `builtin`, currentNative is the original bundle installed on the device

**Returns:** <code>Promise&lt;{ bundle: <a href="#bundleinfo">BundleInfo</a>; native: string; }&gt;</code>

--------------------


### reload()

```typescript
reload() => Promise<void>
```

Reload the view

--------------------


### setMultiDelay(...)

```typescript
setMultiDelay(options: { delayConditions: DelayCondition[]; }) => Promise<void>
```

Set <a href="#delaycondition">DelayCondition</a>, skip updates until one of the conditions is met

| Param         | Type                                                | Description                                                              |
| ------------- | --------------------------------------------------- | ------------------------------------------------------------------------ |
| **`options`** | <code>{ delayConditions: DelayCondition[]; }</code> | are the {@link <a href="#delaycondition">DelayCondition</a>} list to set |

**Since:** 4.3.0

--------------------


### setDelay(...)

```typescript
setDelay(options: DelayCondition) => Promise<void>
```

Set <a href="#delaycondition">DelayCondition</a>, skip updates until the condition is met

| Param         | Type                                                      | Description                                                        |
| ------------- | --------------------------------------------------------- | ------------------------------------------------------------------ |
| **`options`** | <code><a href="#delaycondition">DelayCondition</a></code> | is the {@link <a href="#delaycondition">DelayCondition</a>} to set |

**Since:** 4.0.0

--------------------


### cancelDelay()

```typescript
cancelDelay() => Promise<void>
```

Cancel delay to updates as usual

**Since:** 4.0.0

--------------------


### getLatest()

```typescript
getLatest() => Promise<LatestVersion>
```

Get Latest bundle available from update Url

**Returns:** <code>Promise&lt;<a href="#latestversion">LatestVersion</a>&gt;</code>

**Since:** 4.0.0

--------------------


### setChannel(...)

```typescript
setChannel(options: SetChannelOptions) => Promise<ChannelRes>
```

Set Channel for this device

| Param         | Type                                                            | Description                                                                      |
| ------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setchanneloptions">SetChannelOptions</a></code> | is the {@link <a href="#setchanneloptions">SetChannelOptions</a>} channel to set |

**Returns:** <code>Promise&lt;<a href="#channelres">ChannelRes</a>&gt;</code>

**Since:** 4.7.0

--------------------


### getChannel()

```typescript
getChannel() => Promise<GetChannelRes>
```

get Channel for this device

**Returns:** <code>Promise&lt;<a href="#getchannelres">GetChannelRes</a>&gt;</code>

**Since:** 4.8.0

--------------------


### setCustomId(...)

```typescript
setCustomId(options: SetCustomIdOptions) => Promise<void>
```

Set Channel for this device

| Param         | Type                                                              | Description                                                                         |
| ------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setcustomidoptions">SetCustomIdOptions</a></code> | is the {@link <a href="#setcustomidoptions">SetCustomIdOptions</a>} customId to set |

**Since:** 4.9.0

--------------------


### addListener('download', ...)

```typescript
addListener(eventName: "download", listenerFunc: DownloadChangeListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for download event in the App, let you know when the download is started, loading and finished

| Param              | Type                                                                      |
| ------------------ | ------------------------------------------------------------------------- |
| **`eventName`**    | <code>'download'</code>                                                   |
| **`listenerFunc`** | <code><a href="#downloadchangelistener">DownloadChangeListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 2.0.11

--------------------


### addListener('noNeedUpdate', ...)

```typescript
addListener(eventName: "noNeedUpdate", listenerFunc: NoNeedListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for no need to update event, usefull when you want force check every time the app is launched

| Param              | Type                                                      |
| ------------------ | --------------------------------------------------------- |
| **`eventName`**    | <code>'noNeedUpdate'</code>                               |
| **`listenerFunc`** | <code><a href="#noneedlistener">NoNeedListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 4.0.0

--------------------


### addListener('updateAvailable', ...)

```typescript
addListener(eventName: "updateAvailable", listenerFunc: UpdateAvailabledListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for availbale update event, usefull when you want to force check every time the app is launched

| Param              | Type                                                                          |
| ------------------ | ----------------------------------------------------------------------------- |
| **`eventName`**    | <code>'updateAvailable'</code>                                                |
| **`listenerFunc`** | <code><a href="#updateavailabledlistener">UpdateAvailabledListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 4.0.0

--------------------


### addListener('downloadComplete', ...)

```typescript
addListener(eventName: "downloadComplete", listenerFunc: DownloadCompleteListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for download event in the App, let you know when the download is started, loading and finished

| Param              | Type                                                                          |
| ------------------ | ----------------------------------------------------------------------------- |
| **`eventName`**    | <code>'downloadComplete'</code>                                               |
| **`listenerFunc`** | <code><a href="#downloadcompletelistener">DownloadCompleteListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 4.0.0

--------------------


### addListener('majorAvailable', ...)

```typescript
addListener(eventName: "majorAvailable", listenerFunc: MajorAvailableListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for Major update event in the App, let you know when major update is blocked by setting disableAutoUpdateBreaking

| Param              | Type                                                                      |
| ------------------ | ------------------------------------------------------------------------- |
| **`eventName`**    | <code>'majorAvailable'</code>                                             |
| **`listenerFunc`** | <code><a href="#majoravailablelistener">MajorAvailableListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 2.3.0

--------------------


### addListener('updateFailed', ...)

```typescript
addListener(eventName: "updateFailed", listenerFunc: UpdateFailedListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for update fail event in the App, let you know when update has fail to install at next app start

| Param              | Type                                                                  |
| ------------------ | --------------------------------------------------------------------- |
| **`eventName`**    | <code>'updateFailed'</code>                                           |
| **`listenerFunc`** | <code><a href="#updatefailedlistener">UpdateFailedListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 2.3.0

--------------------


### addListener('downloadFailed', ...)

```typescript
addListener(eventName: "downloadFailed", listenerFunc: DownloadFailedListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for download fail event in the App, let you know when download has fail finished

| Param              | Type                                                                      |
| ------------------ | ------------------------------------------------------------------------- |
| **`eventName`**    | <code>'downloadFailed'</code>                                             |
| **`listenerFunc`** | <code><a href="#downloadfailedlistener">DownloadFailedListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 4.0.0

--------------------


### addListener('appReloaded', ...)

```typescript
addListener(eventName: "appReloaded", listenerFunc: AppReloadedListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for download fail event in the App, let you know when download has fail finished

| Param              | Type                                                                |
| ------------------ | ------------------------------------------------------------------- |
| **`eventName`**    | <code>'appReloaded'</code>                                          |
| **`listenerFunc`** | <code><a href="#appreloadedlistener">AppReloadedListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 4.3.0

--------------------


### getDeviceId()

```typescript
getDeviceId() => Promise<{ deviceId: string; }>
```

Get unique ID used to identify device (sent to auto update server)

**Returns:** <code>Promise&lt;{ deviceId: string; }&gt;</code>

--------------------


### getPluginVersion()

```typescript
getPluginVersion() => Promise<{ version: string; }>
```

Get the native Capacitor Updater plugin version (sent to auto update server)

**Returns:** <code>Promise&lt;{ version: string; }&gt;</code>

--------------------


### isAutoUpdateEnabled()

```typescript
isAutoUpdateEnabled() => Promise<{ enabled: boolean; }>
```

Get the state of auto update config. This will return `false` in manual mode.

**Returns:** <code>Promise&lt;{ enabled: boolean; }&gt;</code>

--------------------


### Interfaces


#### BundleInfo

| Prop             | Type                                                  |
| ---------------- | ----------------------------------------------------- |
| **`id`**         | <code>string</code>                                   |
| **`version`**    | <code>string</code>                                   |
| **`downloaded`** | <code>string</code>                                   |
| **`checksum`**   | <code>string</code>                                   |
| **`status`**     | <code><a href="#bundlestatus">BundleStatus</a></code> |


#### DelayCondition

| Prop        | Type                                                      | Description                              |
| ----------- | --------------------------------------------------------- | ---------------------------------------- |
| **`kind`**  | <code><a href="#delayuntilnext">DelayUntilNext</a></code> | Set up delay conditions in setMultiDelay |
| **`value`** | <code>string</code>                                       |                                          |


#### LatestVersion

| Prop          | Type                 | Description             | Since |
| ------------- | -------------------- | ----------------------- | ----- |
| **`version`** | <code>string</code>  | Res of getLatest method | 4.0.0 |
| **`major`**   | <code>boolean</code> |                         |       |
| **`message`** | <code>string</code>  |                         |       |
| **`error`**   | <code>string</code>  |                         |       |
| **`old`**     | <code>string</code>  |                         |       |
| **`url`**     | <code>string</code>  |                         |       |


#### ChannelRes

| Prop          | Type                | Description                   | Since |
| ------------- | ------------------- | ----------------------------- | ----- |
| **`status`**  | <code>string</code> | Current status of set channel | 4.7.0 |
| **`error`**   | <code>any</code>    |                               |       |
| **`message`** | <code>any</code>    |                               |       |


#### SetChannelOptions

| Prop          | Type                |
| ------------- | ------------------- |
| **`channel`** | <code>string</code> |


#### GetChannelRes

| Prop           | Type                 | Description                   | Since |
| -------------- | -------------------- | ----------------------------- | ----- |
| **`channel`**  | <code>string</code>  | Current status of get channel | 4.8.0 |
| **`error`**    | <code>any</code>     |                               |       |
| **`message`**  | <code>any</code>     |                               |       |
| **`status`**   | <code>string</code>  |                               |       |
| **`allowSet`** | <code>boolean</code> |                               |       |


#### SetCustomIdOptions

| Prop           | Type                |
| -------------- | ------------------- |
| **`customId`** | <code>string</code> |


#### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


#### DownloadEvent

| Prop          | Type                                              | Description                                    | Since |
| ------------- | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`percent`** | <code>number</code>                               | Current status of download, between 0 and 100. | 4.0.0 |
| **`bundle`**  | <code><a href="#bundleinfo">BundleInfo</a></code> |                                                |       |


#### NoNeedEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


#### UpdateAvailableEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


#### DownloadCompleteEvent

| Prop         | Type                                              | Description                          | Since |
| ------------ | ------------------------------------------------- | ------------------------------------ | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a new update is available. | 4.0.0 |


#### MajorAvailableEvent

| Prop          | Type                | Description                                | Since |
| ------------- | ------------------- | ------------------------------------------ | ----- |
| **`version`** | <code>string</code> | Emit when a new major bundle is available. | 4.0.0 |


#### UpdateFailedEvent

| Prop         | Type                                              | Description                           | Since |
| ------------ | ------------------------------------------------- | ------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a update failed to install. | 4.0.0 |


#### DownloadFailedEvent

| Prop          | Type                | Description                | Since |
| ------------- | ------------------- | -------------------------- | ----- |
| **`version`** | <code>string</code> | Emit when a download fail. | 4.0.0 |


### Type Aliases


#### BundleStatus

<code>"success" | "error" | "pending" | "downloading"</code>


#### DelayUntilNext

<code>"background" | "kill" | "nativeVersion" | "date"</code>


#### DownloadChangeListener

<code>(state: <a href="#downloadevent">DownloadEvent</a>): void</code>


#### NoNeedListener

<code>(state: <a href="#noneedevent">NoNeedEvent</a>): void</code>


#### UpdateAvailabledListener

<code>(state: <a href="#updateavailableevent">UpdateAvailableEvent</a>): void</code>


#### DownloadCompleteListener

<code>(state: <a href="#downloadcompleteevent">DownloadCompleteEvent</a>): void</code>


#### MajorAvailableListener

<code>(state: <a href="#majoravailableevent">MajorAvailableEvent</a>): void</code>


#### UpdateFailedListener

<code>(state: <a href="#updatefailedevent">UpdateFailedEvent</a>): void</code>


#### DownloadFailedListener

<code>(state: <a href="#downloadfailedevent">DownloadFailedEvent</a>): void</code>


#### AppReloadedListener

<code>(state: void): void</code>

</docgen-api>

### Listen to download events

```javascript
  import { CapacitorUpdater } from '@capgo/capacitor-updater';

CapacitorUpdater.addListener('download', (info: any) => {
  console.log('download was fired', info.percent);
});
```

On iOS, Apple don't allow you to show a message when the app is updated, so you can't show a progress bar.

### Inspiration

- [cordova-plugin-ionic](https://github.com/ionic-team/cordova-plugin-ionic)
- [capacitor-codepush](https://github.dev/mapiacompany/capacitor-codepush)


### Contributors

[jamesyoung1337](https://github.com/jamesyoung1337) Thanks a lot for your guidance and support, it was impossible to make this plugin work without you.
