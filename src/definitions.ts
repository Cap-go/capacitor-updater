/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/// <reference types="@capacitor/cli" />
import type { PluginListenerHandle } from "@capacitor/core";

declare module "@capacitor/cli" {
  export interface PluginsConfig {
    /**
     * These configuration values are available:
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
       * @default https://api.capgo.app/auto_update
       * @example https://example.com/api/auto_update
       */
      updateUrl?: string;

      /**
       * Configure the URL / endpoint to which update statistics are sent.
       *
       * Only available for Android and iOS. Set to "" to disable stats reporting.
       *
       * @default https://api.capgo.app/stats
       * @example https://example.com/api/stats
       */
      statsUrl?: string;
      /**
       * Configure the private key for end to end live update encryption.
       *
       * Only available for Android and iOS.
       *
       * @default undefined
       */
      privateKey?: string;

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
    };
  }
}

export interface noNeedEvent {
  /**
   * Current status of download, between 0 and 100.
   *
   * @since  4.0.0
   */
  bundle: BundleInfo;
}
export interface updateAvailableEvent {
  /**
   * Current status of download, between 0 and 100.
   *
   * @since  4.0.0
   */
  bundle: BundleInfo;
}

export interface channelRes {
  /**
   * Current status of set channel
   *
   * @since  4.7.0
   */
  status: string;
  error?: any;
  message?: any;
}

export interface getChannelRes {
  /**
   * Current status of get channel
   *
   * @since  4.8.0
   */
  channel?: string;
  error?: any;
  message?: any;
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
   * Emit when a app is ready to use.
   *
   * @since  5.2.0
   */
  bundle: BundleInfo;
  status: string;
}

export interface latestVersion {
  /**
   * Res of getLatest method
   *
   * @since 4.0.0
   */
  version: string;
  major?: boolean;
  message?: string;
  sessionKey?: string;
  error?: string;
  old?: string;
  url?: string;
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

export type BundleStatus = "success" | "error" | "pending" | "downloading";
export type DelayUntilNext = "background" | "kill" | "nativeVersion" | "date";

export type DownloadChangeListener = (state: DownloadEvent) => void;
export type NoNeedListener = (state: noNeedEvent) => void;
export type UpdateAvailabledListener = (state: updateAvailableEvent) => void;
export type DownloadFailedListener = (state: DownloadFailedEvent) => void;
export type DownloadCompleteListener = (state: DownloadCompleteEvent) => void;
export type MajorAvailableListener = (state: MajorAvailableEvent) => void;
export type UpdateFailedListener = (state: UpdateFailedEvent) => void;
export type AppReloadedListener = (state: void) => void;
export type AppReadyListener = (state: AppReadyEvent) => void;

export interface CapacitorUpdaterPlugin {
  /**
   * Notify Capacitor Updater that the current bundle is working (a rollback will occur of this method is not called on every app launch)
   * By default this method should be called in the first 10 sec after app launch, otherwise a rollback will occur.
   * Change this behaviour with {@link appReadyTimeout}
   *
   * @returns {Promise<BundleInfo>} an Promise resolved directly
   * @throws An error if something went wrong
   */
  notifyAppReady(): Promise<BundleInfo>;

  /**
   * Download a new bundle from the provided URL, it should be a zip file, with files inside or with a unique id inside with all your files
   *
   * @returns {Promise<BundleInfo>} The {@link BundleInfo} for the specified bundle.
   * @param url The URL of the bundle zip file (e.g: dist.zip) to be downloaded. (This can be any URL. E.g: Amazon S3, a github tag, any other place you've hosted your bundle.)
   * @param version set the version code/name of this bundle/version
   * @example https://example.com/versions/{version}/dist.zip
   */
  download(options: {
    url: string;
    version: string;
    sessionKey?: string;
    checksum?: string;
  }): Promise<BundleInfo>;

  /**
   * Set the next bundle to be used when the app is reloaded.
   *
   * @returns {Promise<BundleInfo>} The {@link BundleInfo} for the specified bundle id.
   * @param id The bundle id to set as current, next time the app is reloaded. See {@link BundleInfo.id}
   * @throws An error if there are is no index.html file inside the bundle folder.
   */
  next(options: { id: string }): Promise<BundleInfo>;

  /**
   * Set the current bundle and immediately reloads the app.
   *
   * @param id The bundle id to set as current. See {@link BundleInfo.id}
   * @returns {Promise<Void>} An empty promise.
   * @throws An error if there are is no index.html file inside the bundle folder.
   */
  set(options: { id: string }): Promise<void>;

  /**
   * Delete bundle in storage
   *
   * @returns {Promise<void>} an empty Promise when the bundle is deleted
   * @param id The bundle id to delete (note, this is the bundle id, NOT the version name)
   * @throws An error if the something went wrong
   */
  delete(options: { id: string }): Promise<void>;

  /**
   * Get all available bundles
   *
   * @returns {Promise<{bundles: BundleInfo[]}>} an Promise witht the bundles list
   * @throws An error if the something went wrong
   */
  list(): Promise<{ bundles: BundleInfo[] }>;

  /**
   * Set the `builtin` bundle (the one sent to Apple store / Google play store ) as current bundle
   *
   * @returns {Promise<void>} an empty Promise
   * @param toLastSuccessful [false] if yes it reset to to the last successfully loaded bundle instead of `builtin`
   * @throws An error if the something went wrong
   */
  reset(options?: { toLastSuccessful?: boolean }): Promise<void>;

  /**
   * Get the current bundle, if none are set it returns `builtin`, currentNative is the original bundle installed on the device
   *
   * @returns {Promise<{ bundle: BundleInfo, native: string }>} an Promise with the current bundle info
   * @throws An error if the something went wrong
   */
  current(): Promise<{ bundle: BundleInfo; native: string }>;

  /**
   * Reload the view
   *
   * @returns {Promise<void>} an Promise resolved when the view is reloaded
   * @throws An error if the something went wrong
   */
  reload(): Promise<void>;

  /**
   * Set DelayCondition, skip updates until one of the conditions is met
   *
   * @returns {Promise<void>} an Promise resolved directly
   * @param options are the {@link DelayCondition} list to set
   *
   * @example
   * setMultiDelay({ delayConditions: [{ kind: 'kill' }, { kind: 'background', value: '300000' }] })
   * // installs the update after the user kills the app or after a background of 300000 ms (5 minutes)
   *
   * @example
   * setMultiDelay({ delayConditions: [{ kind: 'date', value: '2022-09-14T06:14:11.920Z' }] })
   * // installs the update after the specific iso8601 date is expired
   *
   * @example
   * setMultiDelay({ delayConditions: [{ kind: 'background' }] })
   * // installs the update after the the first background (default behaviour without setting delay)
   *
   * @throws An error if the something went wrong
   * @since 4.3.0
   */
  setMultiDelay(options: { delayConditions: DelayCondition[] }): Promise<void>;

  /**
   * Cancel delay to updates as usual
   *
   * @returns {Promise<void>} an Promise resolved directly
   * @throws An error if the something went wrong
   * @since 4.0.0
   */
  cancelDelay(): Promise<void>;

  /**
   * Get Latest bundle available from update Url
   *
   * @returns {Promise<latestVersion>} an Promise resolved when url is loaded
   * @throws An error if the something went wrong
   * @since 4.0.0
   */
  getLatest(): Promise<latestVersion>;

  /**
   * Set Channel for this device, the channel have to allow self assignement to make this work
   *
   * @returns {Promise<channelRes>} an Promise resolved when channel is set
   * @param options is the {@link SetChannelOptions} channel to set
   * @throws An error if the something went wrong
   * @since 4.7.0
   */
  setChannel(options: SetChannelOptions): Promise<channelRes>;

  /**
   * get Channel for this device
   *
   * @returns {Promise<channelRes>} an Promise resolved with channel info
   * @throws An error if the something went wrong
   * @since 4.8.0
   */
  getChannel(): Promise<getChannelRes>;

  /**
   * Set Channel for this device
   *
   * @returns {Promise<void>} an Promise resolved instantly
   * @param options is the {@link SetCustomIdOptions} customId to set
   * @throws An error if the something went wrong
   * @since 4.9.0
   */
  setCustomId(options: SetCustomIdOptions): Promise<void>;

  /**
   * Listen for download event in the App, let you know when the download is started, loading and finished
   *
   * @since 2.0.11
   */
  addListener(
    eventName: "download",
    listenerFunc: DownloadChangeListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for no need to update event, usefull when you want force check every time the app is launched
   *
   * @since 4.0.0
   */
  addListener(
    eventName: "noNeedUpdate",
    listenerFunc: NoNeedListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;
  /**
   * Listen for availbale update event, usefull when you want to force check every time the app is launched
   *
   * @since 4.0.0
   */
  addListener(
    eventName: "updateAvailable",
    listenerFunc: UpdateAvailabledListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for download event in the App, let you know when the download is started, loading and finished
   *
   * @since 4.0.0
   */
  addListener(
    eventName: "downloadComplete",
    listenerFunc: DownloadCompleteListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for Major update event in the App, let you know when major update is blocked by setting disableAutoUpdateBreaking
   *
   * @since 2.3.0
   */
  addListener(
    eventName: "majorAvailable",
    listenerFunc: MajorAvailableListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for update fail event in the App, let you know when update has fail to install at next app start
   *
   * @since 2.3.0
   */
  addListener(
    eventName: "updateFailed",
    listenerFunc: UpdateFailedListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for download fail event in the App, let you know when download has fail finished
   *
   * @since 4.0.0
   */
  addListener(
    eventName: "downloadFailed",
    listenerFunc: DownloadFailedListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for download fail event in the App, let you know when download has fail finished
   *
   * @since 4.3.0
   */
  addListener(
    eventName: "appReloaded",
    listenerFunc: AppReloadedListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Listen for app ready event in the App, let you know when app is ready to use
   *
   * @since 5.1.0
   */
  addListener(
    eventName: "appReady",
    listenerFunc: AppReadyListener
  ): Promise<PluginListenerHandle> & PluginListenerHandle;

  /**
   * Get the native app version or the builtin version if set in config
   *
   * @returns {Promise<{ version: string }>} an Promise with version for this device
   * @since 5.2.0
   */
  getBuiltinVersion(): Promise<{ version: string }>;

  /**
   * Get unique ID used to identify device (sent to auto update server)
   *
   * @returns {Promise<{ deviceId: string }>} an Promise with id for this device
   * @throws An error if the something went wrong
   */
  getDeviceId(): Promise<{ deviceId: string }>;

  /**
   * Get the native Capacitor Updater plugin version (sent to auto update server)
   *
   * @returns {Promise<{ id: string }>} an Promise with version for this device
   * @throws An error if the something went wrong
   */
  getPluginVersion(): Promise<{ version: string }>;

  /**
   * Get the state of auto update config. This will return `false` in manual mode.
   *
   * @returns {Promise<{enabled: boolean}>} The status for auto update.
   * @throws An error if the something went wrong
   */
  isAutoUpdateEnabled(): Promise<{ enabled: boolean }>;

  /**
   * Remove all listeners for this plugin.
   *
   * @since 1.0.0
   */
  removeAllListeners(): Promise<void>;
}
