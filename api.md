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
| **`resetWhenUpdate`** | `boolean` | Automatically delete previous downloaded bundles when a newer native app bundle is installed to the device. Only available for Android and iOS. | `true` |  |
| **`updateUrl`** | `string` | Configure the URL / endpoint to which update checks are sent. Only available for Android and iOS. | `https://plugin.capgo.app/updates` |  |
| **`channelUrl`** | `string` | Configure the URL / endpoint for channel operations. Only available for Android and iOS. | `https://plugin.capgo.app/channel_self` |  |
| **`statsUrl`** | `string` | Configure the URL / endpoint to which update statistics are sent. Only available for Android and iOS. Set to "" to disable stats reporting. | `https://plugin.capgo.app/stats` |  |
| **`publicKey`** | `string` | Configure the public key for end to end live update encryption Version 2 Only available for Android and iOS. | `undefined` | 6.2.0 |
| **`version`** | `string` | Configure the current version of the app. This will be used for the first update request. If not set, the plugin will get the version from the native code. Only available for Android and iOS. | `undefined` | 4.17.48 |
| **`directUpdate`** | `boolean | 'always' | 'atInstall'` | Configure when the plugin should direct install updates. Only for autoUpdate mode. Works well for apps less than 10MB and with uploads done using --partial flag. Zip or apps more than 10MB will be relatively slow for users to update. - false: Never do direct updates (default behavior) - atInstall: Direct update only when app is installed/updated from store, otherwise use normal background update - always: Always do direct updates immediately when available - true: (deprecated) Same as "always" for backward compatibility Only available for Android and iOS. | `false` | 5.1.0 |
| **`autoSplashscreen`** | `boolean` | Automatically handle splashscreen hiding when using directUpdate. When enabled, the plugin will automatically hide the splashscreen after updates are applied or when no update is needed. This removes the need to manually listen for appReady events and call SplashScreen.hide(). Only works when directUpdate is set to "atInstall", "always", or true. Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false. Requires autoUpdate and directUpdate to be enabled. Only available for Android and iOS. | `false` | 7.6.0 |
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
| **`persistCustomId`** | `boolean` | Persist the customId set through {@link CapacitorUpdaterPlugin.setCustomId} across app restarts. Only available for Android and iOS. | `false (will be true by default in a future major release v8.x.x)` | 7.17.3 |
| **`persistModifyUrl`** | `boolean` | Persist the updateUrl, statsUrl and channelUrl set through {@link CapacitorUpdaterPlugin.setUpdateUrl}, {@link CapacitorUpdaterPlugin.setStatsUrl} and {@link CapacitorUpdaterPlugin.setChannelUrl} across app restarts. Only available for Android and iOS. | `false` | 7.20.0 |
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
- [`addListener('majorAvailable')`](#addlistenermajoravailable-)
- [`addListener('updateFailed')`](#addlistenerupdatefailed-)
- [`addListener('downloadFailed')`](#addlistenerdownloadfailed-)
- [`addListener('appReloaded')`](#addlistenerappreloaded-)
- [`addListener('appReady')`](#addlistenerappready-)
- [`isAutoUpdateAvailable`](#isautoupdateavailable)
- [`getNextBundle`](#getnextbundle)
- [`setShakeMenu`](#setshakemenu)
- [`isShakeMenuEnabled`](#isshakemenuenabled)
- [`getAppId`](#getappid)
- [`setAppId`](#setappid)

</docgen-index>

<docgen-api>
<!--Auto-generated, do not edit by hand-->

### notifyAppReady

```typescript
notifyAppReady() => Promise<AppReadyResult>
```

Notify Capacitor Updater that the current bundle is working (a rollback will occur if this method is not called on every app launch)
By default this method should be called in the first 10 sec after app launch, otherwise a rollback will occur.
Change this behaviour with {@link appReadyTimeout}

**Returns**

`Promise<AppReadyResult>` — an Promise resolved directly

**Throws:** {Error}


--------------------


### setUpdateUrl

```typescript
setUpdateUrl(options: UpdateUrl) => Promise<void>
```

Set the updateUrl for the app, this will be used to check for updates.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `UpdateUrl` | contains the URL to use for checking for updates. |

**Returns**

`Promise<void>`

**Since:** 5.4.0

**Throws:** {Error}


--------------------


### setStatsUrl

```typescript
setStatsUrl(options: StatsUrl) => Promise<void>
```

Set the statsUrl for the app, this will be used to send statistics. Passing an empty string will disable statistics gathering.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `StatsUrl` | contains the URL to use for sending statistics. |

**Returns**

`Promise<void>`

**Since:** 5.4.0

**Throws:** {Error}


--------------------


### setChannelUrl

```typescript
setChannelUrl(options: ChannelUrl) => Promise<void>
```

Set the channelUrl for the app, this will be used to set the channel.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `ChannelUrl` | contains the URL to use for setting the channel. |

**Returns**

`Promise<void>`

**Since:** 5.4.0

**Throws:** {Error}


--------------------


### download

```typescript
download(options: DownloadOptions) => Promise<BundleInfo>
```

Download a new bundle from the provided URL, it should be a zip file, with files inside or with a unique id inside with all your files

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `DownloadOptions` | The {@link DownloadOptions} for downloading a new bundle zip. |

**Returns**

`Promise<BundleInfo>` — The {@link BundleInfo} for the specified bundle.

**Example**

```ts
const bundle = await CapacitorUpdater.download({ url: `https://example.com/versions/${version}/dist.zip`, version });
```


--------------------


### next

```typescript
next(options: BundleId) => Promise<BundleInfo>
```

Set the next bundle to be used when the app is reloaded.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | Contains the ID of the next Bundle to set on next app launch. {@link BundleInfo.id} |

**Returns**

`Promise<BundleInfo>` — The {@link BundleInfo} for the specified bundle id.

**Throws:** {Error} When there is no index.html file inside the bundle folder.


--------------------


### set

```typescript
set(options: BundleId) => Promise<void>
```

Set the current bundle and immediately reloads the app.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | A {@link BundleId} object containing the new bundle id to set as current. |

**Returns**

`Promise<void>`

**Throws:** {Error} When there are is no index.html file inside the bundle folder.


--------------------


### delete

```typescript
delete(options: BundleId) => Promise<void>
```

Deletes the specified bundle from the native app storage. Use with {@link list} to get the stored Bundle IDs.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `BundleId` | A {@link BundleId} object containing the ID of a bundle to delete (note, this is the bundle id, NOT the version name) |

**Returns**

`Promise<void>` — When the bundle is deleted

**Throws:** {Error}


--------------------


### list

```typescript
list(options?: ListOptions | undefined) => Promise<BundleListResult>
```

Get all locally downloaded bundles in your app

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `ListOptions | undefined` | The {@link ListOptions} for listing bundles |

**Returns**

`Promise<BundleListResult>` — A Promise containing the {@link BundleListResult.bundles}

**Throws:** {Error}


--------------------


### reset

```typescript
reset(options?: ResetOptions | undefined) => Promise<void>
```

Reset the app to the `builtin` bundle (the one sent to Apple App Store / Google Play Store ) or the last successfully loaded bundle.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `ResetOptions | undefined` | Containing {@link ResetOptions.toLastSuccessful}, `true` resets to the builtin bundle and `false` will reset to the last successfully loaded bundle. |

**Returns**

`Promise<void>`

**Throws:** {Error}


--------------------


### current

```typescript
current() => Promise<CurrentBundleResult>
```

Get the current bundle, if none are set it returns `builtin`. currentNative is the original bundle installed on the device

**Returns**

`Promise<CurrentBundleResult>` — A Promise evaluating to the {@link CurrentBundleResult}

**Throws:** {Error}


--------------------


### reload

```typescript
reload() => Promise<void>
```

Reload the view

**Returns**

`Promise<void>` — A Promise which is resolved when the view is reloaded

**Throws:** {Error}


--------------------


### setMultiDelay

```typescript
setMultiDelay(options: MultiDelayConditions) => Promise<void>
```

Sets a {@link DelayCondition} array containing conditions that the Plugin will use to delay the update.
After all conditions are met, the update process will run start again as usual, so update will be installed after a backgrounding or killing the app.
For the `date` kind, the value should be an iso8601 date string.
For the `background` kind, the value should be a number in milliseconds.
For the `nativeVersion` kind, the value should be the version number.
For the `kill` kind, the value is not used.
The function has unconsistent behavior the option kill do trigger the update after the first kill and not after the next background like other options. This will be fixed in a future major release.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `MultiDelayConditions` | Containing the {@link MultiDelayConditions} array of conditions to set |

**Returns**

`Promise<void>`

**Since:** 4.3.0

**Throws:** {Error}

**Example**

```ts
// Delay the update after the user kills the app or after a background of 300000 ms (5 minutes)
await CapacitorUpdater.setMultiDelay({ delayConditions: [{ kind: 'kill' }, { kind: 'background', value: '300000' }] })
```

**Example**

```ts
// Delay the update after the specific iso8601 date is expired
await CapacitorUpdater.setMultiDelay({ delayConditions: [{ kind: 'date', value: '2022-09-14T06:14:11.920Z' }] })
```

**Example**

```ts
// Delay the update after the first background (default behaviour without setting delay)
await CapacitorUpdater.setMultiDelay({ delayConditions: [{ kind: 'background' }] })
```


--------------------


### cancelDelay

```typescript
cancelDelay() => Promise<void>
```

Cancels a {@link DelayCondition} to process an update immediately.

**Returns**

`Promise<void>`

**Since:** 4.0.0

**Throws:** {Error}


--------------------


### getLatest

```typescript
getLatest(options?: GetLatestOptions | undefined) => Promise<LatestVersion>
```

Get Latest bundle available from update Url

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `GetLatestOptions | undefined` |  |

**Returns**

`Promise<LatestVersion>` — A Promise resolved when url is loaded

**Since:** 4.0.0

**Throws:** {Error}


--------------------


### setChannel

```typescript
setChannel(options: SetChannelOptions) => Promise<ChannelRes>
```

Sets the channel for this device. The channel has to allow for self assignment for this to work.
Do not use this method to set the channel at boot.
This method is to set the channel after the app is ready, and user interacted.
If you want to set the channel at boot, use the {@link PluginsConfig} to set the default channel.
This methods send to Capgo backend a request to link the device ID to the channel. Capgo can accept or refuse depending of the setting of your channel.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetChannelOptions` | Is the {@link SetChannelOptions} channel to set |

**Returns**

`Promise<ChannelRes>` — A Promise which is resolved when the new channel is set

**Since:** 4.7.0

**Throws:** {Error}


--------------------


### unsetChannel

```typescript
unsetChannel(options: UnsetChannelOptions) => Promise<void>
```

Unset the channel for this device. The device will then return to the default channel

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `UnsetChannelOptions` |  |

**Returns**

`Promise<void>` — A Promise resolved when channel is set

**Since:** 4.7.0

**Throws:** {Error}


--------------------


### getChannel

```typescript
getChannel() => Promise<GetChannelRes>
```

Get the channel for this device

**Returns**

`Promise<GetChannelRes>` — A Promise that resolves with the channel info

**Since:** 4.8.0

**Throws:** {Error}


--------------------


### listChannels

```typescript
listChannels() => Promise<ListChannelsResult>
```

List all channels available for this device that allow self-assignment

**Returns**

`Promise<ListChannelsResult>` — A Promise that resolves with the available channels

**Since:** 7.5.0

**Throws:** {Error}


--------------------


### setCustomId

```typescript
setCustomId(options: SetCustomIdOptions) => Promise<void>
```

Set a custom ID for this device

When {@link PluginsConfig.CapacitorUpdater.persistCustomId} is true, the value will be stored natively and restored on the next app launch.
Pass an empty string to remove any previously stored customId.

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetCustomIdOptions` | is the {@link SetCustomIdOptions} customId to set |

**Returns**

`Promise<void>` — an Promise resolved instantly

**Since:** 4.9.0

**Throws:** {Error}


--------------------


### getBuiltinVersion

```typescript
getBuiltinVersion() => Promise<BuiltinVersion>
```

Get the native app version or the builtin version if set in config

**Returns**

`Promise<BuiltinVersion>` — A Promise with version for this device

**Since:** 5.2.0


--------------------


### getDeviceId

```typescript
getDeviceId() => Promise<DeviceId>
```

Get unique ID used to identify device (sent to auto update server), this ID is made following Apple and Google privacy best practices, and not persisted between installs

**Returns**

`Promise<DeviceId>` — A Promise with id for this device

**Throws:** {Error}


--------------------


### getPluginVersion

```typescript
getPluginVersion() => Promise<PluginVersion>
```

Get the native Capacitor Updater plugin version (sent to auto update server)

**Returns**

`Promise<PluginVersion>` — A Promise with Plugin version

**Throws:** {Error}


--------------------


### isAutoUpdateEnabled

```typescript
isAutoUpdateEnabled() => Promise<AutoUpdateEnabled>
```

Get the state of auto update config.

**Returns**

`Promise<AutoUpdateEnabled>` — The status for auto update. Evaluates to `false` in manual mode.

**Throws:** {Error}


--------------------


### removeAllListeners

```typescript
removeAllListeners() => Promise<void>
```

Remove all listeners for this plugin.

**Returns**

`Promise<void>`

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


### isAutoUpdateAvailable

```typescript
isAutoUpdateAvailable() => Promise<AutoUpdateAvailable>
```

Get if auto update is available (not disabled by serverUrl).

**Returns**

`Promise<AutoUpdateAvailable>` — The availability status for auto update. Evaluates to `false` when serverUrl is set.

**Throws:** {Error}


--------------------


### getNextBundle

```typescript
getNextBundle() => Promise<BundleInfo | null>
```

Get the next bundle that will be used when the app reloads.
Returns null if no next bundle is set.

**Returns**

`Promise<BundleInfo | null>` — A Promise that resolves with the next bundle information or null

**Since:** 6.8.0

**Throws:** {Error}


--------------------


### setShakeMenu

```typescript
setShakeMenu(options: SetShakeMenuOptions) => Promise<void>
```

Enable or disable the shake menu for debugging/testing purposes

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetShakeMenuOptions` | Contains enabled boolean to enable or disable shake menu |

**Returns**

`Promise<void>`

**Since:** 7.5.0

**Throws:** {Error}


--------------------


### isShakeMenuEnabled

```typescript
isShakeMenuEnabled() => Promise<ShakeMenuEnabled>
```

Get the current state of the shake menu

**Returns**

`Promise<ShakeMenuEnabled>` — The current state of shake menu

**Since:** 7.5.0

**Throws:** {Error}


--------------------


### getAppId

```typescript
getAppId() => Promise<GetAppIdRes>
```

Get the configured App ID

**Returns**

`Promise<GetAppIdRes>` — The current App ID

**Since:** 7.14.0

**Throws:** {Error}


--------------------


### setAppId

```typescript
setAppId(options: SetAppIdOptions) => Promise<void>
```

Set the App ID for the app (requires allowModifyAppId to be true in config)

**Parameters**

| Name | Type | Description |
| --- | --- | --- |
| `options` | `SetAppIdOptions` | The new App ID to set |

**Returns**

`Promise<void>`

**Since:** 7.14.0

**Throws:** {Error} If allowModifyAppId is false or if the operation fails


--------------------


</docgen-api>
