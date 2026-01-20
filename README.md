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

<div align="center">
  <h2><a href="https://capgo.app/?ref=plugin_updater_v6"> ➡️ Get Instant updates for your App with Capgo</a></h2>
  <h2><a href="https://capgo.app/consulting/?ref=plugin_updater_v6"> Missing a feature? We’ll build the plugin for you 💪</a></h2>
</div>

Capacitor plugin to update your app remotely in real-time.

Open-source Alternative to Appflow, Codepush or Capawesome

## Why Capacitor Updater?

App store review processes can take days or weeks, blocking critical bug fixes and updates from reaching your users. Capacitor Updater solves this by:

- **Instant updates** - Push JavaScript/HTML/CSS updates directly to users without app store review
- **Delta updates** - Only download changed files, making updates ultra-fast
- **Rollback protection** - Automatically revert broken updates to keep your app stable
- **Open source** - Self-host or use Capgo Cloud, with full control over your update infrastructure
- **Battle-tested** - Used by 3000+ production apps with proven reliability
- **Most stared** - Capacitor updater is the most stared Capacitor plugin on GitHub

Perfect for fixing bugs immediately, A/B testing features, and maintaining control over your release schedule.

## Features

- ☁️ Cloud / Self hosted Support: Use our [Cloud](https://capgo.app/) to manage your app updates or yours.
- 📦 Bundle Management: Download, assign to channel, rollback.
- 📺 Channel Support: Use channels to manage different environments.
- 🎯 Set Channel to specific device to do QA or debug one user.
- 🔄 Auto Update: Automatically download and set the latest bundle for the app.
- 🛟 Rollback: Reset the app to last working bundle if an incompatible bundle has been set.
- 🔁 **Delta Updates**: Make instant updates by only downloading changed files.
- 🔒 **Security**: Encrypt and sign each updates with best in class security standards.
- ⚔️ **Battle-Tested**: Used in more than 3000 projects.
- 📊 View your deployment statistics
- 🔋 Supports Android and iOS
- ⚡️ Capacitor 6/7 support
- 🌐 **Open Source**: Licensed under the Mozilla Public License 2.0
- 🌐 **Open Source Backend**: Self install [our backend](https://github.com/Cap-go/capgo) in your infra


You have 3 ways possible :
- Use [capgo.app](https://capgo.app) a full featured auto-update system in 5 min Setup, to manage version, update, revert and see stats.
- Use your own server update with auto-update system
- Use manual methods to zip, upload, download, from JS to do it when you want.

## Documentation
The most complete [documentation here](https://capgo.app/docs/).

## Community
Join the [discord](https://discord.gg/VnYRvBfgA6) to get help.

## Migration to v8

This major version is here to follow Capacitor major version 8

First follow the migration guide of Capacitor:

[https://capacitorjs.com/docs/updating/8-0](https://capacitorjs.com/docs/updating/8-0/)

## Migration to v7.34

- **Channel storage change**: `setChannel()` now stores channel assignments locally on the device instead of in the cloud. This provides better offline support and reduces backend load.
  - Channel assignments persist between app restarts
  - Use `unsetChannel()` to clear the local assignment and revert to `defaultChannel`
  - Old devices (< v7.34.0) will continue using cloud-based storage
- **New event**: Listen to the `channelPrivate` event to handle cases where a user tries to assign themselves to a private channel (one that doesn't allow self-assignment). See example in the `setChannel()` documentation above.

## Migration to v7

The minimum iOS version is now **15.0** to match Capacitor 7/8 requirements.

Starting from v8, the plugin uses [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) instead of SSZipArchive/ZipArchive for ZIP extraction. ZIPFoundation uses Apple's native `libcompression` framework, which removes the previous zlib dependency and its associated security constraints.

## Compatibility

| Plugin version | Capacitor compatibility | Maintained        |
| -------------- | ----------------------- | ----------------- |
| v8.\*.\*       | v8.\*.\*                | ✅                 |
| v7.\*.\*       | v7.\*.\*                | ✅                 |
| v6.\*.\*       | v6.\*.\*                | ✅                 |
| v5.\*.\*       | v5.\*.\*                | ✅ |
| v4.\*.\*       | v4.\*.\*                | ⚠️ Deprecated |
| v3.\*.\*       | v3.\*.\*                | ⚠️ Deprecated     |
| > 7            | v4.\*.\*                | ⚠️ Deprecated, our CI got crazy and bumped too much version     |

> **Note:** Versions 5, 6, 7, and 8 all share the same features. The major version simply follows your Capacitor version. You can safely use any of these versions that matches your Capacitor installation.

### iOS

#### Privacy manifest

Add the `NSPrivacyAccessedAPICategoryUserDefaults` dictionary key to your [Privacy Manifest](https://capacitorjs.com/docs/ios/privacy-manifest) (usually `ios/App/PrivacyInfo.xcprivacy`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
      <!-- Add this dict entry to the array if the file already exists. -->
      <dict>
        <key>NSPrivacyAccessedAPIType</key>
        <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
        <key>NSPrivacyAccessedAPITypeReasons</key>
        <array>
          <string>CA92.1</string>
        </array>
      </dict>
    </array>
  </dict>
</plist>
```

We recommend to declare [`CA92.1`](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing_use_of_required_reason_api#4278401) as the reason for accessing the [`UserDefaults`](https://developer.apple.com/documentation/foundation/userdefaults) API.

## Installation

Step by step here: [Getting started](https://capgo.app/docs/getting-started/add-an-app/)

Or

```bash
npm install @capgo/capacitor-updater
npx cap sync
```

### Install a specific version

Use npm tags to install the version matching your Capacitor version:

```bash
# For Capacitor 8 (latest)
npm install @capgo/capacitor-updater@latest

# For Capacitor 7
npm install @capgo/capacitor-updater@lts-v7

# For Capacitor 6
npm install @capgo/capacitor-updater@lts-v6

# For Capacitor 5
npm install @capgo/capacitor-updater@lts-v5
```

## Auto-update setup

Create your account in [capgo.app](https://capgo.app) and get your [API key](https://console.capgo.app/dashboard/apikeys)
- Login to CLI `npx @capgo/cli@latest init API_KEY`
And follow the steps by step to setup your app.

For detailed instructions on the auto-update setup, refer to the [Auto update documentation](https://capgo.app/docs/plugin/cloud-mode/getting-started/).


## No Cloud setup

Download update distribution zipfiles from a custom URL. Manually control the entire update process.

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
This informs Capacitor Updater that the current update bundle has loaded successfully. Failing to call this method will cause your application to be rolled back to the previously successful version (or built-in bundle).
- Add this to your application.
```javascript
  const version = await CapacitorUpdater.download({
    version: '0.0.4',
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
          version: '0.0.4',
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

TIP: If you prefer a secure and automated way to update your app, you can use [capgo.app](https://capgo.app) - a full-featured, auto-update system.

### Store Guideline Compliance

Android Google Play and iOS App Store have corresponding guidelines that have rules you should be aware of before integrating the Capacitor-updater solution within your application.

#### Google play

Third paragraph of [Device and Network Abuse](https://support.google.com/googleplay/android-developer/answer/9888379?hl=en) topic describe that updating source code by any method besides Google Play's update mechanism is restricted. But this restriction does not apply to updating JavaScript bundles.
> This restriction does not apply to code that runs in a virtual machine and has limited access to Android APIs (such as JavaScript in a web view or browser).

That fully allow Capacitor-updater as it updates just JS bundles and can't update native code part.

#### App Store

Paragraph **3.3.2**, since back in 2015's [Apple Developer Program License Agreement](https://developer.apple.com/programs/ios/information/) fully allowed performing over-the-air updates of JavaScript and assets.

And in its latest version (20170605) [downloadable here](https://developer.apple.com/terms/) this ruling is even broader:

> Interpreted code may be downloaded to an Application, but only so long as such code:
- (a) does not change the primary purpose of the Application by providing features or functionality that are inconsistent with the intended and advertised purpose of the Application as submitted to the App Store
- (b) does not create a store or storefront for other code or applications
- (c) does not bypass signing, sandbox, or other security features of the OS.

Capacitor-updater allows you to respect these rules in full compliance, so long as the update you push does not significantly deviate your product from its original App Store approved intent.

To further remain in compliance with Apple's guidelines, we suggest that App Store-distributed apps don't enable the `Force update` scenario, since in the [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) it is written that:

> Apps must not force users to rate the app, review the app, download other apps, or other similar actions to access functionality, content, or use of the app.

This is not a problem for the default behavior of background update, since it won't force the user to apply the new version until the next app close, but at least you should be aware of that ruling if you decide to show it.

### Packaging `dist.zip` update bundles

Capacitor Updater works by unzipping a compiled app bundle to the native device filesystem. Whatever you choose to name the file you upload/download from your release/update server URL (via either manual or automatic updating), this `.zip` bundle must meet the following requirements:

- The zip file should contain the full contents of your production Capacitor build output folder, usually `{project directory}/dist/` or `{project directory}/www/`. This is where `index.html` will be located, and it should also contain all bundled JavaScript, CSS, and web resources necessary for your app to run.
- Do not password encrypt the bundle zip file, or it will fail to unpack.
- Make sure the bundle does not contain any extra hidden files or folders, or it may fail to unpack.

### Downgrading to a previous version of the updater plugin

Downgrading to a previous version of the updater plugin is not supported.

## Updater Plugin Config

<docgen-config>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

CapacitorUpdater can be configured with these options:

| Prop                          | Type                                                          | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Default                                                                       | Since   |
| ----------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------- |
| **`appReadyTimeout`**         | <code>number</code>                                           | Configure the number of milliseconds the native plugin should wait before considering an update 'failed'. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | <code>10000 // (10 seconds)</code>                                            |         |
| **`responseTimeout`**         | <code>number</code>                                           | Configure the number of seconds the native plugin should wait before considering API timeout. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>20 // (20 second)</code>                                                |         |
| **`autoDeleteFailed`**        | <code>boolean</code>                                          | Configure whether the plugin should use automatically delete failed bundles. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | <code>true</code>                                                             |         |
| **`autoDeletePrevious`**      | <code>boolean</code>                                          | Configure whether the plugin should use automatically delete previous bundles after a successful update. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | <code>true</code>                                                             |         |
| **`autoUpdate`**              | <code>boolean</code>                                          | Configure whether the plugin should use Auto Update via an update server. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | <code>true</code>                                                             |         |
| **`resetWhenUpdate`**         | <code>boolean</code>                                          | Automatically delete previous downloaded bundles when a newer native app bundle is installed to the device. Setting this to false can broke the auto update flow if the user download from the store a native app bundle that is older than the current downloaded bundle. Upload will be prevented by channel setting downgrade_under_native. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                | <code>true</code>                                                             |         |
| **`updateUrl`**               | <code>string</code>                                           | Configure the URL / endpoint to which update checks are sent. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>https://plugin.capgo.app/updates</code>                                 |         |
| **`channelUrl`**              | <code>string</code>                                           | Configure the URL / endpoint for channel operations. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | <code>https://plugin.capgo.app/channel_self</code>                            |         |
| **`statsUrl`**                | <code>string</code>                                           | Configure the URL / endpoint to which update statistics are sent. Only available for Android and iOS. Set to "" to disable stats reporting.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | <code>https://plugin.capgo.app/stats</code>                                   |         |
| **`publicKey`**               | <code>string</code>                                           | Configure the public key for end to end live update encryption Version 2 Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | <code>undefined</code>                                                        | 6.2.0   |
| **`version`**                 | <code>string</code>                                           | Configure the current version of the app. This will be used for the first update request. If not set, the plugin will get the version from the native code. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | <code>undefined</code>                                                        | 4.17.48 |
| **`directUpdate`**            | <code>boolean \| 'always' \| 'atInstall' \| 'onLaunch'</code> | Configure when the plugin should direct install updates. Only for autoUpdate mode. Works well for apps less than 10MB and with uploads done using --partial flag. Zip or apps more than 10MB will be relatively slow for users to update. - false: Never do direct updates (use default behavior: download at start, set when backgrounded) - atInstall: Direct update only when app is installed, updated from store, otherwise act as directUpdate = false - onLaunch: Direct update only on app installed, updated from store or after app kill, otherwise act as directUpdate = false - always: Direct update in all previous cases (app installed, updated from store, after app kill or app resume), never act as directUpdate = false - true: (deprecated) Same as "always" for backward compatibility Only available for Android and iOS. | <code>false</code>                                                            | 5.1.0   |
| **`autoSplashscreen`**        | <code>boolean</code>                                          | Automatically handle splashscreen hiding when using directUpdate. When enabled, the plugin will automatically hide the splashscreen after updates are applied or when no update is needed. This removes the need to manually listen for appReady events and call SplashScreen.hide(). Only works when directUpdate is set to "atInstall", "always", "onLaunch", or true. Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false. Requires autoUpdate and directUpdate to be enabled. Only available for Android and iOS.                                                                                                                                                                                                                                                                          | <code>false</code>                                                            | 7.6.0   |
| **`autoSplashscreenLoader`**  | <code>boolean</code>                                          | Display a native loading indicator on top of the splashscreen while automatic direct updates are running. Only takes effect when {@link autoSplashscreen} is enabled. Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>false</code>                                                            | 7.19.0  |
| **`autoSplashscreenTimeout`** | <code>number</code>                                           | Automatically hide the splashscreen after the specified number of milliseconds when using automatic direct updates. If the timeout elapses, the update continues to download in the background while the splashscreen is dismissed. Set to `0` (zero) to disable the timeout. When the timeout fires, the direct update flow is skipped and the downloaded bundle is installed on the next background/launch. Requires {@link autoSplashscreen} to be enabled. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                | <code>10000 // (10 seconds)</code>                                            | 7.19.0  |
| **`periodCheckDelay`**        | <code>number</code>                                           | Configure the delay period for period update check. the unit is in seconds. Only available for Android and iOS. Cannot be less than 600 seconds (10 minutes).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | <code>0 (disabled)</code>                                                     |         |
| **`localS3`**                 | <code>boolean</code>                                          | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>undefined</code>                                                        | 4.17.48 |
| **`localHost`**               | <code>string</code>                                           | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>undefined</code>                                                        | 4.17.48 |
| **`localWebHost`**            | <code>string</code>                                           | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>undefined</code>                                                        | 4.17.48 |
| **`localSupa`**               | <code>string</code>                                           | Configure the CLI to use a local server for testing or self-hosted update server.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>undefined</code>                                                        | 4.17.48 |
| **`localSupaAnon`**           | <code>string</code>                                           | Configure the CLI to use a local server for testing.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | <code>undefined</code>                                                        | 4.17.48 |
| **`localApi`**                | <code>string</code>                                           | Configure the CLI to use a local api for testing.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | <code>undefined</code>                                                        | 6.3.3   |
| **`localApiFiles`**           | <code>string</code>                                           | Configure the CLI to use a local file api for testing.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | <code>undefined</code>                                                        | 6.3.3   |
| **`allowModifyUrl`**          | <code>boolean</code>                                          | Allow the plugin to modify the updateUrl, statsUrl and channelUrl dynamically from the JavaScript side.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | <code>false</code>                                                            | 5.4.0   |
| **`allowModifyAppId`**        | <code>boolean</code>                                          | Allow the plugin to modify the appId dynamically from the JavaScript side.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | <code>false</code>                                                            | 7.14.0  |
| **`allowManualBundleError`**  | <code>boolean</code>                                          | Allow marking bundles as errored from JavaScript while using manual update flows. When enabled, {@link CapacitorUpdaterPlugin.setBundleError} can change a bundle status to `error`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | <code>false</code>                                                            | 7.20.0  |
| **`persistCustomId`**         | <code>boolean</code>                                          | Persist the customId set through {@link CapacitorUpdaterPlugin.setCustomId} across app restarts. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | <code>false (will be true by default in a future major release v8.x.x)</code> | 7.17.3  |
| **`persistModifyUrl`**        | <code>boolean</code>                                          | Persist the updateUrl, statsUrl and channelUrl set through {@link CapacitorUpdaterPlugin.setUpdateUrl}, {@link CapacitorUpdaterPlugin.setStatsUrl} and {@link CapacitorUpdaterPlugin.setChannelUrl} across app restarts. Only available for Android and iOS.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      | <code>false</code>                                                            | 7.20.0  |
| **`allowSetDefaultChannel`**  | <code>boolean</code>                                          | Allow or disallow the {@link CapacitorUpdaterPlugin.setChannel} method to modify the defaultChannel. When set to `false`, calling `setChannel()` will return an error with code `disabled_by_config`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | <code>true</code>                                                             | 7.34.0  |
| **`defaultChannel`**          | <code>string</code>                                           | Set the default channel for the app in the config. Case sensitive. This will setting will override the default channel set in the cloud, but will still respect overrides made in the cloud. This requires the channel to allow devices to self dissociate/associate in the channel settings. https://capgo.app/docs/public-api/channels/#channel-configuration-options                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | <code>undefined</code>                                                        | 5.5.0   |
| **`appId`**                   | <code>string</code>                                           | Configure the app id for the app in the config.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | <code>undefined</code>                                                        | 6.0.0   |
| **`keepUrlPathAfterReload`**  | <code>boolean</code>                                          | Configure the plugin to keep the URL path after a reload. WARNING: When a reload is triggered, 'window.history' will be cleared.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | <code>false</code>                                                            | 6.8.0   |
| **`disableJSLogging`**        | <code>boolean</code>                                          | Disable the JavaScript logging of the plugin. if true, the plugin will not log to the JavaScript console. only the native log will be done                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | <code>false</code>                                                            | 7.3.0   |
| **`osLogging`**               | <code>boolean</code>                                          | Enable OS-level logging. When enabled, logs are written to the system log which can be inspected in production builds. - **iOS**: Uses os_log instead of Swift.print, logs accessible via Console.app or Instruments - **Android**: Logs to Logcat (android.util.Log) When set to false, system logging is disabled on both platforms (only JavaScript console logging will occur if enabled). This is useful for debugging production apps (App Store/TestFlight builds on iOS, or production APKs on Android).                                                                                                                                                                                                                                                                                                                                  | <code>true</code>                                                             | 8.42.0  |
| **`shakeMenu`**               | <code>boolean</code>                                          | Enable shake gesture to show update menu for debugging/testing purposes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | <code>false</code>                                                            | 7.5.0   |

### Examples

In `capacitor.config.json`:

```json
{
  "plugins": {
    "CapacitorUpdater": {
      "appReadyTimeout": 1000 // (1 second, minimum 1000),
      "responseTimeout": 10 // (10 second),
      "autoDeleteFailed": false,
      "autoDeletePrevious": false,
      "autoUpdate": false,
      "resetWhenUpdate": false,
      "updateUrl": https://example.com/api/auto_update,
      "channelUrl": https://example.com/api/channel,
      "statsUrl": https://example.com/api/stats,
      "publicKey": undefined,
      "version": undefined,
      "directUpdate": undefined,
      "autoSplashscreen": undefined,
      "autoSplashscreenLoader": undefined,
      "autoSplashscreenTimeout": undefined,
      "periodCheckDelay": 3600 (1 hour),
      "localS3": undefined,
      "localHost": undefined,
      "localWebHost": undefined,
      "localSupa": undefined,
      "localSupaAnon": undefined,
      "localApi": undefined,
      "localApiFiles": undefined,
      "allowModifyUrl": undefined,
      "allowModifyAppId": undefined,
      "allowManualBundleError": undefined,
      "persistCustomId": undefined,
      "persistModifyUrl": undefined,
      "allowSetDefaultChannel": undefined,
      "defaultChannel": undefined,
      "appId": undefined,
      "keepUrlPathAfterReload": undefined,
      "disableJSLogging": undefined,
      "osLogging": undefined,
      "shakeMenu": undefined
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
      appReadyTimeout: 1000 // (1 second, minimum 1000),
      responseTimeout: 10 // (10 second),
      autoDeleteFailed: false,
      autoDeletePrevious: false,
      autoUpdate: false,
      resetWhenUpdate: false,
      updateUrl: https://example.com/api/auto_update,
      channelUrl: https://example.com/api/channel,
      statsUrl: https://example.com/api/stats,
      publicKey: undefined,
      version: undefined,
      directUpdate: undefined,
      autoSplashscreen: undefined,
      autoSplashscreenLoader: undefined,
      autoSplashscreenTimeout: undefined,
      periodCheckDelay: 3600 (1 hour),
      localS3: undefined,
      localHost: undefined,
      localWebHost: undefined,
      localSupa: undefined,
      localSupaAnon: undefined,
      localApi: undefined,
      localApiFiles: undefined,
      allowModifyUrl: undefined,
      allowModifyAppId: undefined,
      allowManualBundleError: undefined,
      persistCustomId: undefined,
      persistModifyUrl: undefined,
      allowSetDefaultChannel: undefined,
      defaultChannel: undefined,
      appId: undefined,
      keepUrlPathAfterReload: undefined,
      disableJSLogging: undefined,
      osLogging: undefined,
      shakeMenu: undefined,
    },
  },
};

export default config;
```

</docgen-config>

## API

<docgen-index>
<!--Auto-generated, compact index-->

* [`notifyAppReady()`](#notifyappready)
* [`setUpdateUrl(...)`](#setupdateurl)
* [`setStatsUrl(...)`](#setstatsurl)
* [`setChannelUrl(...)`](#setchannelurl)
* [`download(...)`](#download)
* [`next(...)`](#next)
* [`set(...)`](#set)
* [`delete(...)`](#delete)
* [`setBundleError(...)`](#setbundleerror)
* [`list(...)`](#list)
* [`reset(...)`](#reset)
* [`current()`](#current)
* [`reload()`](#reload)
* [`setMultiDelay(...)`](#setmultidelay)
* [`cancelDelay()`](#canceldelay)
* [`getLatest(...)`](#getlatest)
* [`setChannel(...)`](#setchannel)
* [`unsetChannel(...)`](#unsetchannel)
* [`getChannel()`](#getchannel)
* [`listChannels()`](#listchannels)
* [`setCustomId(...)`](#setcustomid)
* [`getBuiltinVersion()`](#getbuiltinversion)
* [`getDeviceId()`](#getdeviceid)
* [`getPluginVersion()`](#getpluginversion)
* [`isAutoUpdateEnabled()`](#isautoupdateenabled)
* [`removeAllListeners()`](#removealllisteners)
* [`addListener('download', ...)`](#addlistenerdownload-)
* [`addListener('noNeedUpdate', ...)`](#addlistenernoneedupdate-)
* [`addListener('updateAvailable', ...)`](#addlistenerupdateavailable-)
* [`addListener('downloadComplete', ...)`](#addlistenerdownloadcomplete-)
* [`addListener('breakingAvailable', ...)`](#addlistenerbreakingavailable-)
* [`addListener('majorAvailable', ...)`](#addlistenermajoravailable-)
* [`addListener('updateFailed', ...)`](#addlistenerupdatefailed-)
* [`addListener('downloadFailed', ...)`](#addlistenerdownloadfailed-)
* [`addListener('appReloaded', ...)`](#addlistenerappreloaded-)
* [`addListener('appReady', ...)`](#addlistenerappready-)
* [`addListener('channelPrivate', ...)`](#addlistenerchannelprivate-)
* [`addListener('onFlexibleUpdateStateChange', ...)`](#addlisteneronflexibleupdatestatechange-)
* [`isAutoUpdateAvailable()`](#isautoupdateavailable)
* [`getNextBundle()`](#getnextbundle)
* [`getFailedUpdate()`](#getfailedupdate)
* [`setShakeMenu(...)`](#setshakemenu)
* [`isShakeMenuEnabled()`](#isshakemenuenabled)
* [`getAppId()`](#getappid)
* [`setAppId(...)`](#setappid)
* [`getAppUpdateInfo(...)`](#getappupdateinfo)
* [`openAppStore(...)`](#openappstore)
* [`performImmediateUpdate()`](#performimmediateupdate)
* [`startFlexibleUpdate()`](#startflexibleupdate)
* [`completeFlexibleUpdate()`](#completeflexibleupdate)
* [Interfaces](#interfaces)
* [Type Aliases](#type-aliases)
* [Enums](#enums)

</docgen-index>

<docgen-api>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

#### notifyAppReady()

```typescript
notifyAppReady() => Promise<AppReadyResult>
```

Notify the native layer that JavaScript initialized successfully.

**CRITICAL: You must call this method on every app launch to prevent automatic rollback.**

This is a simple notification to confirm that your bundle's JavaScript loaded and executed.
The native web server successfully served the bundle files and your JS runtime started.
That's all it checks - nothing more complex.

**What triggers rollback:**
- NOT calling this method within the timeout (default: 10 seconds)
- Complete JavaScript failure (bundle won't load at all)

**What does NOT trigger rollback:**
- Runtime errors after initialization (API failures, crashes, etc.)
- Network request failures
- Application logic errors

**IMPORTANT: Call this BEFORE any network requests.**
Don't wait for APIs, data loading, or async operations. Call it as soon as your
JavaScript bundle starts executing to confirm the bundle itself is valid.

Best practices:
- Call immediately in your app entry point (main.js, app component mount, etc.)
- Don't put it after network calls or heavy initialization
- Don't wrap it in try/catch with conditions
- Adjust {@link PluginsConfig.CapacitorUpdater.appReadyTimeout} if you need more time

**Returns:** <code>Promise&lt;<a href="#appreadyresult">AppReadyResult</a>&gt;</code>

--------------------


#### setUpdateUrl(...)

```typescript
setUpdateUrl(options: UpdateUrl) => Promise<void>
```

Set the update URL for the app dynamically at runtime.

This overrides the {@link PluginsConfig.CapacitorUpdater.updateUrl} config value.
Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.

Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
Otherwise, the URL will reset to the config value on next app launch.

| Param         | Type                                            | Description                                       |
| ------------- | ----------------------------------------------- | ------------------------------------------------- |
| **`options`** | <code><a href="#updateurl">UpdateUrl</a></code> | Contains the URL to use for checking for updates. |

**Since:** 5.4.0

--------------------


#### setStatsUrl(...)

```typescript
setStatsUrl(options: StatsUrl) => Promise<void>
```

Set the statistics URL for the app dynamically at runtime.

This overrides the {@link PluginsConfig.CapacitorUpdater.statsUrl} config value.
Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.

Pass an empty string to disable statistics gathering entirely.
Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.

| Param         | Type                                          | Description                                                                    |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------------ |
| **`options`** | <code><a href="#statsurl">StatsUrl</a></code> | Contains the URL to use for sending statistics, or an empty string to disable. |

**Since:** 5.4.0

--------------------


#### setChannelUrl(...)

```typescript
setChannelUrl(options: ChannelUrl) => Promise<void>
```

Set the channel URL for the app dynamically at runtime.

This overrides the {@link PluginsConfig.CapacitorUpdater.channelUrl} config value.
Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.

Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
Otherwise, the URL will reset to the config value on next app launch.

| Param         | Type                                              | Description                                     |
| ------------- | ------------------------------------------------- | ----------------------------------------------- |
| **`options`** | <code><a href="#channelurl">ChannelUrl</a></code> | Contains the URL to use for channel operations. |

**Since:** 5.4.0

--------------------


#### download(...)

```typescript
download(options: DownloadOptions) => Promise<BundleInfo>
```

Download a new bundle from the provided URL for later installation.

The downloaded bundle is stored locally but not activated. To use it:
- Call {@link next} to set it for installation on next app backgrounding/restart
- Call {@link set} to activate it immediately (destroys current JavaScript context)

The URL should point to a zip file containing either:
- Your app files directly in the zip root, or
- A single folder containing all your app files

The bundle must include an `index.html` file at the root level.

For encrypted bundles, provide the `sessionKey` and `checksum` parameters.
For multi-file partial updates, provide the `manifest` array.

| Param         | Type                                                        | Description                                                                                  |
| ------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#downloadoptions">DownloadOptions</a></code> | The {@link <a href="#downloadoptions">DownloadOptions</a>} for downloading a new bundle zip. |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


#### next(...)

```typescript
next(options: BundleId) => Promise<BundleInfo>
```

Set the next bundle to be activated when the app backgrounds or restarts.

This is the recommended way to apply updates as it doesn't interrupt the user's current session.
The bundle will be activated when:
- The app is backgrounded (user switches away), or
- The app is killed and relaunched, or
- {@link reload} is called manually

Unlike {@link set}, this method does NOT destroy the current JavaScript context immediately.
Your app continues running normally until one of the above events occurs.

Use {@link setMultiDelay} to add additional conditions before the update is applied.

| Param         | Type                                          | Description                                                                                                                 |
| ------------- | --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#bundleid">BundleId</a></code> | Contains the ID of the bundle to set as next. Use {@link <a href="#bundleinfo">BundleInfo.id</a>} from a downloaded bundle. |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


#### set(...)

```typescript
set(options: BundleId) => Promise<void>
```

Set the current bundle and immediately reloads the app.

**IMPORTANT: This is a terminal operation that destroys the current JavaScript context.**

When you call this method:
- The entire JavaScript context is immediately destroyed
- The app reloads from a different folder with different files
- NO code after this call will execute
- NO promises will resolve
- NO callbacks will fire
- Event listeners registered after this call are unreliable and may never fire

The reload happens automatically - you don't need to do anything else.
If you need to preserve state like the current URL path, use the {@link PluginsConfig.CapacitorUpdater.keepUrlPathAfterReload} config option.
For other state preservation needs, save your data before calling this method (e.g., to localStorage).

**Do not** try to execute additional logic after calling `set()` - it won't work as expected.

| Param         | Type                                          | Description                                                                                       |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#bundleid">BundleId</a></code> | A {@link <a href="#bundleid">BundleId</a>} object containing the new bundle id to set as current. |

--------------------


#### delete(...)

```typescript
delete(options: BundleId) => Promise<void>
```

Delete a bundle from local storage to free up disk space.

You cannot delete:
- The currently active bundle
- The `builtin` bundle (the version shipped with your app)
- The bundle set as `next` (call {@link next} with a different bundle first)

Use {@link list} to get all available bundle IDs.

**Note:** The bundle ID is NOT the same as the version name.
Use the `id` field from {@link <a href="#bundleinfo">BundleInfo</a>}, not the `version` field.

| Param         | Type                                          | Description                                                                           |
| ------------- | --------------------------------------------- | ------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#bundleid">BundleId</a></code> | A {@link <a href="#bundleid">BundleId</a>} object containing the bundle ID to delete. |

--------------------


#### setBundleError(...)

```typescript
setBundleError(options: BundleId) => Promise<BundleInfo>
```

Manually mark a bundle as failed/errored in manual update mode.

This is useful when you detect that a bundle has critical issues and want to prevent
it from being used again. The bundle status will be changed to `error` and the plugin
will avoid using this bundle in the future.

**Requirements:**
- {@link PluginsConfig.CapacitorUpdater.allowManualBundleError} must be set to `true`
- Only works in manual update mode (when autoUpdate is disabled)

Common use case: After downloading and testing a bundle, you discover it has critical
bugs and want to mark it as failed so it won't be retried.

| Param         | Type                                          | Description                                                                                    |
| ------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#bundleid">BundleId</a></code> | A {@link <a href="#bundleid">BundleId</a>} object containing the bundle ID to mark as errored. |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

**Since:** 7.20.0

--------------------


#### list(...)

```typescript
list(options?: ListOptions | undefined) => Promise<BundleListResult>
```

Get all locally downloaded bundles stored in your app.

This returns all bundles that have been downloaded and are available locally, including:
- The currently active bundle
- The `builtin` bundle (shipped with your app)
- Any downloaded bundles waiting to be activated
- Failed bundles (with `error` status)

Use this to:
- Check available disk space by counting bundles
- Delete old bundles with {@link delete}
- Monitor bundle download status

| Param         | Type                                                | Description                                                                                |
| ------------- | --------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| **`options`** | <code><a href="#listoptions">ListOptions</a></code> | The {@link <a href="#listoptions">ListOptions</a>} for customizing the bundle list output. |

**Returns:** <code>Promise&lt;<a href="#bundlelistresult">BundleListResult</a>&gt;</code>

--------------------


#### reset(...)

```typescript
reset(options?: ResetOptions | undefined) => Promise<void>
```

Reset the app to a known good bundle.

This method helps recover from problematic updates by reverting to either:
- The `builtin` bundle (the original version shipped with your app to App Store/Play Store)
- The last successfully loaded bundle (most recent bundle that worked correctly)

**IMPORTANT: This triggers an immediate app reload, destroying the current JavaScript context.**
See {@link set} for details on the implications of this operation.

Use cases:
- Emergency recovery when an update causes critical issues
- Testing rollback functionality
- Providing users a "reset to factory" option

| Param         | Type                                                  |
| ------------- | ----------------------------------------------------- |
| **`options`** | <code><a href="#resetoptions">ResetOptions</a></code> |

--------------------


#### current()

```typescript
current() => Promise<CurrentBundleResult>
```

Get information about the currently active bundle.

Returns:
- `bundle`: The currently active bundle information
- `native`: The version of the builtin bundle (the original app version from App/Play Store)

If no updates have been applied, `bundle.id` will be `"builtin"`, indicating the app
is running the original version shipped with the native app.

Use this to:
- Display the current version to users
- Check if an update is currently active
- Compare against available updates
- Log the active bundle for debugging

**Returns:** <code>Promise&lt;<a href="#currentbundleresult">CurrentBundleResult</a>&gt;</code>

--------------------


#### reload()

```typescript
reload() => Promise<void>
```

Manually reload the app to apply a pending update.

This triggers the same reload behavior that happens automatically when the app backgrounds.
If you've called {@link next} to queue an update, calling `reload()` will apply it immediately.

**IMPORTANT: This destroys the current JavaScript context immediately.**
See {@link set} for details on the implications of this operation.

Common use cases:
- Applying an update immediately after download instead of waiting for backgrounding
- Providing a "Restart now" button to users after an update is ready
- Testing update flows during development

If no update is pending (no call to {@link next}), this simply reloads the current bundle.

--------------------


#### setMultiDelay(...)

```typescript
setMultiDelay(options: MultiDelayConditions) => Promise<void>
```

Configure conditions that must be met before a pending update is applied.

After calling {@link next} to queue an update, use this method to control when it gets applied.
The update will only be installed after ALL specified conditions are satisfied.

Available condition types:
- `background`: Wait for the app to be backgrounded. Optionally specify duration in milliseconds.
- `kill`: Wait for the app to be killed and relaunched (**Note:** Current behavior triggers update immediately on kill, not on next background. This will be fixed in v8.)
- `date`: Wait until a specific date/time (ISO 8601 format)
- `nativeVersion`: Wait until the native app is updated to a specific version

Condition value formats:
- `background`: Number in milliseconds (e.g., `"300000"` for 5 minutes), or omit for immediate
- `kill`: No value needed
- `date`: ISO 8601 date string (e.g., `"2025-12-31T23:59:59Z"`)
- `nativeVersion`: Version string (e.g., `"2.0.0"`)

| Param         | Type                                                                  | Description                                                                                        |
| ------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#multidelayconditions">MultiDelayConditions</a></code> | Contains the {@link <a href="#multidelayconditions">MultiDelayConditions</a>} array of conditions. |

**Since:** 4.3.0

--------------------


#### cancelDelay()

```typescript
cancelDelay() => Promise<void>
```

Cancel all delay conditions and apply the pending update immediately.

If you've set delay conditions with {@link setMultiDelay}, this method clears them
and triggers the pending update to be applied on the next app background or restart.

This is useful when:
- User manually requests to update now (e.g., clicks "Update now" button)
- Your app detects it's a good time to update (e.g., user finished critical task)
- You want to override a time-based delay early

**Since:** 4.0.0

--------------------


#### getLatest(...)

```typescript
getLatest(options?: GetLatestOptions | undefined) => Promise<LatestVersion>
```

Check the update server for the latest available bundle version.

This queries your configured update URL (or Capgo backend) to see if a newer bundle
is available for download. It does NOT download the bundle automatically.

The response includes:
- `version`: The latest available version identifier
- `url`: Download URL for the bundle (if available)
- `breaking`: Whether this update is marked as incompatible (requires native app update)
- `message`: Optional message from the server
- `manifest`: File list for partial updates (if using multi-file downloads)

After receiving the latest version info, you can:
1. Compare it with your current version
2. Download it using {@link download}
3. Apply it using {@link next} or {@link set}

**Important: Error handling for "no new version available"**

When the device's current version matches the latest version on the server (i.e., the device is already
up-to-date), the server returns a 200 response with `error: "no_new_version_available"` and
`message: "No new version available"`. **This causes `getLatest()` to throw an error**, even though
this is a normal, expected condition.

You should catch this specific error to handle it gracefully:

```typescript
try {
  const latest = await CapacitorUpdater.getLatest();
  // New version is available, proceed with download
} catch (error) {
  if (error.message === 'No new version available') {
    // Device is already on the latest version - this is normal
    console.log('Already up to date');
  } else {
    // Actual error occurred
    console.error('Failed to check for updates:', error);
  }
}
```

In this scenario, the server:
- Logs the request with a "No new version available" message
- Sends a "noNew" stat action to track that the device checked for updates but was already current (done on the backend)

| Param         | Type                                                          | Description                                                                                          |
| ------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#getlatestoptions">GetLatestOptions</a></code> | Optional {@link <a href="#getlatestoptions">GetLatestOptions</a>} to specify which channel to check. |

**Returns:** <code>Promise&lt;<a href="#latestversion">LatestVersion</a>&gt;</code>

**Since:** 4.0.0

--------------------


#### setChannel(...)

```typescript
setChannel(options: SetChannelOptions) => Promise<ChannelRes>
```

Assign this device to a specific update channel at runtime.

Channels allow you to distribute different bundle versions to different groups of users
(e.g., "production", "beta", "staging"). This method switches the device to a new channel.

**Requirements:**
- The target channel must allow self-assignment (configured in your Capgo dashboard or backend)
- The backend may accept or reject the request based on channel settings

**When to use:**
- After the app is ready and the user has interacted (e.g., opted into beta program)
- To implement in-app channel switching (beta toggle, tester access, etc.)
- For user-driven channel changes

**When NOT to use:**
- At app boot/initialization - use {@link PluginsConfig.CapacitorUpdater.defaultChannel} config instead
- Before user interaction

**Important: Listen for the `channelPrivate` event**

When a user attempts to set a channel that doesn't allow device self-assignment, the method will
throw an error AND fire a {@link addListener}('channelPrivate') event. You should listen to this event
to provide appropriate feedback to users:

```typescript
CapacitorUpdater.addListener('channelPrivate', (data) =&gt; {
  console.warn(`Cannot access channel "${data.channel}": ${data.message}`);
  // Show user-friendly message
});
```

This sends a request to the Capgo backend linking your device ID to the specified channel.

| Param         | Type                                                            | Description                                                                                                                  |
| ------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setchanneloptions">SetChannelOptions</a></code> | The {@link <a href="#setchanneloptions">SetChannelOptions</a>} containing the channel name and optional auto-update trigger. |

**Returns:** <code>Promise&lt;<a href="#channelres">ChannelRes</a>&gt;</code>

**Since:** 4.7.0

--------------------


#### unsetChannel(...)

```typescript
unsetChannel(options: UnsetChannelOptions) => Promise<void>
```

Remove the device's channel assignment and return to the default channel.

This unlinks the device from any specifically assigned channel, causing it to fall back to:
- The {@link PluginsConfig.CapacitorUpdater.defaultChannel} if configured, or
- Your backend's default channel for this app

Use this when:
- Users opt out of beta/testing programs
- You want to reset a device to standard update distribution
- Testing channel switching behavior

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#unsetchanneloptions">UnsetChannelOptions</a></code> |

**Since:** 4.7.0

--------------------


#### getChannel()

```typescript
getChannel() => Promise<GetChannelRes>
```

Get the current channel assigned to this device.

Returns information about:
- `channel`: The currently assigned channel name (if any)
- `allowSet`: Whether the channel allows self-assignment
- `status`: Operation status
- `error`/`message`: Additional information (if applicable)

Use this to:
- Display current channel to users (e.g., "You're on the Beta channel")
- Check if a device is on a specific channel before showing features
- Verify channel assignment after calling {@link setChannel}

**Returns:** <code>Promise&lt;<a href="#getchannelres">GetChannelRes</a>&gt;</code>

**Since:** 4.8.0

--------------------


#### listChannels()

```typescript
listChannels() => Promise<ListChannelsResult>
```

Get a list of all channels available for this device to self-assign to.

Only returns channels where `allow_self_set` is `true`. These are channels that
users can switch to using {@link setChannel} without backend administrator intervention.

Each channel includes:
- `id`: Unique channel identifier
- `name`: Human-readable channel name
- `public`: Whether the channel is publicly visible
- `allow_self_set`: Always `true` in results (filtered to only self-assignable channels)

Use this to:
- Build a channel selector UI for users (e.g., "Join Beta" button)
- Show available testing/preview channels
- Implement channel discovery features

**Returns:** <code>Promise&lt;<a href="#listchannelsresult">ListChannelsResult</a>&gt;</code>

**Since:** 7.5.0

--------------------


#### setCustomId(...)

```typescript
setCustomId(options: SetCustomIdOptions) => Promise<void>
```

Set a custom identifier for this device.

This allows you to identify devices by your own custom ID (user ID, account ID, etc.)
instead of or in addition to the device's unique hardware ID. The custom ID is sent
to your update server and can be used for:
- Targeting specific users for updates
- Analytics and user tracking
- Debugging and support (correlating devices with users)
- A/B testing or feature flagging

**Persistence:**
- When {@link PluginsConfig.CapacitorUpdater.persistCustomId} is `true`, the ID persists across app restarts
- When `false`, the ID is only kept for the current session

**Clearing the custom ID:**
- Pass an empty string `""` to remove any stored custom ID

| Param         | Type                                                              | Description                                                                                               |
| ------------- | ----------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setcustomidoptions">SetCustomIdOptions</a></code> | The {@link <a href="#setcustomidoptions">SetCustomIdOptions</a>} containing the custom identifier string. |

**Since:** 4.9.0

--------------------


#### getBuiltinVersion()

```typescript
getBuiltinVersion() => Promise<BuiltinVersion>
```

Get the builtin bundle version (the original version shipped with your native app).

This returns the version of the bundle that was included when the app was installed
from the App Store or Play Store. This is NOT the currently active bundle version -
use {@link current} for that.

Returns:
- The {@link PluginsConfig.CapacitorUpdater.version} config value if set, or
- The native app version from platform configs (package.json, Info.plist, build.gradle)

Use this to:
- Display the "factory" version to users
- Compare against downloaded bundle versions
- Determine if any updates have been applied
- Debugging version mismatches

**Returns:** <code>Promise&lt;<a href="#builtinversion">BuiltinVersion</a>&gt;</code>

**Since:** 5.2.0

--------------------


#### getDeviceId()

```typescript
getDeviceId() => Promise<DeviceId>
```

Get the unique, privacy-friendly identifier for this device.

This ID is used to identify the device when communicating with update servers.
It's automatically generated and stored securely by the plugin.

**Privacy & Security characteristics:**
- Generated as a UUID (not based on hardware identifiers)
- Stored securely in platform-specific secure storage
- Android: Android Keystore (persists across app reinstalls on API 23+)
- iOS: Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- Not synced to cloud (iOS)
- Follows Apple and Google privacy best practices
- Users can clear it via system settings (Android) or keychain access (iOS)

**Persistence:**
The device ID persists across app reinstalls to maintain consistent device identity
for update tracking and analytics.

Use this to:
- Debug update delivery issues (check what ID the server sees)
- Implement device-specific features
- Correlate server logs with specific devices

**Returns:** <code>Promise&lt;<a href="#deviceid">DeviceId</a>&gt;</code>

--------------------


#### getPluginVersion()

```typescript
getPluginVersion() => Promise<PluginVersion>
```

Get the version of the Capacitor Updater plugin installed in your app.

This returns the version of the native plugin code (Android/iOS), which is sent
to the update server with each request. This is NOT your app version or bundle version.

Use this to:
- Debug plugin-specific issues (when reporting bugs)
- Verify plugin installation and version
- Check compatibility with backend features
- Display in debug/about screens

**Returns:** <code>Promise&lt;<a href="#pluginversion">PluginVersion</a>&gt;</code>

--------------------


#### isAutoUpdateEnabled()

```typescript
isAutoUpdateEnabled() => Promise<AutoUpdateEnabled>
```

Check if automatic updates are currently enabled.

Returns `true` if {@link PluginsConfig.CapacitorUpdater.autoUpdate} is enabled,
meaning the plugin will automatically check for, download, and apply updates.

Returns `false` if in manual mode, where you control the update flow using
{@link getLatest}, {@link download}, {@link next}, and {@link set}.

Use this to:
- Determine which update flow your app is using
- Show/hide manual update UI based on mode
- Debug update behavior

**Returns:** <code>Promise&lt;<a href="#autoupdateenabled">AutoUpdateEnabled</a>&gt;</code>

--------------------


#### removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

Remove all event listeners registered for this plugin.

This unregisters all listeners added via {@link addListener} for all event types:
- `download`
- `noNeedUpdate`
- `updateAvailable`
- `downloadComplete`
- `downloadFailed`
- `breakingAvailable` / `majorAvailable`
- `updateFailed`
- `appReloaded`
- `appReady`

Use this during cleanup (e.g., when unmounting components or closing screens)
to prevent memory leaks from lingering event listeners.

**Since:** 1.0.0

--------------------


#### addListener('download', ...)

```typescript
addListener(eventName: 'download', listenerFunc: (state: DownloadEvent) => void) => Promise<PluginListenerHandle>
```

Listen for bundle download event in the App. Fires once a download has started, during downloading and when finished.
This will return you all download percent during the download

| Param              | Type                                                                        |
| ------------------ | --------------------------------------------------------------------------- |
| **`eventName`**    | <code>'download'</code>                                                     |
| **`listenerFunc`** | <code>(state: <a href="#downloadevent">DownloadEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 2.0.11

--------------------


#### addListener('noNeedUpdate', ...)

```typescript
addListener(eventName: 'noNeedUpdate', listenerFunc: (state: NoNeedEvent) => void) => Promise<PluginListenerHandle>
```

Listen for no need to update event, useful when you want force check every time the app is launched

| Param              | Type                                                                    |
| ------------------ | ----------------------------------------------------------------------- |
| **`eventName`**    | <code>'noNeedUpdate'</code>                                             |
| **`listenerFunc`** | <code>(state: <a href="#noneedevent">NoNeedEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 4.0.0

--------------------


#### addListener('updateAvailable', ...)

```typescript
addListener(eventName: 'updateAvailable', listenerFunc: (state: UpdateAvailableEvent) => void) => Promise<PluginListenerHandle>
```

Listen for available update event, useful when you want to force check every time the app is launched

| Param              | Type                                                                                      |
| ------------------ | ----------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'updateAvailable'</code>                                                            |
| **`listenerFunc`** | <code>(state: <a href="#updateavailableevent">UpdateAvailableEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 4.0.0

--------------------


#### addListener('downloadComplete', ...)

```typescript
addListener(eventName: 'downloadComplete', listenerFunc: (state: DownloadCompleteEvent) => void) => Promise<PluginListenerHandle>
```

Listen for downloadComplete events.

| Param              | Type                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'downloadComplete'</code>                                                             |
| **`listenerFunc`** | <code>(state: <a href="#downloadcompleteevent">DownloadCompleteEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 4.0.0

--------------------


#### addListener('breakingAvailable', ...)

```typescript
addListener(eventName: 'breakingAvailable', listenerFunc: (state: BreakingAvailableEvent) => void) => Promise<PluginListenerHandle>
```

Listen for breaking update events when the backend flags an update as incompatible with the current app.
Emits the same payload as the legacy `majorAvailable` listener.

| Param              | Type                                                                                    |
| ------------------ | --------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'breakingAvailable'</code>                                                        |
| **`listenerFunc`** | <code>(state: <a href="#majoravailableevent">MajorAvailableEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 7.22.0

--------------------


#### addListener('majorAvailable', ...)

```typescript
addListener(eventName: 'majorAvailable', listenerFunc: (state: MajorAvailableEvent) => void) => Promise<PluginListenerHandle>
```

Listen for Major update event in the App, let you know when major update is blocked by setting disableAutoUpdateBreaking

| Param              | Type                                                                                    |
| ------------------ | --------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'majorAvailable'</code>                                                           |
| **`listenerFunc`** | <code>(state: <a href="#majoravailableevent">MajorAvailableEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 2.3.0

--------------------


#### addListener('updateFailed', ...)

```typescript
addListener(eventName: 'updateFailed', listenerFunc: (state: UpdateFailedEvent) => void) => Promise<PluginListenerHandle>
```

Listen for update fail event in the App, let you know when update has fail to install at next app start

| Param              | Type                                                                                |
| ------------------ | ----------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'updateFailed'</code>                                                         |
| **`listenerFunc`** | <code>(state: <a href="#updatefailedevent">UpdateFailedEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 2.3.0

--------------------


#### addListener('downloadFailed', ...)

```typescript
addListener(eventName: 'downloadFailed', listenerFunc: (state: DownloadFailedEvent) => void) => Promise<PluginListenerHandle>
```

Listen for download fail event in the App, let you know when a bundle download has failed

| Param              | Type                                                                                    |
| ------------------ | --------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'downloadFailed'</code>                                                           |
| **`listenerFunc`** | <code>(state: <a href="#downloadfailedevent">DownloadFailedEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 4.0.0

--------------------


#### addListener('appReloaded', ...)

```typescript
addListener(eventName: 'appReloaded', listenerFunc: () => void) => Promise<PluginListenerHandle>
```

Listen for reload event in the App, let you know when reload has happened

| Param              | Type                       |
| ------------------ | -------------------------- |
| **`eventName`**    | <code>'appReloaded'</code> |
| **`listenerFunc`** | <code>() =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 4.3.0

--------------------


#### addListener('appReady', ...)

```typescript
addListener(eventName: 'appReady', listenerFunc: (state: AppReadyEvent) => void) => Promise<PluginListenerHandle>
```

Listen for app ready event in the App, let you know when app is ready to use, this event is retain till consumed.

| Param              | Type                                                                        |
| ------------------ | --------------------------------------------------------------------------- |
| **`eventName`**    | <code>'appReady'</code>                                                     |
| **`listenerFunc`** | <code>(state: <a href="#appreadyevent">AppReadyEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 5.1.0

--------------------


#### addListener('channelPrivate', ...)

```typescript
addListener(eventName: 'channelPrivate', listenerFunc: (state: ChannelPrivateEvent) => void) => Promise<PluginListenerHandle>
```

Listen for channel private event, fired when attempting to set a channel that doesn't allow device self-assignment.

This event is useful for:
- Informing users they don't have permission to switch to a specific channel
- Implementing custom error handling for channel restrictions
- Logging unauthorized channel access attempts

| Param              | Type                                                                                    |
| ------------------ | --------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'channelPrivate'</code>                                                           |
| **`listenerFunc`** | <code>(state: <a href="#channelprivateevent">ChannelPrivateEvent</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 7.34.0

--------------------


#### addListener('onFlexibleUpdateStateChange', ...)

```typescript
addListener(eventName: 'onFlexibleUpdateStateChange', listenerFunc: (state: FlexibleUpdateState) => void) => Promise<PluginListenerHandle>
```

Listen for flexible update state changes on Android.

This event fires during the flexible update download process, providing:
- Download progress (bytes downloaded / total bytes)
- Installation status changes

**Install status values:**
- `UNKNOWN` (0): Unknown status
- `PENDING` (1): Download pending
- `DOWNLOADING` (2): Download in progress
- `INSTALLING` (3): Installing the update
- `INSTALLED` (4): Update installed (app restart needed)
- `FAILED` (5): Update failed
- `CANCELED` (6): Update was canceled
- `DOWNLOADED` (11): Download complete, ready to install

When status is `DOWNLOADED`, you should prompt the user and call
{@link completeFlexibleUpdate} to finish the installation.

| Param              | Type                                                                                    |
| ------------------ | --------------------------------------------------------------------------------------- |
| **`eventName`**    | <code>'onFlexibleUpdateStateChange'</code>                                              |
| **`listenerFunc`** | <code>(state: <a href="#flexibleupdatestate">FlexibleUpdateState</a>) =&gt; void</code> |

**Returns:** <code>Promise&lt;<a href="#pluginlistenerhandle">PluginListenerHandle</a>&gt;</code>

**Since:** 8.0.0

--------------------


#### isAutoUpdateAvailable()

```typescript
isAutoUpdateAvailable() => Promise<AutoUpdateAvailable>
```

Check if the auto-update feature is available (not disabled by custom server configuration).

Returns `false` when a custom `updateUrl` is configured, as this typically indicates
you're using a self-hosted update server that may not support all auto-update features.

Returns `true` when using the default Capgo backend or when the feature is available.

This is different from {@link isAutoUpdateEnabled}:
- `isAutoUpdateEnabled()`: Checks if auto-update MODE is turned on/off
- `isAutoUpdateAvailable()`: Checks if auto-update is SUPPORTED with your current configuration

**Returns:** <code>Promise&lt;<a href="#autoupdateavailable">AutoUpdateAvailable</a>&gt;</code>

--------------------


#### getNextBundle()

```typescript
getNextBundle() => Promise<BundleInfo | null>
```

Get information about the bundle queued to be activated on next reload.

Returns:
- {@link <a href="#bundleinfo">BundleInfo</a>} object if a bundle has been queued via {@link next}
- `null` if no update is pending

This is useful to:
- Check if an update is waiting to be applied
- Display "Update pending" status to users
- Show version info of the queued update
- Decide whether to show a "Restart to update" prompt

The queued bundle will be activated when:
- The app is backgrounded (default behavior)
- The app is killed and restarted
- {@link reload} is called manually
- Delay conditions set by {@link setMultiDelay} are met

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a> | null&gt;</code>

**Since:** 6.8.0

--------------------


#### getFailedUpdate()

```typescript
getFailedUpdate() => Promise<UpdateFailedEvent | null>
```

Retrieve information about the most recent bundle that failed to load.

When a bundle fails to load (e.g., JavaScript errors prevent initialization, missing files),
the plugin automatically rolls back and stores information about the failure. This method
retrieves that failure information.

**IMPORTANT: The stored value is cleared after being retrieved once.**
Calling this method multiple times will only return the failure info on the first call,
then `null` on subsequent calls until another failure occurs.

Returns:
- {@link <a href="#updatefailedevent">UpdateFailedEvent</a>} with bundle info if a failure was recorded
- `null` if no failure has occurred or if it was already retrieved

Use this to:
- Show users why an update failed
- Log failure information for debugging
- Implement custom error handling/reporting
- Display rollback notifications

**Returns:** <code>Promise&lt;<a href="#updatefailedevent">UpdateFailedEvent</a> | null&gt;</code>

**Since:** 7.22.0

--------------------


#### setShakeMenu(...)

```typescript
setShakeMenu(options: SetShakeMenuOptions) => Promise<void>
```

Enable or disable the shake gesture menu for debugging and testing.

When enabled, users can shake their device to open a debug menu that shows:
- Current bundle information
- Available bundles
- Options to switch bundles manually
- Update status

This is useful during development and testing to:
- Quickly test different bundle versions
- Debug update flows
- Switch between production and test bundles
- Verify bundle installations

**Important:** Disable this in production builds or only enable for internal testers.

Can also be configured via {@link PluginsConfig.CapacitorUpdater.shakeMenu}.

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#setshakemenuoptions">SetShakeMenuOptions</a></code> |

**Since:** 7.5.0

--------------------


#### isShakeMenuEnabled()

```typescript
isShakeMenuEnabled() => Promise<ShakeMenuEnabled>
```

Check if the shake gesture debug menu is currently enabled.

Returns the current state of the shake menu feature that can be toggled via
{@link setShakeMenu} or configured via {@link PluginsConfig.CapacitorUpdater.shakeMenu}.

Use this to:
- Check if debug features are enabled
- Show/hide debug settings UI
- Verify configuration during testing

**Returns:** <code>Promise&lt;<a href="#shakemenuenabled">ShakeMenuEnabled</a>&gt;</code>

**Since:** 7.5.0

--------------------


#### getAppId()

```typescript
getAppId() => Promise<GetAppIdRes>
```

Get the currently configured App ID used for update server communication.

Returns the App ID that identifies this app to the update server. This can be:
- The value set via {@link setAppId}, or
- The {@link PluginsConfig.CapacitorUpdater.appId} config value, or
- The default app identifier from your native app configuration

Use this to:
- Verify which App ID is being used for updates
- Debug update delivery issues
- Display app configuration in debug screens
- Confirm App ID after calling {@link setAppId}

**Returns:** <code>Promise&lt;<a href="#getappidres">GetAppIdRes</a>&gt;</code>

**Since:** 7.14.0

--------------------


#### setAppId(...)

```typescript
setAppId(options: SetAppIdOptions) => Promise<void>
```

Dynamically change the App ID used for update server communication.

This overrides the App ID used to identify your app to the update server, allowing you
to switch between different app configurations at runtime (e.g., production vs staging
app IDs, or multi-tenant configurations).

**Requirements:**
- {@link PluginsConfig.CapacitorUpdater.allowModifyAppId} must be set to `true`

**Important considerations:**
- Changing the App ID will affect which updates this device receives
- The new App ID must exist on your update server
- This is primarily for advanced use cases (multi-tenancy, environment switching)
- Most apps should use the config-based {@link PluginsConfig.CapacitorUpdater.appId} instead

| Param         | Type                                                        |
| ------------- | ----------------------------------------------------------- |
| **`options`** | <code><a href="#setappidoptions">SetAppIdOptions</a></code> |

**Since:** 7.14.0

--------------------


#### getAppUpdateInfo(...)

```typescript
getAppUpdateInfo(options?: GetAppUpdateInfoOptions | undefined) => Promise<AppUpdateInfo>
```

Get information about the app's availability in the App Store or Play Store.

This method checks the native app stores to see if a newer version of the app
is available for download. This is different from Capgo's OTA updates - this
checks for native app updates that require going through the app stores.

**Platform differences:**
- **Android**: Uses Play Store's In-App Updates API for accurate update information
- **iOS**: Queries the App Store lookup API (requires country code for accurate results)

**Returns information about:**
- Current installed version
- Available version in the store (if any)
- Whether an update is available
- Update priority (Android only)
- Whether immediate/flexible updates are allowed (Android only)

Use this to:
- Check if users need to update from the app store
- Show "Update Available" prompts for native updates
- Implement version gating (require minimum native version)
- Combine with Capgo OTA updates for a complete update strategy

| Param         | Type                                                                        | Description                                                                                                |
| ------------- | --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#getappupdateinfooptions">GetAppUpdateInfoOptions</a></code> | Optional {@link <a href="#getappupdateinfooptions">GetAppUpdateInfoOptions</a>} with country code for iOS. |

**Returns:** <code>Promise&lt;<a href="#appupdateinfo">AppUpdateInfo</a>&gt;</code>

**Since:** 8.0.0

--------------------


#### openAppStore(...)

```typescript
openAppStore(options?: OpenAppStoreOptions | undefined) => Promise<void>
```

Open the app's page in the App Store or Play Store.

This navigates the user to your app's store listing where they can manually
update the app. Use this as a fallback when in-app updates are not available
or when the user needs to update on iOS.

**Platform behavior:**
- **Android**: Opens Play Store to the app's page
- **iOS**: Opens App Store to the app's page

**Customization options:**
- `appId`: Specify a custom App Store ID (iOS) - useful for opening a different app's page
- `packageName`: Specify a custom package name (Android) - useful for opening a different app's page

| Param         | Type                                                                | Description                                                                                                          |
| ------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#openappstoreoptions">OpenAppStoreOptions</a></code> | Optional {@link <a href="#openappstoreoptions">OpenAppStoreOptions</a>} to customize which app's store page to open. |

**Since:** 8.0.0

--------------------


#### performImmediateUpdate()

```typescript
performImmediateUpdate() => Promise<AppUpdateResult>
```

Perform an immediate in-app update on Android.

This triggers Google Play's immediate update flow, which:
1. Shows a full-screen update UI
2. Downloads and installs the update
3. Restarts the app automatically

The user cannot continue using the app until the update is complete.
This is ideal for critical updates that must be installed immediately.

**Requirements:**
- Android only (throws error on iOS)
- An update must be available (check with {@link getAppUpdateInfo} first)
- The update must allow immediate updates (`immediateUpdateAllowed: true`)

**User experience:**
- Full-screen blocking UI
- Progress shown during download
- App automatically restarts after installation

**Returns:** <code>Promise&lt;<a href="#appupdateresult">AppUpdateResult</a>&gt;</code>

**Since:** 8.0.0

--------------------


#### startFlexibleUpdate()

```typescript
startFlexibleUpdate() => Promise<AppUpdateResult>
```

Start a flexible in-app update on Android.

This triggers Google Play's flexible update flow, which:
1. Downloads the update in the background
2. Allows the user to continue using the app
3. Notifies when download is complete
4. Requires calling {@link completeFlexibleUpdate} to install

Monitor the download progress using the `onFlexibleUpdateStateChange` listener.

**Requirements:**
- Android only (throws error on iOS)
- An update must be available (check with {@link getAppUpdateInfo} first)
- The update must allow flexible updates (`flexibleUpdateAllowed: true`)

**Typical flow:**
1. Call `startFlexibleUpdate()` to begin download
2. Listen to `onFlexibleUpdateStateChange` for progress
3. When status is `DOWNLOADED`, prompt user to restart
4. Call `completeFlexibleUpdate()` to install and restart

**Returns:** <code>Promise&lt;<a href="#appupdateresult">AppUpdateResult</a>&gt;</code>

**Since:** 8.0.0

--------------------


#### completeFlexibleUpdate()

```typescript
completeFlexibleUpdate() => Promise<void>
```

Complete a flexible in-app update on Android.

After a flexible update has been downloaded (status `DOWNLOADED` in
`onFlexibleUpdateStateChange`), call this method to install the update
and restart the app.

**Important:** This will immediately restart the app. Make sure to:
- Save any user data before calling
- Prompt the user before restarting
- Only call when the download status is `DOWNLOADED`

**Since:** 8.0.0

--------------------


#### Interfaces


##### AppReadyResult

| Prop         | Type                                              |
| ------------ | ------------------------------------------------- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> |


##### BundleInfo

| Prop             | Type                                                  |
| ---------------- | ----------------------------------------------------- |
| **`id`**         | <code>string</code>                                   |
| **`version`**    | <code>string</code>                                   |
| **`downloaded`** | <code>string</code>                                   |
| **`checksum`**   | <code>string</code>                                   |
| **`status`**     | <code><a href="#bundlestatus">BundleStatus</a></code> |


##### UpdateUrl

| Prop      | Type                |
| --------- | ------------------- |
| **`url`** | <code>string</code> |


##### StatsUrl

| Prop      | Type                |
| --------- | ------------------- |
| **`url`** | <code>string</code> |


##### ChannelUrl

| Prop      | Type                |
| --------- | ------------------- |
| **`url`** | <code>string</code> |


##### DownloadOptions

This URL and versions are used to download the bundle from the server, If you use backend all information will be given by the method getLatest.
If you don't use backend, you need to provide the URL and version of the bundle. Checksum and sessionKey are required if you encrypted the bundle with the CLI command encrypt, you should receive them as result of the command.

| Prop             | Type                         | Description                                                                                                                                                      | Default                | Since |
| ---------------- | ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ----- |
| **`url`**        | <code>string</code>          | The URL of the bundle zip file (e.g: dist.zip) to be downloaded. (This can be any URL. E.g: Amazon S3, a GitHub tag, any other place you've hosted your bundle.) |                        |       |
| **`version`**    | <code>string</code>          | The version code/name of this bundle/version                                                                                                                     |                        |       |
| **`sessionKey`** | <code>string</code>          | The session key for the update, when the bundle is encrypted with a session key                                                                                  | <code>undefined</code> | 4.0.0 |
| **`checksum`**   | <code>string</code>          | The checksum for the update, it should be in sha256 and encrypted with private key if the bundle is encrypted                                                    | <code>undefined</code> | 4.0.0 |
| **`manifest`**   | <code>ManifestEntry[]</code> | The manifest for multi-file downloads                                                                                                                            | <code>undefined</code> | 6.1.0 |


##### ManifestEntry

| Prop               | Type                        |
| ------------------ | --------------------------- |
| **`file_name`**    | <code>string \| null</code> |
| **`file_hash`**    | <code>string \| null</code> |
| **`download_url`** | <code>string \| null</code> |


##### BundleId

| Prop     | Type                |
| -------- | ------------------- |
| **`id`** | <code>string</code> |


##### BundleListResult

| Prop          | Type                      |
| ------------- | ------------------------- |
| **`bundles`** | <code>BundleInfo[]</code> |


##### ListOptions

| Prop      | Type                 | Description                                                                                                                                   | Default            | Since  |
| --------- | -------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ------ |
| **`raw`** | <code>boolean</code> | Whether to return the raw bundle list or the manifest. If true, the list will attempt to read the internal database instead of files on disk. | <code>false</code> | 6.14.0 |


##### ResetOptions

| Prop                   | Type                 |
| ---------------------- | -------------------- |
| **`toLastSuccessful`** | <code>boolean</code> |


##### CurrentBundleResult

| Prop         | Type                                              |
| ------------ | ------------------------------------------------- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> |
| **`native`** | <code>string</code>                               |


##### MultiDelayConditions

| Prop                  | Type                          |
| --------------------- | ----------------------------- |
| **`delayConditions`** | <code>DelayCondition[]</code> |


##### DelayCondition

| Prop        | Type                                                      | Description                              |
| ----------- | --------------------------------------------------------- | ---------------------------------------- |
| **`kind`**  | <code><a href="#delayuntilnext">DelayUntilNext</a></code> | Set up delay conditions in setMultiDelay |
| **`value`** | <code>string</code>                                       |                                          |


##### LatestVersion

| Prop             | Type                         | Description                                                                                                                                                                                                   | Since  |
| ---------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| **`version`**    | <code>string</code>          | Result of getLatest method                                                                                                                                                                                    | 4.0.0  |
| **`checksum`**   | <code>string</code>          |                                                                                                                                                                                                               | 6      |
| **`breaking`**   | <code>boolean</code>         | Indicates whether the update was flagged as breaking by the backend.                                                                                                                                          | 7.22.0 |
| **`major`**      | <code>boolean</code>         |                                                                                                                                                                                                               |        |
| **`message`**    | <code>string</code>          | Optional message from the server. When no new version is available, this will be "No new version available".                                                                                                  |        |
| **`sessionKey`** | <code>string</code>          |                                                                                                                                                                                                               |        |
| **`error`**      | <code>string</code>          | Error code from the server, if any. Common values: - `"no_new_version_available"`: Device is already on the latest version (not a failure) - Other error codes indicate actual failures in the update process |        |
| **`old`**        | <code>string</code>          | The previous/current version name (provided for reference).                                                                                                                                                   |        |
| **`url`**        | <code>string</code>          | Download URL for the bundle (when a new version is available).                                                                                                                                                |        |
| **`manifest`**   | <code>ManifestEntry[]</code> | File list for partial updates (when using multi-file downloads).                                                                                                                                              | 6.1    |
| **`link`**       | <code>string</code>          | Optional link associated with this bundle version (e.g., release notes URL, changelog, GitHub release).                                                                                                       | 7.35.0 |
| **`comment`**    | <code>string</code>          | Optional comment or description for this bundle version.                                                                                                                                                      | 7.35.0 |


##### GetLatestOptions

| Prop          | Type                | Description                                                                                     | Default                | Since |
| ------------- | ------------------- | ----------------------------------------------------------------------------------------------- | ---------------------- | ----- |
| **`channel`** | <code>string</code> | The channel to get the latest version for The channel must allow 'self_assign' for this to work | <code>undefined</code> | 6.8.0 |


##### ChannelRes

| Prop          | Type                | Description                   | Since |
| ------------- | ------------------- | ----------------------------- | ----- |
| **`status`**  | <code>string</code> | Current status of set channel | 4.7.0 |
| **`error`**   | <code>string</code> |                               |       |
| **`message`** | <code>string</code> |                               |       |


##### SetChannelOptions

| Prop                    | Type                 |
| ----------------------- | -------------------- |
| **`channel`**           | <code>string</code>  |
| **`triggerAutoUpdate`** | <code>boolean</code> |


##### UnsetChannelOptions

| Prop                    | Type                 |
| ----------------------- | -------------------- |
| **`triggerAutoUpdate`** | <code>boolean</code> |


##### GetChannelRes

| Prop           | Type                 | Description                   | Since |
| -------------- | -------------------- | ----------------------------- | ----- |
| **`channel`**  | <code>string</code>  | Current status of get channel | 4.8.0 |
| **`error`**    | <code>string</code>  |                               |       |
| **`message`**  | <code>string</code>  |                               |       |
| **`status`**   | <code>string</code>  |                               |       |
| **`allowSet`** | <code>boolean</code> |                               |       |


##### ListChannelsResult

| Prop           | Type                       | Description                | Since |
| -------------- | -------------------------- | -------------------------- | ----- |
| **`channels`** | <code>ChannelInfo[]</code> | List of available channels | 7.5.0 |


##### ChannelInfo

| Prop                 | Type                 | Description                                     | Since |
| -------------------- | -------------------- | ----------------------------------------------- | ----- |
| **`id`**             | <code>string</code>  | The channel ID                                  | 7.5.0 |
| **`name`**           | <code>string</code>  | The channel name                                | 7.5.0 |
| **`public`**         | <code>boolean</code> | Whether this is a public channel                | 7.5.0 |
| **`allow_self_set`** | <code>boolean</code> | Whether devices can self-assign to this channel | 7.5.0 |


##### SetCustomIdOptions

| Prop           | Type                | Description                                                                                   |
| -------------- | ------------------- | --------------------------------------------------------------------------------------------- |
| **`customId`** | <code>string</code> | Custom identifier to associate with the device. Use an empty string to clear any saved value. |


##### BuiltinVersion

| Prop          | Type                |
| ------------- | ------------------- |
| **`version`** | <code>string</code> |


##### DeviceId

| Prop           | Type                |
| -------------- | ------------------- |
| **`deviceId`** | <code>string</code> |


##### PluginVersion

| Prop          | Type                |
| ------------- | ------------------- |
| **`version`** | <code>string</code> |


##### AutoUpdateEnabled

| Prop          | Type                 |
| ------------- | -------------------- |
| **`enabled`** | <code>boolean</code> |


##### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


##### DownloadEvent

| Prop          | Type                                              | Description                                    | Since |
| ------------- | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`percent`** | <code>number</code>                               | Current status of download, between 0 and 100. | 4.0.0 |
| **`bundle`**  | <code><a href="#bundleinfo">BundleInfo</a></code> |                                                |       |


##### NoNeedEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


##### UpdateAvailableEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


##### DownloadCompleteEvent

| Prop         | Type                                              | Description                          | Since |
| ------------ | ------------------------------------------------- | ------------------------------------ | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a new update is available. | 4.0.0 |


##### MajorAvailableEvent

| Prop          | Type                | Description                               | Since |
| ------------- | ------------------- | ----------------------------------------- | ----- |
| **`version`** | <code>string</code> | Emit when a breaking update is available. | 4.0.0 |


##### UpdateFailedEvent

| Prop         | Type                                              | Description                           | Since |
| ------------ | ------------------------------------------------- | ------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a update failed to install. | 4.0.0 |


##### DownloadFailedEvent

| Prop          | Type                | Description                | Since |
| ------------- | ------------------- | -------------------------- | ----- |
| **`version`** | <code>string</code> | Emit when a download fail. | 4.0.0 |


##### AppReadyEvent

| Prop         | Type                                              | Description                           | Since |
| ------------ | ------------------------------------------------- | ------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emitted when the app is ready to use. | 5.2.0 |
| **`status`** | <code>string</code>                               |                                       |       |


##### ChannelPrivateEvent

| Prop          | Type                | Description                                                                         | Since  |
| ------------- | ------------------- | ----------------------------------------------------------------------------------- | ------ |
| **`channel`** | <code>string</code> | Emitted when attempting to set a channel that doesn't allow device self-assignment. | 7.34.0 |
| **`message`** | <code>string</code> |                                                                                     |        |


##### FlexibleUpdateState

State information for flexible update progress (Android only).

| Prop                       | Type                                                                                | Description                                                                        | Since |
| -------------------------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ----- |
| **`installStatus`**        | <code><a href="#flexibleupdateinstallstatus">FlexibleUpdateInstallStatus</a></code> | The current installation status.                                                   | 8.0.0 |
| **`bytesDownloaded`**      | <code>number</code>                                                                 | Number of bytes downloaded so far. Only available during the `DOWNLOADING` status. | 8.0.0 |
| **`totalBytesToDownload`** | <code>number</code>                                                                 | Total number of bytes to download. Only available during the `DOWNLOADING` status. | 8.0.0 |


##### AutoUpdateAvailable

| Prop            | Type                 |
| --------------- | -------------------- |
| **`available`** | <code>boolean</code> |


##### SetShakeMenuOptions

| Prop          | Type                 |
| ------------- | -------------------- |
| **`enabled`** | <code>boolean</code> |


##### ShakeMenuEnabled

| Prop          | Type                 |
| ------------- | -------------------- |
| **`enabled`** | <code>boolean</code> |


##### GetAppIdRes

| Prop        | Type                |
| ----------- | ------------------- |
| **`appId`** | <code>string</code> |


##### SetAppIdOptions

| Prop        | Type                |
| ----------- | ------------------- |
| **`appId`** | <code>string</code> |


##### AppUpdateInfo

Information about app updates available in the App Store or Play Store.

| Prop                              | Type                                                                                | Description                                                                                                                                                                                                              | Since |
| --------------------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| **`currentVersionName`**          | <code>string</code>                                                                 | The currently installed version name (e.g., "1.2.3").                                                                                                                                                                    | 8.0.0 |
| **`availableVersionName`**        | <code>string</code>                                                                 | The version name available in the store, if an update is available. May be undefined if no update information is available.                                                                                              | 8.0.0 |
| **`currentVersionCode`**          | <code>string</code>                                                                 | The currently installed version code (Android) or build number (iOS).                                                                                                                                                    | 8.0.0 |
| **`availableVersionCode`**        | <code>string</code>                                                                 | The version code available in the store (Android only). On iOS, this will be the same as `availableVersionName`.                                                                                                         | 8.0.0 |
| **`availableVersionReleaseDate`** | <code>string</code>                                                                 | The release date of the available version (iOS only). Format: ISO 8601 date string.                                                                                                                                      | 8.0.0 |
| **`updateAvailability`**          | <code><a href="#appupdateavailability">AppUpdateAvailability</a></code>             | The current update availability status.                                                                                                                                                                                  | 8.0.0 |
| **`updatePriority`**              | <code>number</code>                                                                 | The priority of the update as set by the developer in Play Console (Android only). Values range from 0 (default/lowest) to 5 (highest priority). Use this to decide whether to show an update prompt or force an update. | 8.0.0 |
| **`immediateUpdateAllowed`**      | <code>boolean</code>                                                                | Whether an immediate update is allowed (Android only). If `true`, you can call {@link CapacitorUpdaterPlugin.performImmediateUpdate}.                                                                                    | 8.0.0 |
| **`flexibleUpdateAllowed`**       | <code>boolean</code>                                                                | Whether a flexible update is allowed (Android only). If `true`, you can call {@link CapacitorUpdaterPlugin.startFlexibleUpdate}.                                                                                         | 8.0.0 |
| **`clientVersionStalenessDays`**  | <code>number</code>                                                                 | Number of days since the update became available (Android only). Use this to implement "update nagging" - remind users more frequently as the update ages.                                                               | 8.0.0 |
| **`installStatus`**               | <code><a href="#flexibleupdateinstallstatus">FlexibleUpdateInstallStatus</a></code> | The current install status of a flexible update (Android only).                                                                                                                                                          | 8.0.0 |
| **`minimumOsVersion`**            | <code>string</code>                                                                 | The minimum OS version required for the available update (iOS only).                                                                                                                                                     | 8.0.0 |


##### GetAppUpdateInfoOptions

Options for {@link CapacitorUpdaterPlugin.getAppUpdateInfo}.

| Prop          | Type                | Description                                                                                                                                                                                                                                                                                                                     | Since |
| ------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **`country`** | <code>string</code> | Two-letter country code (ISO 3166-1 alpha-2) for the App Store lookup. This is required on iOS to get accurate App Store information, as app availability and versions can vary by country. Examples: "US", "GB", "DE", "JP", "FR" On Android, this option is ignored as the Play Store handles region detection automatically. | 8.0.0 |


##### OpenAppStoreOptions

Options for {@link CapacitorUpdaterPlugin.openAppStore}.

| Prop              | Type                | Description                                                                                                                                                                                                  | Since |
| ----------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| **`packageName`** | <code>string</code> | The Android package name to open in the Play Store. If not specified, uses the current app's package name. Use this to open a different app's store page. Only used on Android.                              | 8.0.0 |
| **`appId`**       | <code>string</code> | The iOS App Store ID to open. If not specified, uses the current app's bundle identifier to look up the app. Use this to open a different app's store page or when automatic lookup fails. Only used on iOS. | 8.0.0 |


##### AppUpdateResult

Result of an app update operation.

| Prop       | Type                                                                | Description                              | Since |
| ---------- | ------------------------------------------------------------------- | ---------------------------------------- | ----- |
| **`code`** | <code><a href="#appupdateresultcode">AppUpdateResultCode</a></code> | The result code of the update operation. | 8.0.0 |


#### Type Aliases


##### BundleStatus

pending: The bundle is pending to be **SET** as the next bundle.
downloading: The bundle is being downloaded.
success: The bundle has been downloaded and is ready to be **SET** as the next bundle.
error: The bundle has failed to download.

<code>'success' | 'error' | 'pending' | 'downloading'</code>


##### DelayUntilNext

<code>'background' | 'kill' | 'nativeVersion' | 'date'</code>


##### BreakingAvailableEvent

Payload emitted by {@link CapacitorUpdaterPlugin.addListener} with `breakingAvailable`.

<code><a href="#majoravailableevent">MajorAvailableEvent</a></code>


#### Enums


##### FlexibleUpdateInstallStatus

| Members           | Value           | Description                                                                                                                    |
| ----------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **`UNKNOWN`**     | <code>0</code>  | Unknown install status.                                                                                                        |
| **`PENDING`**     | <code>1</code>  | Download is pending and will start soon.                                                                                       |
| **`DOWNLOADING`** | <code>2</code>  | Download is in progress. Check `bytesDownloaded` and `totalBytesToDownload` for progress.                                      |
| **`INSTALLING`**  | <code>3</code>  | The update is being installed.                                                                                                 |
| **`INSTALLED`**   | <code>4</code>  | The update has been installed. The app needs to be restarted to use the new version.                                           |
| **`FAILED`**      | <code>5</code>  | The update failed to download or install.                                                                                      |
| **`CANCELED`**    | <code>6</code>  | The update was canceled by the user.                                                                                           |
| **`DOWNLOADED`**  | <code>11</code> | The update has been downloaded and is ready to install. Call {@link CapacitorUpdaterPlugin.completeFlexibleUpdate} to install. |


##### AppUpdateAvailability

| Members                    | Value          | Description                                                                                |
| -------------------------- | -------------- | ------------------------------------------------------------------------------------------ |
| **`UNKNOWN`**              | <code>0</code> | Update availability is unknown. This typically means the check hasn't completed or failed. |
| **`UPDATE_NOT_AVAILABLE`** | <code>1</code> | No update is available. The installed version is the latest.                               |
| **`UPDATE_AVAILABLE`**     | <code>2</code> | An update is available for download.                                                       |
| **`UPDATE_IN_PROGRESS`**   | <code>3</code> | An update is currently being downloaded or installed.                                      |


##### AppUpdateResultCode

| Members             | Value          | Description                                                                                                                 |
| ------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **`OK`**            | <code>0</code> | The update completed successfully.                                                                                          |
| **`CANCELED`**      | <code>1</code> | The user canceled the update.                                                                                               |
| **`FAILED`**        | <code>2</code> | The update failed.                                                                                                          |
| **`NOT_AVAILABLE`** | <code>3</code> | No update is available.                                                                                                     |
| **`NOT_ALLOWED`**   | <code>4</code> | The requested update type is not allowed. For example, trying to perform an immediate update when only flexible is allowed. |
| **`INFO_MISSING`**  | <code>5</code> | Required information is missing. This can happen if {@link CapacitorUpdaterPlugin.getAppUpdateInfo} wasn't called first.    |

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

[jamesyoung1337](https://github.com/jamesyoung1337) Thank you so much for your guidance and support, it was impossible to make this plugin work without you.
