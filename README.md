# Capacitor updater
  <a href="https://capgo.app/"><img src='https://raw.githubusercontent.com/Cap-go/capgo/main/assets/capgo_banner.png' alt='Capgo - Instant updates for capacitor'/></a>
[![Discord](https://badgen.net/badge/icon/discord?icon=discord&label)](https://discord.com/invite/VnYRvBfgA6)
<a href="https://discord.com/invite/VnYRvBfgA6"><img src="https://img.shields.io/discord/912707985829163099?color=%237289DA&label=Discord" alt="Discord">
[![npm](https://img.shields.io/npm/dm/@capgo/capacitor-updater)](https://www.npmjs.com/package/@capgo/capacitor-updater)
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

<h2><a href="https://capgo.app/consulting/">Hire a Capacitor consultant</a></h2>

Update Ionic Capacitor apps without App/Play Store review (Code-push / hot-code updates).

You have 3 ways possible :
- Use [capgo.app](https://capgo.app) a full featured auto update system in 5 min Setup, to manage version, update, revert and see stats.
- Use your own server update with auto update system
- Use manual methods to zip, upload, download, from JS to do it when you want.


## Community
Join the [discord](https://discord.gg/VnYRvBfgA6) to get help.

## Documentation
I maintain a more user friendly and complete [documentation here](https://capgo.app/docs/).

## Installation

```bash
npm install @capgo/capacitor-updater
npx cap sync
```

## Auto-update setup

Create your account in [capgo.app](https://capgo.app) and get your [API key](https://capgo.app/app/apikeys)
- Login to CLI `npx @capgo/cli@latest init API_KEY`
And follow the steps by step to setup your app.

See more there in the [Auto update documentation](https://capgo.app/docs/plugin/auto-update).


## Manual setup

Download update distribution zipfiles from a custom url. Manually control the entire update process.

- Edit your `capacitor.config.json` like below, set `autoUpdate` to false.
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

### Store Guideline Compliance

Android Google Play and iOS App Store have corresponding guidelines that have rules you should be aware of before integrating the Capacitor-updater solution within your application.

#### Google play

Third paragraph of [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en) topic describe that updating source code by any method other than Google Play's update mechanism is restricted. But this restriction does not apply to updating javascript bundles.
> This restriction does not apply to code that runs in a virtual machine and has limited access to Android APIs (such as JavaScript in a webview or browser).

That fully allow Capacitor-updater as it updates just JS bundles and can't update native code part.

#### App Store

Paragraph **3.3.2**, since back in 2015's [Apple Developer Program License Agreement](https://developer.apple.com/programs/ios/information/) fully allowed performing over-the-air updates of JavaScript and assets -  and in its latest version (20170605) [downloadable here](https://developer.apple.com/terms/) this ruling is even broader:

> Interpreted code may be downloaded to an Application but only so long as such code: (a) does not change the primary purpose of the Application by providing features or functionality that are inconsistent with the intended and advertised purpose of the Application as submitted to the App Store, (b) does not create a store or storefront for other code or applications, and (c) does not bypass signing, sandbox, or other security features of the OS.

Capacitor-updater allows you to follow these rules in full compliance so long as the update you push does not significantly deviate your product from its original App Store approved intent.

To further remain in compliance with Apple's guidelines we suggest that App Store-distributed apps don't enable the `Force update` scenario, since in the [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) it is written that:

> Apps must not force users to rate the app, review the app, download other apps, or other similar actions in order to access functionality, content, or use of the app.

This is not a problem for the default behavior of background update, since it won't force the user to apply the new version until next app close, but at least you should be aware of that ruling if you decide to show it.

### Packaging `dist.zip` update bundles

Capacitor Updator works by unzipping a compiled app bundle to the native device filesystem. Whatever you choose to name the file you upload/download from your release/update server URL (via either manual or automatic updating), this `.zip` bundle must meet the following requirements:

- The zip file should contain the full contents of your production Capacitor build output folder, usually `{project directory}/dist/` or `{project directory}/www/`. This is where `index.html` will be located, and it should also contain all bundled JavaScript, CSS, and web resources necessary for your app to run.
- Do not password encrypt the bundle zip file, or it will fail to unpack.
- Make sure the bundle does not contain any extra hidden files or folders, or it may fail to unpack.

## Updater Plugin Config

<docgen-config>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

CapacitorUpdater can be configured with this options:

| Prop                     | Type                 | Description                                                                                                                                                                                     | Default                                        | Since   |
| ------------------------ | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- | ------- |
| **`appReadyTimeout`**    | <code>number</code>  | Configure the number of milliseconds the native plugin should wait before considering an update 'failed'. Only available for Android and iOS.                                                   | <code>10000 // (10 seconds)</code>             |         |
| **`responseTimeout`**    | <code>number</code>  | Configure the number of milliseconds the native plugin should wait before considering API timeout. Only available for Android and iOS.                                                          | <code>20 // (20 second)</code>                 |         |
| **`autoDeleteFailed`**   | <code>boolean</code> | Configure whether the plugin should use automatically delete failed bundles. Only available for Android and iOS.                                                                                | <code>true</code>                              |         |
| **`autoDeletePrevious`** | <code>boolean</code> | Configure whether the plugin should use automatically delete previous bundles after a successful update. Only available for Android and iOS.                                                    | <code>true</code>                              |         |
| **`autoUpdate`**         | <code>boolean</code> | Configure whether the plugin should use Auto Update via an update server. Only available for Android and iOS.                                                                                   | <code>true</code>                              |         |
| **`resetWhenUpdate`**    | <code>boolean</code> | Automatically delete previous downloaded bundles when a newer native app bundle is installed to the device. Only available for Android and iOS.                                                 | <code>true</code>                              |         |
| **`updateUrl`**          | <code>string</code>  | Configure the URL / endpoint to which update checks are sent. Only available for Android and iOS.                                                                                               | <code>https://api.capgo.app/auto_update</code> |         |
| **`statsUrl`**           | <code>string</code>  | Configure the URL / endpoint to which update statistics are sent. Only available for Android and iOS. Set to "" to disable stats reporting.                                                     | <code>https://api.capgo.app/stats</code>       |         |
| **`privateKey`**         | <code>string</code>  | Configure the private key for end to end live update encryption. Only available for Android and iOS.                                                                                            | <code>undefined</code>                         |         |
| **`version`**            | <code>string</code>  | Configure the current version of the app. This will be used for the first update request. If not set, the plugin will get the version from the native code. Only available for Android and iOS. | <code>undefined</code>                         | 4.17.48 |
| **`directUpdate`**       | <code>boolean</code> | Make the plugin direct install the update when the app what just updated/installed. Only for autoUpdate mode. Only available for Android and iOS.                                               | <code>undefined</code>                         | 5.1.0   |
| **`periodCheckDelay`**   | <code>number</code>  | Configure the delay period for period update check. the unit is in seconds. Only available for Android and iOS. Cannot be less than 600 seconds (10 minutes).                                   | <code>600 // (10 minutes)</code>               |         |
| **`localS3`**            | <code>boolean</code> | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                               | <code>undefined</code>                         | 4.17.48 |
| **`localHost`**          | <code>string</code>  | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                               | <code>undefined</code>                         | 4.17.48 |
| **`localWebHost`**       | <code>string</code>  | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                               | <code>undefined</code>                         | 4.17.48 |
| **`localSupa`**          | <code>string</code>  | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                               | <code>undefined</code>                         | 4.17.48 |
| **`localSupaAnon`**      | <code>string</code>  | Configure the CLI to use a local server for testing.                                                                                                                                            | <code>undefined</code>                         | 4.17.48 |
| **`allowModifyUrl`**     | <code>boolean</code> | Allow the plugin to modify the updateUrl, statsUrl and channelUrl dynamically from the JavaScript side.                                                                                         | <code>false</code>                             | 5.4.0   |
| **`defaultChannel`**     | <code>string</code>  | Set the default channel for the app in the config.                                                                                                                                              | <code>undefined</code>                         | 5.5.0   |

### Examples

In `capacitor.config.json`:

```json
{
  "plugins": {
    "CapacitorUpdater": {
      "appReadyTimeout": 1000, // (1 second)
      "responseTimeout": 10, // (10 second)
      "autoDeleteFailed": false,
      "autoDeletePrevious": false,
      "autoUpdate": false,
      "resetWhenUpdate": false,
      "updateUrl": https://example.com/api/auto_update,
      "statsUrl": https://example.com/api/stats,
      "privateKey": undefined,
      "version": undefined,
      "directUpdate": undefined,
      "periodCheckDelay": undefined,
      "localS3": undefined,
      "localHost": undefined,
      "localWebHost": undefined,
      "localSupa": undefined,
      "localSupaAnon": undefined,
      "allowModifyUrl": undefined,
      "defaultChannel": undefined
    }
  }
}
```

In `capacitor.config.ts`:

```ts
/// <reference types="@capgo/capacitor-updater" />

import { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  plugins: {
    CapacitorUpdater: {
      appReadyTimeout: 1000 // (1 second),
      responseTimeout: 10 // (10 second),
      autoDeleteFailed: false,
      autoDeletePrevious: false,
      autoUpdate: false,
      resetWhenUpdate: false,
      updateUrl: https://example.com/api/auto_update,
      statsUrl: https://example.com/api/stats,
      privateKey: undefined,
      version: undefined,
      directUpdate: undefined,
      periodCheckDelay: undefined,
      localS3: undefined,
      localHost: undefined,
      localWebHost: undefined,
      localSupa: undefined,
      localSupaAnon: undefined,
      allowModifyUrl: undefined,
      defaultChannel: undefined,
    },
  },
};

export default config;
```

</docgen-config>

## API

<docgen-index>

* [`notifyAppReady()`](#notifyappready)
* [`setUpdateUrl(...)`](#setupdateurl)
* [`setStatsUrl(...)`](#setstatsurl)
* [`setChannelUrl(...)`](#setchannelurl)
* [`download(...)`](#download)
* [`next(...)`](#next)
* [`set(...)`](#set)
* [`delete(...)`](#delete)
* [`list()`](#list)
* [`reset(...)`](#reset)
* [`current()`](#current)
* [`reload()`](#reload)
* [`setMultiDelay(...)`](#setmultidelay)
* [`cancelDelay()`](#canceldelay)
* [`getLatest()`](#getlatest)
* [`setChannel(...)`](#setchannel)
* [`unsetChannel(...)`](#unsetchannel)
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
* [`addListener('appReady', ...)`](#addlistenerappready)
* [`getBuiltinVersion()`](#getbuiltinversion)
* [`getDeviceId()`](#getdeviceid)
* [`getPluginVersion()`](#getpluginversion)
* [`isAutoUpdateEnabled()`](#isautoupdateenabled)
* [`removeAllListeners()`](#removealllisteners)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

### notifyAppReady()

```typescript
notifyAppReady() => Promise<{ bundle: BundleInfo; }>
```

Notify Capacitor Updater that the current bundle is working (a rollback will occur of this method is not called on every app launch)
By default this method should be called in the first 10 sec after app launch, otherwise a rollback will occur.
Change this behaviour with {@link appReadyTimeout}

**Returns:** <code>Promise&lt;{ bundle: <a href="#bundleinfo">BundleInfo</a>; }&gt;</code>

--------------------


### setUpdateUrl(...)

```typescript
setUpdateUrl(options: { url: string; }) => Promise<void>
```

Set the updateUrl for the app, this will be used to check for updates.

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Since:** 5.4.0

--------------------


### setStatsUrl(...)

```typescript
setStatsUrl(options: { url: string; }) => Promise<void>
```

Set the statsUrl for the app, this will be used to send statistics.

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Since:** 5.4.0

--------------------


### setChannelUrl(...)

```typescript
setChannelUrl(options: { url: string; }) => Promise<void>
```

Set the channelUrl for the app, this will be used to set the channel.

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Since:** 5.4.0

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

Get all locally downloaded bundles in your app

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


### cancelDelay()

```typescript
cancelDelay() => Promise<void>
```

Cancel delay to updates as usual

**Since:** 4.0.0

--------------------


### getLatest()

```typescript
getLatest() => Promise<latestVersion>
```

Get Latest bundle available from update Url

**Returns:** <code>Promise&lt;<a href="#latestversion">latestVersion</a>&gt;</code>

**Since:** 4.0.0

--------------------


### setChannel(...)

```typescript
setChannel(options: SetChannelOptions) => Promise<channelRes>
```

Set Channel for this device, the channel have to allow self assignement to make this work
Do not use this method to set the channel at boot when autoUpdate is enabled, this method is made to set the channel after the app is ready when user click on a button for example

| Param         | Type                                                            | Description                                                                      |
| ------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setchanneloptions">SetChannelOptions</a></code> | is the {@link <a href="#setchanneloptions">SetChannelOptions</a>} channel to set |

**Returns:** <code>Promise&lt;<a href="#channelres">channelRes</a>&gt;</code>

**Since:** 4.7.0

--------------------


### unsetChannel(...)

```typescript
unsetChannel(options: UnsetChannelOptions) => Promise<void>
```

Unset Channel for this device, the device will return to the default channel

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#unsetchanneloptions">UnsetChannelOptions</a></code> |

**Since:** 4.7.0

--------------------


### getChannel()

```typescript
getChannel() => Promise<getChannelRes>
```

get Channel for this device

**Returns:** <code>Promise&lt;<a href="#getchannelres">getChannelRes</a>&gt;</code>

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

Listen for download event in the App, let you know when the download is started, loading and finished, with a percent value

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

Listen for reload event in the App, let you know when reload has happend

| Param              | Type                                                                |
| ------------------ | ------------------------------------------------------------------- |
| **`eventName`**    | <code>'appReloaded'</code>                                          |
| **`listenerFunc`** | <code><a href="#appreloadedlistener">AppReloadedListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 4.3.0

--------------------


### addListener('appReady', ...)

```typescript
addListener(eventName: "appReady", listenerFunc: AppReadyListener) => Promise<PluginListenerHandle> & PluginListenerHandle
```

Listen for app ready event in the App, let you know when app is ready to use

| Param              | Type                                                          |
| ------------------ | ------------------------------------------------------------- |
| **`eventName`**    | <code>'appReady'</code>                                       |
| **`listenerFunc`** | <code><a href="#appreadylistener">AppReadyListener</a></code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt; & <a href="#pluginlistenerhandle">PluginListenerHandle</a></code>

**Since:** 5.1.0

--------------------


### getBuiltinVersion()

```typescript
getBuiltinVersion() => Promise<{ version: string; }>
```

Get the native app version or the builtin version if set in config

**Returns:** <code>Promise&lt;{ version: string; }&gt;</code>

**Since:** 5.2.0

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


### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

Remove all listeners for this plugin.

**Since:** 1.0.0

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


#### latestVersion

| Prop             | Type                 | Description             | Since |
| ---------------- | -------------------- | ----------------------- | ----- |
| **`version`**    | <code>string</code>  | Res of getLatest method | 4.0.0 |
| **`major`**      | <code>boolean</code> |                         |       |
| **`message`**    | <code>string</code>  |                         |       |
| **`sessionKey`** | <code>string</code>  |                         |       |
| **`error`**      | <code>string</code>  |                         |       |
| **`old`**        | <code>string</code>  |                         |       |
| **`url`**        | <code>string</code>  |                         |       |


#### channelRes

| Prop          | Type                | Description                   | Since |
| ------------- | ------------------- | ----------------------------- | ----- |
| **`status`**  | <code>string</code> | Current status of set channel | 4.7.0 |
| **`error`**   | <code>any</code>    |                               |       |
| **`message`** | <code>any</code>    |                               |       |


#### SetChannelOptions

| Prop                    | Type                 |
| ----------------------- | -------------------- |
| **`channel`**           | <code>string</code>  |
| **`triggerAutoUpdate`** | <code>boolean</code> |


#### UnsetChannelOptions

| Prop                    | Type                 |
| ----------------------- | -------------------- |
| **`triggerAutoUpdate`** | <code>boolean</code> |


#### getChannelRes

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


#### noNeedEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


#### updateAvailableEvent

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


#### AppReadyEvent

| Prop         | Type                                              | Description                      | Since |
| ------------ | ------------------------------------------------- | -------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a app is ready to use. | 5.2.0 |
| **`status`** | <code>string</code>                               |                                  |       |


### Type Aliases


#### BundleStatus

<code>"success" | "error" | "pending" | "downloading"</code>


#### DelayUntilNext

<code>"background" | "kill" | "nativeVersion" | "date"</code>


#### DownloadChangeListener

<code>(state: <a href="#downloadevent">DownloadEvent</a>): void</code>


#### NoNeedListener

<code>(state: <a href="#noneedevent">noNeedEvent</a>): void</code>


#### UpdateAvailabledListener

<code>(state: <a href="#updateavailableevent">updateAvailableEvent</a>): void</code>


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


#### AppReadyListener

<code>(state: <a href="#appreadyevent">AppReadyEvent</a>): void</code>

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
