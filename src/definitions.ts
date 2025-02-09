/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/// <reference types="@capacitor/cli" />

import type { PluginListenerHandle } from '@capacitor/core';

declare module '@capacitor/cli' {
  export interface PluginsConfig {
    /**
     * CapacitorUpdater can be configured with these options:
     */
    CapacitorUpdater?: {
      /**
       * Configure the number of milliseconds the native plugin should wait before considering an update 'failed'.
       *
       * Only available for Android and iOS.
       *
       * @default 10000 // (10 seconds)
       * @example 1000 // (1 second)
       */
      appReadyTimeout?: number;
      /**
       * Configure the number of milliseconds the native plugin should wait before considering API timeout.
       *
       * Only available for Android and iOS.
       *
       * @default 20 // (20 second)
       * @example 10 // (10 second)
       */
      responseTimeout?: number;
      /**
       * Configure whether the plugin should use automatically delete failed bundles.
       *
       * Only available for Android and iOS.
       *
       * @default true
       * @example false
       */
      autoDeleteFailed?: boolean;

      /**
       * Configure whether the plugin should use automatically delete previous bundles after a successful update.
       *
       * Only available for Android and iOS.
       *
       * @default true
       * @example false
       */
      autoDeletePrevious?: boolean;

      /**
       * Configure whether the plugin should use Auto Update via an update server.
       *
       * Only available for Android and iOS.
       *
       * @default true
       * @example false
       */
      autoUpdate?: boolean;

      /**
       * Automatically delete previous downloaded bundles when a newer native app bundle is installed to the device.
       *
       * Only available for Android and iOS.
       *
       * @default true
       * @example false
       */
      resetWhenUpdate?: boolean;

      /**
       * Configure the URL / endpoint to which update checks are sent.
       *
       * Only available for Android and iOS.
       *
       * @default https://plugin.capgo.app/updates
       * @example https://example.com/api/auto_update
       */
      updateUrl?: string;

      /**
       * Configure the URL / endpoint for channel operations.
       *
       * Only available for Android and iOS.
       *
       * @default https://plugin.capgo.app/channel_self
       * @example https://example.com/api/channel
       */
      channelUrl?: string;

      /**
       * Configure the URL / endpoint to which update statistics are sent.
       *
       * Only available for Android and iOS. Set to "" to disable stats reporting.
       *
       * @default https://plugin.capgo.app/stats
       * @example https://example.com/api/stats
       */
      statsUrl?: string;
      /**
       * Configure the public key for end to end live update encryption Version 2
       *
       * Only available for Android and iOS.
       *
       * @default undefined
       * @since 6.2.0
       */
      publicKey?: string;

      /**
       * Configure the current version of the app. This will be used for the first update request.
       * If not set, the plugin will get the version from the native code.
       *
       * Only available for Android and iOS.
       *
       * @default undefined
       * @since  4.17.48
       */
      version?: string;
      /**
       * Make the plugin direct install the update when the app what just updated/installed. Only for autoUpdate mode.
       *
       * Only available for Android and iOS.
       *
       * @default undefined
       * @since  5.1.0
       */
      directUpdate?: boolean;

      /**
       * Configure the delay period for period update check. the unit is in seconds.
       *
       * Only available for Android and iOS.
       * Cannot be less than 600 seconds (10 minutes).
       *
       * @default 600 // (10 minutes)
       */
      periodCheckDelay?: number;

      /**
       * Configure the CLI to use a local server for testing or self-hosted update server.
       *
       *
       * @default undefined
       * @since  4.17.48
       */
      localS3?: boolean;
      /**
       * Configure the CLI to use a local server for testing or self-hosted update server.
       *
       *
       * @default undefined
       * @since  4.17.48
       */
      localHost?: string;
      /**
       * Configure the CLI to use a local server for testing or self-hosted update server.
       *
       *
       * @default undefined
       * @since  4.17.48
       */
      localWebHost?: string;
      /**
       * Configure the CLI to use a local server for testing or self-hosted update server.
       *
       *
       * @default undefined
       * @since  4.17.48
       */
      localSupa?: string;
      /**
       * Configure the CLI to use a local server for testing.
       *
       *
       * @default undefined
       * @since  4.17.48
       */
      localSupaAnon?: string;
      /**
       * Configure the CLI to use a local api for testing.
       *
       *
       * @default undefined
       * @since  6.3.3
       */
      localApi?: string;
      /**
       * Configure the CLI to use a local file api for testing.
       *
       *
       * @default undefined
       * @since  6.3.3
       */
      localApiFiles?: string;
      /**
       * Allow the plugin to modify the updateUrl, statsUrl and channelUrl dynamically from the JavaScript side.
       *
       *
       * @default false
       * @since  5.4.0
       */
      allowModifyUrl?: boolean;

      /**
       * Set the default channel for the app in the config.
       *
       *
       *
       * @default undefined
       * @since  5.5.0
       */
      defaultChannel?: string;
      /**
       * Configure the app id for the app in the config.
       *
       * @default undefined
       * @since  6.0.0
       */
      appId?: string;

      /**
       * Configure the plugin to keep the URL path after a reload.
       * WARNING: When a reload is triggered, 'window.history' will be cleared.
       *
       * @default false
       * @since  6.8.0
       */
      keepUrlPathAfterReload?: boolean;
    };
  }
}

export interface CapacitorUpdaterPlugin {
  /**
   * Notify Capacitor Updater that the current bundle is working (a rollback will occur if this method is not called on every app launch)
   * By default this method should be called in the first 10 sec after app launch, otherwise a rollback will occur.
   * Change this behaviour with {@link appReadyTimeout}
   *
   * @returns {Promise<AppReadyResult>} an Promise resolved directly
   * @throws {Error}
   */
  notifyAppReady(): Promise<AppReadyResult>;

  /**
   * Set the updateUrl for the app, this will be used to check for updates.
   *
   * @param options contains the URL to use for checking for updates.
   * @returns {Promise<void>}
   * @throws {Error}
   * @since 5.4.0
   */
  setUpdateUrl(options: UpdateUrl): Promise<void>;

  /**
   * Set the statsUrl for the app, this will be used to send statistics. Passing an empty string will disable statistics gathering.
   *
   * @param options contains the URL to use for sending statistics.
   * @returns {Promise<void>}
   * @throws {Error}
   * @since 5.4.0
   */
  setStatsUrl(options: StatsUrl): Promise<void>;

  /**
   * Set the channelUrl for the app, this will be used to set the channel.
   *
   * @param options contains the URL to use for setting the channel.
   * @returns {Promise<void>}
   * @throws {Error}
   * @since 5.4.0
   */
  setChannelUrl(options: ChannelUrl): Promise<void>;

  /**
   * Download a new bundle from the provided URL, it should be a zip file, with files inside or with a unique id inside with all your files
   *
   * @example const bundle = await CapacitorUpdater.download({ url: `https://example.com/versions/${version}/dist.zip`, version });
   * @returns {Promise<BundleInfo>} The {@link BundleInfo} for the specified bundle.
   * @param options The {@link DownloadOptions} for downloading a new bundle zip.
   */
  download(options: DownloadOptions): Promise<BundleInfo>;

  /**
   * Set the next bundle to be used when the app is reloaded.
   *
   * @param options Contains the ID of the next Bundle to set on next app launch. {@link BundleInfo.id}
   * @returns {Promise<BundleInfo>} The {@link BundleInfo} for the specified bundle id.
   * @throws {Error} When there is no index.html file inside the bundle folder.
   */
  next(options: BundleId): Promise<BundleInfo>;

  /**
   * Set the current bundle and immediately reloads the app.
   *
   * @param options A {@link BundleId} object containing the new bundle id to set as current.
   * @returns {Promise<void>}
   * @throws {Error} When there are is no index.html file inside the bundle folder.
   */
  set(options: BundleId): Promise<void>;

  /**
   * Deletes the specified bundle from the native app storage. Use with {@link list} to get the stored Bundle IDs.
   *
   * @param options A {@link BundleId} object containing the ID of a bundle to delete (note, this is the bundle id, NOT the version name)
   * @returns {Promise<void>} When the bundle is deleted
   * @throws {Error}
   */
  delete(options: BundleId): Promise<void>;

  /**
   * Get all locally downloaded bundles in your app
   *
   * @returns {Promise<BundleListResult>} A Promise containing the {@link BundleListResult.bundles}
   * @param options The {@link ListOptions} for listing bundles
   * @throws {Error}
   */
  list(options?: ListOptions): Promise<BundleListResult>;

  /**
   * Reset the app to the `builtin` bundle (the one sent to Apple App Store / Google Play Store ) or the last successfully loaded bundle.
   *
   * @param options Containing {@link ResetOptions.toLastSuccessful}, `true` resets to the builtin bundle and `false` will reset to the last successfully loaded bundle.
   * @returns {Promise<void>}
   * @throws {Error}
   */
  reset(options?: ResetOptions): Promise<void>;

  /**
   * Get the current bundle, if none are set it returns `builtin`. currentNative is the original bundle installed on the device
   *
   * @returns {Promise<CurrentBundleResult>} A Promise evaluating to the {@link CurrentBundleResult}
   * @throws {Error}
   */
  current(): Promise<CurrentBundleResult>;

  /**
   * Reload the view
   *
   * @returns {Promise<void>} A Promise which is resolved when the view is reloaded
   * @throws {Error}
   */
  reload(): Promise<void>;

  /**
   * Sets a {@link DelayCondition} array containing conditions that the Plugin will use to delay the update.
   * After all conditions are met, the update process will run start again as usual, so update will be installed after a backgrounding or killing the app.
   * For the `date` kind, the value should be an iso8601 date string.
   * For the `background` kind, the value should be a number in milliseconds.
   * For the `nativeVersion` kind, the value should be the version number.
   * For the `kill` kind, the value is not used.
   * The function has unconsistent behavior the option kill do trigger the update after the first kill and not after the next background like other options. This will be fixed in a future major release.
   *
   * @example
   * // Delay the update after the user kills the app or after a background of 300000 ms (5 minutes)
   * await CapacitorUpdater.setMultiDelay({ delayConditions: [{ kind: 'kill' }, { kind: 'background', value: '300000' }] })
   * @example
   * // Delay the update after the specific iso8601 date is expired
   * await CapacitorUpdater.setMultiDelay({ delayConditions: [{ kind: 'date', value: '2022-09-14T06:14:11.920Z' }] })
   * @example
   * // Delay the update after the first background (default behaviour without setting delay)
   * await CapacitorUpdater.setMultiDelay({ delayConditions: [{ kind: 'background' }] })
   * @param options Containing the {@link MultiDelayConditions} array of conditions to set
   * @returns {Promise<void>}
   * @throws {Error}
   * @since 4.3.0
   */
  setMultiDelay(options: MultiDelayConditions): Promise<void>;

  /**
   * Cancels a {@link DelayCondition} to process an update immediately.
   *
   * @returns {Promise<void>}
   * @throws {Error}
   * @since 4.0.0
   */
  cancelDelay(): Promise<void>;

  /**
   * Get Latest bundle available from update Url
   *
   * @returns {Promise<LatestVersion>} A Promise resolved when url is loaded
   * @throws {Error}
   * @since 4.0.0
   */
  getLatest(options?: GetLatestOptions): Promise<LatestVersion>;

  /**
   * Sets the channel for this device. The channel has to allow for self assignment for this to work.
   * Do not use this method to set the channel at boot when `autoUpdate` is enabled in the {@link PluginsConfig}.
   * This method is to set the channel after the app is ready.
   * This methods send to Capgo backend a request to link the device ID to the channel. Capgo can accept or refuse depending of the setting of your channel.
   *
   *
   *
   * @param options Is the {@link SetChannelOptions} channel to set
   * @returns {Promise<ChannelRes>} A Promise which is resolved when the new channel is set
   * @throws {Error}
   * @since 4.7.0
   */
  setChannel(options: SetChannelOptions): Promise<ChannelRes>;

  /**
   * Unset the channel for this device. The device will then return to the default channel
   *
   * @returns {Promise<ChannelRes>} A Promise resolved when channel is set
   * @throws {Error}
   * @since 4.7.0
   */
  unsetChannel(options: UnsetChannelOptions): Promise<void>;

  /**
   * Get the channel for this device
   *
   * @returns {Promise<ChannelRes>} A Promise that resolves with the channel info
   * @throws {Error}
   * @since 4.8.0
   */
  getChannel(): Promise<GetChannelRes>;

  /**
   * Set a custom ID for this device
   *
   * @param options is the {@link SetCustomIdOptions} customId to set
   * @returns {Promise<void>} an Promise resolved instantly
   * @throws {Error}
   * @since 4.9.0
   */
  setCustomId(options: SetCustomIdOptions): Promise<void>;

  /**
   * Get the native app version or the builtin version if set in config
   *
   * @returns {Promise<BuiltinVersion>} A Promise with version for this device
   * @since 5.2.0
   */
  getBuiltinVersion(): Promise<BuiltinVersion>;

  /**
   * Get unique ID used to identify device (sent to auto update server)
   *
   * @returns {Promise<DeviceId>} A Promise with id for this device
   * @throws {Error}
   */
  getDeviceId(): Promise<DeviceId>;

  /**
   * Get the native Capacitor Updater plugin version (sent to auto update server)
   *
   * @returns {Promise<PluginVersion>} A Promise with Plugin version
   * @throws {Error}
   */
  getPluginVersion(): Promise<PluginVersion>;

  /**
   * Get the state of auto update config.
   *
   * @returns {Promise<AutoUpdateEnabled>} The status for auto update. Evaluates to `false` in manual mode.
   * @throws {Error}
   */
  isAutoUpdateEnabled(): Promise<AutoUpdateEnabled>;

  /**
   * Remove all listeners for this plugin.
   *
   * @since 1.0.0
   */
  removeAllListeners(): Promise<void>;

  /**
   * Listen for bundle download event in the App. Fires once a download has started, during downloading and when finished.
   *
   * @since 2.0.11
   */
  addListener(eventName: 'download', listenerFunc: (state: DownloadEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Listen for no need to update event, useful when you want force check every time the app is launched
   *
   * @since 4.0.0
   */
  addListener(eventName: 'noNeedUpdate', listenerFunc: (state: NoNeedEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Listen for available update event, useful when you want to force check every time the app is launched
   *
   * @since 4.0.0
   */
  addListener(
    eventName: 'updateAvailable',
    listenerFunc: (state: UpdateAvailableEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for downloadComplete events.
   *
   * @since 4.0.0
   */
  addListener(
    eventName: 'downloadComplete',
    listenerFunc: (state: DownloadCompleteEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for Major update event in the App, let you know when major update is blocked by setting disableAutoUpdateBreaking
   *
   * @since 2.3.0
   */
  addListener(
    eventName: 'majorAvailable',
    listenerFunc: (state: MajorAvailableEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for update fail event in the App, let you know when update has fail to install at next app start
   *
   * @since 2.3.0
   */
  addListener(
    eventName: 'updateFailed',
    listenerFunc: (state: UpdateFailedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for download fail event in the App, let you know when a bundle download has failed
   *
   * @since 4.0.0
   */
  addListener(
    eventName: 'downloadFailed',
    listenerFunc: (state: DownloadFailedEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   *  Listen for reload event in the App, let you know when reload has happened
   *
   * @since 4.3.0
   */
  addListener(eventName: 'appReloaded', listenerFunc: () => void): Promise<PluginListenerHandle>;

  /**
   * Listen for app ready event in the App, let you know when app is ready to use
   *
   * @since 5.1.0
   */
  addListener(eventName: 'appReady', listenerFunc: (state: AppReadyEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Get if auto update is available (not disabled by serverUrl).
   *
   * @returns {Promise<AutoUpdateAvailable>} The availability status for auto update. Evaluates to `false` when serverUrl is set.
   * @throws {Error}
   */
  isAutoUpdateAvailable(): Promise<AutoUpdateAvailable>;

  /**
   * Get the next bundle that will be used when the app reloads.
   * Returns null if no next bundle is set.
   *
   * @returns {Promise<BundleInfo | null>} A Promise that resolves with the next bundle information or null
   * @throws {Error}
   * @since 6.8.0
   */
  getNextBundle(): Promise<BundleInfo | null>;
}

export type BundleStatus = 'success' | 'error' | 'pending' | 'downloading';

export type DelayUntilNext = 'background' | 'kill' | 'nativeVersion' | 'date';

export interface NoNeedEvent {
  /**
   * Current status of download, between 0 and 100.
   *
   * @since  4.0.0
   */
  bundle: BundleInfo;
}

export interface UpdateAvailableEvent {
  /**
   * Current status of download, between 0 and 100.
   *
   * @since  4.0.0
   */
  bundle: BundleInfo;
}

export interface ChannelRes {
  /**
   * Current status of set channel
   *
   * @since  4.7.0
   */
  status: string;
  error?: string;
  message?: string;
}

export interface GetChannelRes {
  /**
   * Current status of get channel
   *
   * @since  4.8.0
   */
  channel?: string;
  error?: string;
  message?: string;
  status?: string;
  allowSet?: boolean;
}

export interface DownloadEvent {
  /**
   * Current status of download, between 0 and 100.
   *
   * @since  4.0.0
   */
  percent: number;
  bundle: BundleInfo;
}

export interface MajorAvailableEvent {
  /**
   * Emit when a new major bundle is available.
   *
   * @since  4.0.0
   */
  version: string;
}

export interface DownloadFailedEvent {
  /**
   * Emit when a download fail.
   *
   * @since  4.0.0
   */
  version: string;
}

export interface DownloadCompleteEvent {
  /**
   * Emit when a new update is available.
   *
   * @since  4.0.0
   */
  bundle: BundleInfo;
}

export interface UpdateFailedEvent {
  /**
   * Emit when a update failed to install.
   *
   * @since 4.0.0
   */
  bundle: BundleInfo;
}

export interface AppReadyEvent {
  /**
   * Emitted when the app is ready to use.
   *
   * @since  5.2.0
   */
  bundle: BundleInfo;
  status: string;
}

export interface ManifestEntry {
  file_name: string | null;
  file_hash: string | null;
  download_url: string | null;
}

export interface LatestVersion {
  /**
   * Result of getLatest method
   *
   * @since 4.0.0
   */
  version: string;
  /**
   * @since 6
   */
  checksum?: string;
  major?: boolean;
  message?: string;
  sessionKey?: string;
  error?: string;
  old?: string;
  url?: string;
  /**
   * @since 6.1
   */
  manifest?: ManifestEntry[];
}

export interface BundleInfo {
  id: string;
  version: string;
  downloaded: string;
  checksum: string;
  status: BundleStatus;
}

export interface SetChannelOptions {
  channel: string;
  triggerAutoUpdate?: boolean;
}

export interface UnsetChannelOptions {
  triggerAutoUpdate?: boolean;
}

export interface SetCustomIdOptions {
  customId: string;
}

export interface DelayCondition {
  /**
   * Set up delay conditions in setMultiDelay
   * @param value is useless for @param kind "kill", optional for "background" (default value: "0") and required for "nativeVersion" and "date"
   */
  kind: DelayUntilNext;
  value?: string;
}

export interface GetLatestOptions {
  /**
   * The channel to get the latest version for
   * The channel must allow 'self_assign' for this to work
   * @since 6.8.0
   * @default undefined
   */
  channel?: string;
}

export interface AppReadyResult {
  bundle: BundleInfo;
}

export interface UpdateUrl {
  url: string;
}

export interface StatsUrl {
  url: string;
}

export interface ChannelUrl {
  url: string;
}

export interface DownloadOptions {
  /**
   * The URL of the bundle zip file (e.g: dist.zip) to be downloaded. (This can be any URL. E.g: Amazon S3, a GitHub tag, any other place you've hosted your bundle.)
   */
  url?: string;
  /**
   * The version code/name of this bundle/version
   */
  version: string;
  /**
   * The session key for the update
   * @since 4.0.0
   * @default undefined
   */
  sessionKey?: string;
  /**
   * The checksum for the update
   * @since 4.0.0
   * @default undefined
   */
  checksum?: string;
}

export interface BundleId {
  id: string;
}

export interface BundleListResult {
  bundles: BundleInfo[];
}

export interface ResetOptions {
  toLastSuccessful: boolean;
}

export interface ListOptions {
  /**
   * Whether to return the raw bundle list or the manifest. If true, the list will attempt to read the internal database instead of files on disk.
   * @since 6.14.0
   * @default false
   */
  raw?: boolean;
}

export interface CurrentBundleResult {
  bundle: BundleInfo;
  native: string;
}

export interface MultiDelayConditions {
  delayConditions: DelayCondition[];
}

export interface BuiltinVersion {
  version: string;
}

export interface DeviceId {
  deviceId: string;
}

export interface PluginVersion {
  version: string;
}

export interface AutoUpdateEnabled {
  enabled: boolean;
}

export interface AutoUpdateAvailable {
  available: boolean;
}
