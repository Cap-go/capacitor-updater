---
title: "Functions and settings"
description: "All available method and settings of the plugin"
sidebar:
  order: 2
---

# Updater Plugin Config

<docgen-config>
<!--Update the source file JSDoc comments and rerun docgen to update the docs below-->

CapacitorUpdater can be configured with these options:

| Prop | Type | Description | Default | Since |
| --- | --- | --- | --- | --- |
| **`appReadyTimeout`** | `number` | Configure the number of milliseconds the native plugin should wait before considering an update 'failed'. Only available for Android and iOS. | `10000 // (10 seconds)` |  |
| **`responseTimeout`** | `number` | Configure the number of seconds the native plugin should wait before considering API timeout. Only available for Android and iOS. | `20 // (20 second)` |  |
| **`autoDeleteFailed`** | `boolean` | Configure whether the plugin should use automatically delete failed bundles. Only available for Android and iOS. | `true` |  |
| **`autoDeletePrevious`** | `boolean` | Configure whether the plugin should use automatically delete previous bundles after a successful update. Only available for Android and iOS. | `true` |  |
| **`autoUpdate`** | `boolean` | Configure whether the plugin should use Auto Update via an update server. Only available for Android and iOS. | `true` |  |
| **`resetWhenUpdate`** | `boolean` | Automatically delete previous downloaded bundles when a newer native app bundle is installed to the device. Setting this to false can broke the auto update flow if the user download from the store a native app bundle that is older than the current downloaded bundle. Upload will be prevented by channel setting downgrade_under_native. Only available for Android and iOS. | `true` |  |
| **`updateUrl`** | `string` | Configure the URL / endpoint to which update checks are sent. Only available for Android and iOS. | `https://plugin.capgo.app/updates` |  |
| **`channelUrl`** | `string` | Configure the URL / endpoint for channel operations. Only available for Android and iOS. | `https://plugin.capgo.app/channel_self` |  |
| **`statsUrl`** | `string` | Configure the URL / endpoint to which update statistics are sent. Only available for Android and iOS. Set to "" to disable stats reporting. | `https://plugin.capgo.app/stats` |  |
| **`publicKey`** | `string` | Configure the public key for end to end live update encryption Version 2 Only available for Android and iOS. | `undefined` | 6.2.0 |
| **`version`** | `string` | Configure the current version of the app. This will be used for the first update request. If not set, the plugin will get the version from the native code. Only available for Android and iOS. | `undefined` | 4.17.48 |
| **`directUpdate`** | `boolean | 'always' | 'atInstall' | 'onLaunch'` | Configure when the plugin should direct install updates. Only for autoUpdate mode. Works well for apps less than 10MB and with uploads done using --partial flag. Zip or apps more than 10MB will be relatively slow for users to update. - false: Never do direct updates (use default behavior: download at start, set when backgrounded) - atInstall: Direct update only when app is installed, updated from store, otherwise act as directUpdate = false - onLaunch: Direct update only on app installed, updated from store or after app kill, otherwise act as directUpdate = false - always: Direct update in all previous cases (app installed, updated from store, after app kill or app resume), never act as directUpdate = false - true: (deprecated) Same as "always" for backward compatibility Only available for Android and iOS. | `false` | 5.1.0 |
| **`autoSplashscreen`** | `boolean` | Automatically handle splashscreen hiding when using directUpdate. When enabled, the plugin will automatically hide the splashscreen after updates are applied or when no update is needed. This removes the need to manually listen for appReady events and call SplashScreen.hide(). Only works when directUpdate is set to "atInstall", "always", "onLaunch", or true. Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false. Requires autoUpdate and directUpdate to be enabled. Only available for Android and iOS. | `false` | 7.6.0 |
| **`autoSplashscreenLoader`** | `boolean` | Display a native loading indicator on top of the splashscreen while automatic direct updates are running. Only takes effect when {@link autoSplashscreen} is enabled. Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false. Only available for Android and iOS. | `false` | 7.19.0 |
| **`autoSplashscreenTimeout`** | `number` | Automatically hide the splashscreen after the specified number of milliseconds when using automatic direct updates. If the timeout elapses, the update continues to download in the background while the splashscreen is dismissed. Set to `0` (zero) to disable the timeout. When the timeout fires, the direct update flow is skipped and the downloaded bundle is installed on the next background/launch. Requires {@link autoSplashscreen} to be enabled. Only available for Android and iOS. | `10000 // (10 seconds)` | 7.19.0 |
| **`periodCheckDelay`** | `number` | Configure the delay period for period update check. the unit is in seconds. Only available for Android and iOS. Cannot be less than 600 seconds (10 minutes). | `0 (disabled)` |  |
| **`localS3`** | `boolean` | Configure the CLI to use a local server for testing or self-hosted update server. | `undefined` | 4.17.48 |
| **`localHost`** | `string` | Configure the CLI to use a local server for testing or self-hosted update server. | `undefined` | 4.17.48 |
| **`localWebHost`** | `string` | Configure the CLI to use a local server for testing or self-hosted update server. | `undefined` | 4.17.48 |
| **`localSupa`** | `string` | Configure the CLI to use a local server for testing or self-hosted update server. | `undefined` | 4.17.48 |
| **`localSupaAnon`** | `string` | Configure the CLI to use a local server for testing. | `undefined` | 4.17.48 |
| **`localApi`** | `string` | Configure the CLI to use a local api for testing. | `undefined` | 6.3.3 |
| **`localApiFiles`** | `string` | Configure the CLI to use a local file api for testing. | `undefined` | 6.3.3 |
| **`allowModifyUrl`** | `boolean` | Allow the plugin to modify the updateUrl, statsUrl and channelUrl dynamically from the JavaScript side. | `false` | 5.4.0 |
| **`allowModifyAppId`** | `boolean` | Allow the plugin to modify the appId dynamically from the JavaScript side. | `false` | 7.14.0 |
| **`allowManualBundleError`** | `boolean` | Allow marking bundles as errored from JavaScript while using manual update flows. When enabled, {@link CapacitorUpdaterPlugin.setBundleError} can change a bundle status to `error`. | `false` | 7.20.0 |
| **`persistCustomId`** | `boolean` | Persist the customId set through {@link CapacitorUpdaterPlugin.setCustomId} across app restarts. Only available for Android and iOS. | `false (will be true by default in a future major release v8.x.x)` | 7.17.3 |
| **`persistModifyUrl`** | `boolean` | Persist the updateUrl, statsUrl and channelUrl set through {@link CapacitorUpdaterPlugin.setUpdateUrl}, {@link CapacitorUpdaterPlugin.setStatsUrl} and {@link CapacitorUpdaterPlugin.setChannelUrl} across app restarts. Only available for Android and iOS. | `false` | 7.20.0 |
| **`allowSetDefaultChannel`** | `boolean` | Allow or disallow the {@link CapacitorUpdaterPlugin.setChannel} method to modify the defaultChannel. When set to `false`, calling `setChannel()` will return an error with code `disabled_by_config`. | `true` | 7.34.0 |
| **`defaultChannel`** | `string` | Set the default channel for the app in the config. Case sensitive. This will setting will override the default channel set in the cloud, but will still respect overrides made in the cloud. This requires the channel to allow devices to self dissociate/associate in the channel settings. https://capgo.app/docs/public-api/channels/#channel-configuration-options | `undefined` | 5.5.0 |
| **`appId`** | `string` | Configure the app id for the app in the config. | `undefined` | 6.0.0 |
| **`keepUrlPathAfterReload`** | `boolean` | Configure the plugin to keep the URL path after a reload. WARNING: When a reload is triggered, 'window.history' will be cleared. | `false` | 6.8.0 |
| **`disableJSLogging`** | `boolean` | Disable the JavaScript logging of the plugin. if true, the plugin will not log to the JavaScript console. only the native log will be done | `false` | 7.3.0 |
| **`shakeMenu`** | `boolean` | Enable shake gesture to show update menu for debugging/testing purposes | `false` | 7.5.0 |


</docgen-config>

## API Reference

<docgen-index>
<!--Auto-generated, do not edit by hand-->

- [`notifyAppReady`](#notifyappready)
- [`setUpdateUrl`](#setupdateurl)
- [`setStatsUrl`](#setstatsurl)
- [`setChannelUrl`](#setchannelurl)
- [`download`](#download)
- [`next`](#next)
- [`set`](#set)
- [`delete`](#delete)
- [`setBundleError`](#setbundleerror)
- [`list`](#list)
- [`reset`](#reset)
- [`current`](#current)
- [`reload`](#reload)
- [`setMultiDelay`](#setmultidelay)
- [`cancelDelay`](#canceldelay)
- [`getLatest`](#getlatest)
- [`setChannel`](#setchannel)
- [`unsetChannel`](#unsetchannel)
- [`getChannel`](#getchannel)
- [`listChannels`](#listchannels)
- [`setCustomId`](#setcustomid)
- [`getBuiltinVersion`](#getbuiltinversion)
- [`getDeviceId`](#getdeviceid)
- [`getPluginVersion`](#getpluginversion)
- [`isAutoUpdateEnabled`](#isautoupdateenabled)
- [`removeAllListeners`](#removealllisteners)
- [`addListener('download')`](#addlistenerdownload-)
- [`addListener('noNeedUpdate')`](#addlistenernoneedupdate-)
- [`addListener('updateAvailable')`](#addlistenerupdateavailable-)
- [`addListener('downloadComplete')`](#addlistenerdownloadcomplete-)
- [`addListener('breakingAvailable')`](#addlistenerbreakingavailable-)
- [`addListener('majorAvailable')`](#addlistenermajoravailable-)
- [`addListener('updateFailed')`](#addlistenerupdatefailed-)
- [`addListener('downloadFailed')`](#addlistenerdownloadfailed-)
- [`addListener('appReloaded')`](#addlistenerappreloaded-)
- [`addListener('appReady')`](#addlistenerappready-)
- [`addListener('channelPrivate')`](#addlistenerchannelprivate-)
- [`addListener('onFlexibleUpdateStateChange')`](#addlisteneronflexibleupdatestatechange-)
- [`isAutoUpdateAvailable`](#isautoupdateavailable)
- [`getNextBundle`](#getnextbundle)
- [`getFailedUpdate`](#getfailedupdate)
- [`setShakeMenu`](#setshakemenu)
- [`isShakeMenuEnabled`](#isshakemenuenabled)
- [`getAppId`](#getappid)
- [`setAppId`](#setappid)
- [`getAppUpdateInfo`](#getappupdateinfo)
- [`openAppStore`](#openappstore)
- [`performImmediateUpdate`](#performimmediateupdate)
- [`startFlexibleUpdate`](#startflexibleupdate)
- [`completeFlexibleUpdate`](#completeflexibleupdate)

</docgen-index>

<docgen-api>
<!--Auto-generated, do not edit by hand-->

### notifyAppReady

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

**Returns**

`Promise<AppReadyResult>` — Always resolves successfully with current bundle info. This method never fails.


--------------------


### setUpdateUrl

```typescript
setUpdateUrl(options: UpdateUrl) => Promise<void>
```

Set the update URL for the app dynamically at runtime.

This overrides the {@link PluginsConfig.CapacitorUpdater.updateUrl} config value.
Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.

Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
Otherwise, the URL will reset to the config value on next app launch.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `UpdateUrl` | Contains the URL to use for checking for updates. |

**Returns**

`Promise<void>` — Resolves when the URL is successfully updated.

**Since:** 5.4.0

**Throws:** {Error} If `allowModifyUrl` is false or if the operation fails.


--------------------


### setStatsUrl

```typescript
setStatsUrl(options: StatsUrl) => Promise<void>
```

Set the statistics URL for the app dynamically at runtime.

This overrides the {@link PluginsConfig.CapacitorUpdater.statsUrl} config value.
Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.

Pass an empty string to disable statistics gathering entirely.
Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `StatsUrl` | Contains the URL to use for sending statistics, or an empty string to disable. |

**Returns**

`Promise<void>` — Resolves when the URL is successfully updated.

**Since:** 5.4.0

**Throws:** {Error} If `allowModifyUrl` is false or if the operation fails.


--------------------


### setChannelUrl

```typescript
setChannelUrl(options: ChannelUrl) => Promise<void>
```

Set the channel URL for the app dynamically at runtime.

This overrides the {@link PluginsConfig.CapacitorUpdater.channelUrl} config value.
Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.

Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
Otherwise, the URL will reset to the config value on next app launch.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `ChannelUrl` | Contains the URL to use for channel operations. |

**Returns**

`Promise<void>` — Resolves when the URL is successfully updated.

**Since:** 5.4.0

**Throws:** {Error} If `allowModifyUrl` is false or if the operation fails.


--------------------


### download

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `DownloadOptions` | The {@link DownloadOptions} for downloading a new bundle zip. |

**Returns**

`Promise<BundleInfo>` — The {@link BundleInfo} for the downloaded bundle.

**Throws:** {Error} If the download fails or the bundle is invalid.

**Example**

```ts
const bundle = await CapacitorUpdater.download({
  url: `https://example.com/versions/${version}/dist.zip`,
  version: version
});
// Bundle is downloaded but not active yet
await CapacitorUpdater.next({ id: bundle.id }); // Will activate on next background
```


--------------------


### next

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | Contains the ID of the bundle to set as next. Use {@link BundleInfo.id} from a downloaded bundle. |

**Returns**

`Promise<BundleInfo>` — The {@link BundleInfo} for the specified bundle.

**Throws:** {Error} When there is no index.html file inside the bundle folder or the bundle doesn't exist.


--------------------


### set

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | A {@link BundleId} object containing the new bundle id to set as current. |

**Returns**

`Promise<void>` — A promise that will never resolve because the JavaScript context is destroyed.

**Throws:** {Error} When there is no index.html file inside the bundle folder.


--------------------


### delete

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
Use the `id` field from {@link BundleInfo}, not the `version` field.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | A {@link BundleId} object containing the bundle ID to delete. |

**Returns**

`Promise<void>` — Resolves when the bundle is successfully deleted.

**Throws:** {Error} If the bundle is currently in use or doesn't exist.


--------------------


### setBundleError

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | A {@link BundleId} object containing the bundle ID to mark as errored. |

**Returns**

`Promise<BundleInfo>` — The updated {@link BundleInfo} with status set to `error`.

**Since:** 7.20.0

**Throws:** {Error} When the bundle does not exist or `allowManualBundleError` is false.


--------------------


### list

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `ListOptions | undefined` | The {@link ListOptions} for customizing the bundle list output. |

**Returns**

`Promise<BundleListResult>` — A promise containing the array of {@link BundleInfo} objects.

**Throws:** {Error} If the operation fails.


--------------------


### reset

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `ResetOptions | undefined` |  |

**Returns**

`Promise<void>` — A promise that may never resolve because the app will be reloaded.

**Throws:** {Error} If the reset operation fails.


--------------------


### current

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

**Returns**

`Promise<CurrentBundleResult>` — A promise with the current bundle and native version info.

**Throws:** {Error} If the operation fails.


--------------------


### reload

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

**Returns**

`Promise<void>` — A promise that may never resolve because the app will be reloaded.

**Throws:** {Error} If the reload operation fails.


--------------------


### setMultiDelay

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `MultiDelayConditions` | Contains the {@link MultiDelayConditions} array of conditions. |

**Returns**

`Promise<void>` — Resolves when the delay conditions are set.

**Since:** 4.3.0

**Throws:** {Error} If the operation fails or conditions are invalid.

**Example**

```ts
// Update after user kills app OR after 5 minutes in background
await CapacitorUpdater.setMultiDelay({
  delayConditions: [
    { kind: 'kill' },
    { kind: 'background', value: '300000' }
  ]
});
```

**Example**

```ts
// Update after a specific date
await CapacitorUpdater.setMultiDelay({
  delayConditions: [{ kind: 'date', value: '2025-12-31T23:59:59Z' }]
});
```

**Example**

```ts
// Default behavior: update on next background
await CapacitorUpdater.setMultiDelay({
  delayConditions: [{ kind: 'background' }]
});
```


--------------------


### cancelDelay

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

**Returns**

`Promise<void>` — Resolves when the delay conditions are cleared.

**Since:** 4.0.0

**Throws:** {Error} If the operation fails.


--------------------


### getLatest

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `GetLatestOptions | undefined` | Optional {@link GetLatestOptions} to specify which channel to check. |

**Returns**

`Promise<LatestVersion>` — Information about the latest available bundle version.

**Since:** 4.0.0

**Throws:** {Error} Always throws when no new version is available (`error: "no_new_version_available"`), or when the request fails.


--------------------


### setChannel

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
CapacitorUpdater.addListener('channelPrivate', (data) => {
  console.warn(`Cannot access channel "${data.channel}": ${data.message}`);
  // Show user-friendly message
});
```

This sends a request to the Capgo backend linking your device ID to the specified channel.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetChannelOptions` | The {@link SetChannelOptions} containing the channel name and optional auto-update trigger. |

**Returns**

`Promise<ChannelRes>` — Channel operation result with status and optional error/message.

**Since:** 4.7.0

**Throws:** {Error} If the channel doesn't exist or doesn't allow self-assignment.


--------------------


### unsetChannel

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `UnsetChannelOptions` |  |

**Returns**

`Promise<void>` — Resolves when the channel is successfully unset.

**Since:** 4.7.0

**Throws:** {Error} If the operation fails.


--------------------


### getChannel

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

**Returns**

`Promise<GetChannelRes>` — The current channel information.

**Since:** 4.8.0

**Throws:** {Error} If the operation fails.


--------------------


### listChannels

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

**Returns**

`Promise<ListChannelsResult>` — List of channels the device can self-assign to.

**Since:** 7.5.0

**Throws:** {Error} If the operation fails or the request to the backend fails.


--------------------


### setCustomId

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetCustomIdOptions` | The {@link SetCustomIdOptions} containing the custom identifier string. |

**Returns**

`Promise<void>` — Resolves immediately (synchronous operation).

**Since:** 4.9.0

**Throws:** {Error} If the operation fails.


--------------------


### getBuiltinVersion

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

**Returns**

`Promise<BuiltinVersion>` — The builtin bundle version string.

**Since:** 5.2.0


--------------------


### getDeviceId

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

**Returns**

`Promise<DeviceId>` — The unique device identifier string.

**Throws:** {Error} If the operation fails.


--------------------


### getPluginVersion

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

**Returns**

`Promise<PluginVersion>` — The Capacitor Updater plugin version string.

**Throws:** {Error} If the operation fails.


--------------------


### isAutoUpdateEnabled

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

**Returns**

`Promise<AutoUpdateEnabled>` — `true` if auto-update is enabled, `false` if in manual mode.

**Throws:** {Error} If the operation fails.


--------------------


### removeAllListeners

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

**Returns**

`Promise<void>` — Resolves when all listeners are removed.

**Since:** 1.0.0


--------------------


### addListener('download')

```typescript
addListener(eventName: 'download', listenerFunc: (state: DownloadEvent) => void) => Promise<PluginListenerHandle>
```

Listen for bundle download event in the App. Fires once a download has started, during downloading and when finished.
This will return you all download percent during the download

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'download'` |  |
| `listenerFunc` | `(state: DownloadEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 2.0.11


--------------------


### addListener('noNeedUpdate')

```typescript
addListener(eventName: 'noNeedUpdate', listenerFunc: (state: NoNeedEvent) => void) => Promise<PluginListenerHandle>
```

Listen for no need to update event, useful when you want force check every time the app is launched

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'noNeedUpdate'` |  |
| `listenerFunc` | `(state: NoNeedEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 4.0.0


--------------------


### addListener('updateAvailable')

```typescript
addListener(eventName: 'updateAvailable', listenerFunc: (state: UpdateAvailableEvent) => void) => Promise<PluginListenerHandle>
```

Listen for available update event, useful when you want to force check every time the app is launched

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'updateAvailable'` |  |
| `listenerFunc` | `(state: UpdateAvailableEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 4.0.0


--------------------


### addListener('downloadComplete')

```typescript
addListener(eventName: 'downloadComplete', listenerFunc: (state: DownloadCompleteEvent) => void) => Promise<PluginListenerHandle>
```

Listen for downloadComplete events.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'downloadComplete'` |  |
| `listenerFunc` | `(state: DownloadCompleteEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 4.0.0


--------------------


### addListener('breakingAvailable')

```typescript
addListener(eventName: 'breakingAvailable', listenerFunc: (state: BreakingAvailableEvent) => void) => Promise<PluginListenerHandle>
```

Listen for breaking update events when the backend flags an update as incompatible with the current app.
Emits the same payload as the legacy `majorAvailable` listener.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'breakingAvailable'` |  |
| `listenerFunc` | `(state: MajorAvailableEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 7.22.0


--------------------


### addListener('majorAvailable')

```typescript
addListener(eventName: 'majorAvailable', listenerFunc: (state: MajorAvailableEvent) => void) => Promise<PluginListenerHandle>
```

Listen for Major update event in the App, let you know when major update is blocked by setting disableAutoUpdateBreaking

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'majorAvailable'` |  |
| `listenerFunc` | `(state: MajorAvailableEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 2.3.0


--------------------


### addListener('updateFailed')

```typescript
addListener(eventName: 'updateFailed', listenerFunc: (state: UpdateFailedEvent) => void) => Promise<PluginListenerHandle>
```

Listen for update fail event in the App, let you know when update has fail to install at next app start

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'updateFailed'` |  |
| `listenerFunc` | `(state: UpdateFailedEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 2.3.0


--------------------


### addListener('downloadFailed')

```typescript
addListener(eventName: 'downloadFailed', listenerFunc: (state: DownloadFailedEvent) => void) => Promise<PluginListenerHandle>
```

Listen for download fail event in the App, let you know when a bundle download has failed

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'downloadFailed'` |  |
| `listenerFunc` | `(state: DownloadFailedEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 4.0.0


--------------------


### addListener('appReloaded')

```typescript
addListener(eventName: 'appReloaded', listenerFunc: () => void) => Promise<PluginListenerHandle>
```

Listen for reload event in the App, let you know when reload has happened

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'appReloaded'` |  |
| `listenerFunc` | `() => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 4.3.0


--------------------


### addListener('appReady')

```typescript
addListener(eventName: 'appReady', listenerFunc: (state: AppReadyEvent) => void) => Promise<PluginListenerHandle>
```

Listen for app ready event in the App, let you know when app is ready to use, this event is retain till consumed.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'appReady'` |  |
| `listenerFunc` | `(state: AppReadyEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 5.1.0


--------------------


### addListener('channelPrivate')

```typescript
addListener(eventName: 'channelPrivate', listenerFunc: (state: ChannelPrivateEvent) => void) => Promise<PluginListenerHandle>
```

Listen for channel private event, fired when attempting to set a channel that doesn't allow device self-assignment.

This event is useful for:
- Informing users they don't have permission to switch to a specific channel
- Implementing custom error handling for channel restrictions
- Logging unauthorized channel access attempts

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'channelPrivate'` |  |
| `listenerFunc` | `(state: ChannelPrivateEvent) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 7.34.0


--------------------


### addListener('onFlexibleUpdateStateChange')

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `eventName` | `'onFlexibleUpdateStateChange'` |  |
| `listenerFunc` | `(state: FlexibleUpdateState) => void` |  |

**Returns**

`Promise<PluginListenerHandle>`

**Since:** 8.0.0


--------------------


### isAutoUpdateAvailable

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

**Returns**

`Promise<AutoUpdateAvailable>` — `false` when custom updateUrl is set, `true` otherwise.

**Throws:** {Error} If the operation fails.


--------------------


### getNextBundle

```typescript
getNextBundle() => Promise<BundleInfo | null>
```

Get information about the bundle queued to be activated on next reload.

Returns:
- {@link BundleInfo} object if a bundle has been queued via {@link next}
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

**Returns**

`Promise<BundleInfo | null>` — The pending bundle info, or `null` if none is queued.

**Since:** 6.8.0

**Throws:** {Error} If the operation fails.


--------------------


### getFailedUpdate

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
- {@link UpdateFailedEvent} with bundle info if a failure was recorded
- `null` if no failure has occurred or if it was already retrieved

Use this to:
- Show users why an update failed
- Log failure information for debugging
- Implement custom error handling/reporting
- Display rollback notifications

**Returns**

`Promise<UpdateFailedEvent | null>` — The failed update info (cleared after first retrieval), or `null`.

**Since:** 7.22.0

**Throws:** {Error} If the operation fails.


--------------------


### setShakeMenu

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetShakeMenuOptions` |  |

**Returns**

`Promise<void>` — Resolves when the setting is applied.

**Since:** 7.5.0

**Throws:** {Error} If the operation fails.


--------------------


### isShakeMenuEnabled

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

**Returns**

`Promise<ShakeMenuEnabled>` — Object with `enabled: true` or `enabled: false`.

**Since:** 7.5.0

**Throws:** {Error} If the operation fails.


--------------------


### getAppId

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

**Returns**

`Promise<GetAppIdRes>` — Object containing the current `appId` string.

**Since:** 7.14.0

**Throws:** {Error} If the operation fails.


--------------------


### setAppId

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetAppIdOptions` |  |

**Returns**

`Promise<void>` — Resolves when the App ID is successfully changed.

**Since:** 7.14.0

**Throws:** {Error} If `allowModifyAppId` is false or the operation fails.


--------------------


### getAppUpdateInfo

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `GetAppUpdateInfoOptions | undefined` | Optional {@link GetAppUpdateInfoOptions} with country code for iOS. |

**Returns**

`Promise<AppUpdateInfo>` — Information about the current and available app versions.

**Since:** 8.0.0

**Throws:** {Error} If the operation fails or store information is unavailable.


--------------------


### openAppStore

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

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `OpenAppStoreOptions | undefined` | Optional {@link OpenAppStoreOptions} to customize which app's store page to open. |

**Returns**

`Promise<void>` — Resolves when the store is opened.

**Since:** 8.0.0

**Throws:** {Error} If the store cannot be opened.


--------------------


### performImmediateUpdate

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

**Returns**

`Promise<AppUpdateResult>` — Result indicating success, cancellation, or failure.

**Since:** 8.0.0

**Throws:** {Error} If not on Android, no update is available, or immediate updates not allowed.


--------------------


### startFlexibleUpdate

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

**Returns**

`Promise<AppUpdateResult>` — Result indicating the update was started, cancelled, or failed.

**Since:** 8.0.0

**Throws:** {Error} If not on Android, no update is available, or flexible updates not allowed.


--------------------


### completeFlexibleUpdate

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

**Returns**

`Promise<void>` — Resolves when the update installation begins (app will restart).

**Since:** 8.0.0

**Throws:** {Error} If not on Android or no downloaded update is pending.


--------------------


</docgen-api>
