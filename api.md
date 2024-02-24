---
title: "Methods"
description: "All available method of the plugin"
sidebar:
  order: 2
---

See the Github [Readme](https://github.com/Cap-go/capacitor-updater) for more information.

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

## notifyAppReady()

```typescript
notifyAppReady() => Promise<{ bundle: BundleInfo; }>
```

Notify Capacitor Updater that the current bundle is working (a rollback will occur of this method is not called on every app launch)
By default this method should be called in the first 10 sec after app launch, otherwise a rollback will occur.
Change this behaviour with {@link appReadyTimeout}

**Returns:** <code>Promise&lt;{ bundle: <a href="#bundleinfo">BundleInfo</a>; }&gt;</code>

--------------------


## setUpdateUrl(...)

```typescript
setUpdateUrl(options: { url: string; }) => Promise<void>
```

Set the updateUrl for the app, this will be used to check for updates.

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Since:** 5.4.0

--------------------


## setStatsUrl(...)

```typescript
setStatsUrl(options: { url: string; }) => Promise<void>
```

Set the statsUrl for the app, this will be used to send statistics.

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Since:** 5.4.0

--------------------


## setChannelUrl(...)

```typescript
setChannelUrl(options: { url: string; }) => Promise<void>
```

Set the channelUrl for the app, this will be used to set the channel.

| Param         | Type                          |
| ------------- | ----------------------------- |
| **`options`** | <code>{ url: string; }</code> |

**Since:** 5.4.0

--------------------


## download(...)

```typescript
download(options: { url: string; version: string; sessionKey?: string; checksum?: string; }) => Promise<BundleInfo>
```

Download a new bundle from the provided URL, it should be a zip file, with files inside or with a unique id inside with all your files

| Param         | Type                                                                                   |
| ------------- | -------------------------------------------------------------------------------------- |
| **`options`** | <code>{ url: string; version: string; sessionKey?: string; checksum?: string; }</code> |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


## next(...)

```typescript
next(options: { id: string; }) => Promise<BundleInfo>
```

Set the next bundle to be used when the app is reloaded.

| Param         | Type                         |
| ------------- | ---------------------------- |
| **`options`** | <code>{ id: string; }</code> |

**Returns:** <code>Promise&lt;<a href="#bundleinfo">BundleInfo</a>&gt;</code>

--------------------


## set(...)

```typescript
set(options: { id: string; }) => Promise<void>
```

Set the current bundle and immediately reloads the app.

| Param         | Type                         |
| ------------- | ---------------------------- |
| **`options`** | <code>{ id: string; }</code> |

--------------------


## delete(...)

```typescript
delete(options: { id: string; }) => Promise<void>
```

Delete bundle in storage

| Param         | Type                         |
| ------------- | ---------------------------- |
| **`options`** | <code>{ id: string; }</code> |

--------------------


## list()

```typescript
list() => Promise<{ bundles: BundleInfo[]; }>
```

Get all locally downloaded bundles in your app

**Returns:** <code>Promise&lt;{ bundles: BundleInfo[]; }&gt;</code>

--------------------


## reset(...)

```typescript
reset(options?: { toLastSuccessful?: boolean | undefined; } | undefined) => Promise<void>
```

Set the `builtin` bundle (the one sent to Apple store / Google play store ) as current bundle

| Param         | Type                                         |
| ------------- | -------------------------------------------- |
| **`options`** | <code>{ toLastSuccessful?: boolean; }</code> |

--------------------


## current()

```typescript
current() => Promise<{ bundle: BundleInfo; native: string; }>
```

Get the current bundle, if none are set it returns `builtin`, currentNative is the original bundle installed on the device

**Returns:** <code>Promise&lt;{ bundle: <a href="#bundleinfo">BundleInfo</a>; native: string; }&gt;</code>

--------------------


## reload()

```typescript
reload() => Promise<void>
```

Reload the view

--------------------


## setMultiDelay(...)

```typescript
setMultiDelay(options: { delayConditions: DelayCondition[]; }) => Promise<void>
```

Set <a href="#delaycondition">DelayCondition</a>, skip updates until one of the conditions is met

| Param         | Type                                                | Description                                                              |
| ------------- | --------------------------------------------------- | ------------------------------------------------------------------------ |
| **`options`** | <code>{ delayConditions: DelayCondition[]; }</code> | are the {@link <a href="#delaycondition">DelayCondition</a>} list to set |

**Since:** 4.3.0

--------------------


## cancelDelay()

```typescript
cancelDelay() => Promise<void>
```

Cancel delay to updates as usual

**Since:** 4.0.0

--------------------


## getLatest()

```typescript
getLatest() => Promise<latestVersion>
```

Get Latest bundle available from update Url

**Returns:** <code>Promise&lt;<a href="#latestversion">latestVersion</a>&gt;</code>

**Since:** 4.0.0

--------------------


## setChannel(...)

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


## unsetChannel(...)

```typescript
unsetChannel(options: UnsetChannelOptions) => Promise<void>
```

Unset Channel for this device, the device will return to the default channel

| Param         | Type                                                                |
| ------------- | ------------------------------------------------------------------- |
| **`options`** | <code><a href="#unsetchanneloptions">UnsetChannelOptions</a></code> |

**Since:** 4.7.0

--------------------


## getChannel()

```typescript
getChannel() => Promise<getChannelRes>
```

get Channel for this device

**Returns:** <code>Promise&lt;<a href="#getchannelres">getChannelRes</a>&gt;</code>

**Since:** 4.8.0

--------------------


## setCustomId(...)

```typescript
setCustomId(options: SetCustomIdOptions) => Promise<void>
```

Set Channel for this device

| Param         | Type                                                              | Description                                                                         |
| ------------- | ----------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| **`options`** | <code><a href="#setcustomidoptions">SetCustomIdOptions</a></code> | is the {@link <a href="#setcustomidoptions">SetCustomIdOptions</a>} customId to set |

**Since:** 4.9.0

--------------------


## addListener('download', ...)

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


## addListener('noNeedUpdate', ...)

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


## addListener('updateAvailable', ...)

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


## addListener('downloadComplete', ...)

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


## addListener('majorAvailable', ...)

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


## addListener('updateFailed', ...)

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


## addListener('downloadFailed', ...)

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


## addListener('appReloaded', ...)

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


## addListener('appReady', ...)

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


## getBuiltinVersion()

```typescript
getBuiltinVersion() => Promise<{ version: string; }>
```

Get the native app version or the builtin version if set in config

**Returns:** <code>Promise&lt;{ version: string; }&gt;</code>

**Since:** 5.2.0

--------------------


## getDeviceId()

```typescript
getDeviceId() => Promise<{ deviceId: string; }>
```

Get unique ID used to identify device (sent to auto update server)

**Returns:** <code>Promise&lt;{ deviceId: string; }&gt;</code>

--------------------


## getPluginVersion()

```typescript
getPluginVersion() => Promise<{ version: string; }>
```

Get the native Capacitor Updater plugin version (sent to auto update server)

**Returns:** <code>Promise&lt;{ version: string; }&gt;</code>

--------------------


## isAutoUpdateEnabled()

```typescript
isAutoUpdateEnabled() => Promise<{ enabled: boolean; }>
```

Get the state of auto update config. This will return `false` in manual mode.

**Returns:** <code>Promise&lt;{ enabled: boolean; }&gt;</code>

--------------------


## removeAllListeners()

```typescript
removeAllListeners() => Promise<void>
```

Remove all listeners for this plugin.

**Since:** 1.0.0

--------------------


## Interfaces


### BundleInfo

| Prop             | Type                                                  |
| ---------------- | ----------------------------------------------------- |
| **`id`**         | <code>string</code>                                   |
| **`version`**    | <code>string</code>                                   |
| **`downloaded`** | <code>string</code>                                   |
| **`checksum`**   | <code>string</code>                                   |
| **`status`**     | <code><a href="#bundlestatus">BundleStatus</a></code> |


### DelayCondition

| Prop        | Type                                                      | Description                              |
| ----------- | --------------------------------------------------------- | ---------------------------------------- |
| **`kind`**  | <code><a href="#delayuntilnext">DelayUntilNext</a></code> | Set up delay conditions in setMultiDelay |
| **`value`** | <code>string</code>                                       |                                          |


### latestVersion

| Prop             | Type                 | Description             | Since |
| ---------------- | -------------------- | ----------------------- | ----- |
| **`version`**    | <code>string</code>  | Res of getLatest method | 4.0.0 |
| **`major`**      | <code>boolean</code> |                         |       |
| **`message`**    | <code>string</code>  |                         |       |
| **`sessionKey`** | <code>string</code>  |                         |       |
| **`error`**      | <code>string</code>  |                         |       |
| **`old`**        | <code>string</code>  |                         |       |
| **`url`**        | <code>string</code>  |                         |       |


### channelRes

| Prop          | Type                | Description                   | Since |
| ------------- | ------------------- | ----------------------------- | ----- |
| **`status`**  | <code>string</code> | Current status of set channel | 4.7.0 |
| **`error`**   | <code>any</code>    |                               |       |
| **`message`** | <code>any</code>    |                               |       |


### SetChannelOptions

| Prop                    | Type                 |
| ----------------------- | -------------------- |
| **`channel`**           | <code>string</code>  |
| **`triggerAutoUpdate`** | <code>boolean</code> |


### UnsetChannelOptions

| Prop                    | Type                 |
| ----------------------- | -------------------- |
| **`triggerAutoUpdate`** | <code>boolean</code> |


### getChannelRes

| Prop           | Type                 | Description                   | Since |
| -------------- | -------------------- | ----------------------------- | ----- |
| **`channel`**  | <code>string</code>  | Current status of get channel | 4.8.0 |
| **`error`**    | <code>any</code>     |                               |       |
| **`message`**  | <code>any</code>     |                               |       |
| **`status`**   | <code>string</code>  |                               |       |
| **`allowSet`** | <code>boolean</code> |                               |       |


### SetCustomIdOptions

| Prop           | Type                |
| -------------- | ------------------- |
| **`customId`** | <code>string</code> |


### PluginListenerHandle

| Prop         | Type                                      |
| ------------ | ----------------------------------------- |
| **`remove`** | <code>() =&gt; Promise&lt;void&gt;</code> |


### DownloadEvent

| Prop          | Type                                              | Description                                    | Since |
| ------------- | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`percent`** | <code>number</code>                               | Current status of download, between 0 and 100. | 4.0.0 |
| **`bundle`**  | <code><a href="#bundleinfo">BundleInfo</a></code> |                                                |       |


### noNeedEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


### updateAvailableEvent

| Prop         | Type                                              | Description                                    | Since |
| ------------ | ------------------------------------------------- | ---------------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Current status of download, between 0 and 100. | 4.0.0 |


### DownloadCompleteEvent

| Prop         | Type                                              | Description                          | Since |
| ------------ | ------------------------------------------------- | ------------------------------------ | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a new update is available. | 4.0.0 |


### MajorAvailableEvent

| Prop          | Type                | Description                                | Since |
| ------------- | ------------------- | ------------------------------------------ | ----- |
| **`version`** | <code>string</code> | Emit when a new major bundle is available. | 4.0.0 |


### UpdateFailedEvent

| Prop         | Type                                              | Description                           | Since |
| ------------ | ------------------------------------------------- | ------------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a update failed to install. | 4.0.0 |


### DownloadFailedEvent

| Prop          | Type                | Description                | Since |
| ------------- | ------------------- | -------------------------- | ----- |
| **`version`** | <code>string</code> | Emit when a download fail. | 4.0.0 |


### AppReadyEvent

| Prop         | Type                                              | Description                      | Since |
| ------------ | ------------------------------------------------- | -------------------------------- | ----- |
| **`bundle`** | <code><a href="#bundleinfo">BundleInfo</a></code> | Emit when a app is ready to use. | 5.2.0 |
| **`status`** | <code>string</code>                               |                                  |       |


## Type Aliases


### BundleStatus

<code>"success" | "error" | "pending" | "downloading"</code>


### DelayUntilNext

<code>"background" | "kill" | "nativeVersion" | "date"</code>


### DownloadChangeListener

<code>(state: <a href="#downloadevent">DownloadEvent</a>): void</code>


### NoNeedListener

<code>(state: <a href="#noneedevent">noNeedEvent</a>): void</code>


### UpdateAvailabledListener

<code>(state: <a href="#updateavailableevent">updateAvailableEvent</a>): void</code>


### DownloadCompleteListener

<code>(state: <a href="#downloadcompleteevent">DownloadCompleteEvent</a>): void</code>


### MajorAvailableListener

<code>(state: <a href="#majoravailableevent">MajorAvailableEvent</a>): void</code>


### UpdateFailedListener

<code>(state: <a href="#updatefailedevent">UpdateFailedEvent</a>): void</code>


### DownloadFailedListener

<code>(state: <a href="#downloadfailedevent">DownloadFailedEvent</a>): void</code>


### AppReloadedListener

<code>(state: void): void</code>


### AppReadyListener

<code>(state: <a href="#appreadyevent">AppReadyEvent</a>): void</code>

</docgen-api>
