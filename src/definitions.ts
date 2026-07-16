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
       * @example 1000 // (1 second, minimum 1000)
       */
      appReadyTimeout?: number;

      /**
       * Configure the number of seconds the native plugin should wait before considering API timeout.
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
       * Configure how the plugin checks for, downloads, and applies live updates.
       *
       * The plugin checks for updates when the app moves to the foreground. When
       * {@link periodCheckDelay} is greater than 0, it also checks on a repeating timer
       * while the app stays open.
       *
       * Boolean values keep their existing behavior:
       * - `true`: Same as `"atBackground"`.
       * - `false`: Same as `"off"`.
       *
       * String values merge the previous Auto Update and Direct Update configuration:
       * - `"off"`: Disable automatic update checks.
       * - `"atBackground"`: Check and download automatically on each foreground check, then apply the update the next time the app moves to background.
       * - `"atInstall"`: Apply immediately only after a fresh install or native app store update; otherwise use `"atBackground"` behavior.
       * - `"onLaunch"`: Apply immediately only when the app is brought to the foreground from a killed state (cold start). After that first check, fall back to `"atBackground"` behavior.
       * - `"always"`: Check on every foreground transition and apply immediately whenever an update is available.
       * - `"onlyDownload"`: Check and download automatically, emit `updateAvailable`, and never set the next bundle or apply an update automatically.
       *
       * Only available for Android and iOS.
       *
       * @default true
       * @example "onlyDownload"
       */
      autoUpdate?: boolean | 'off' | 'atBackground' | 'atInstall' | 'onLaunch' | 'always' | 'onlyDownload';

      /**
       * Automatically delete previous downloaded bundles when a newer native app bundle is installed to the device.
       * Setting this to false can broke the auto update flow if the user download from the store a native app bundle that is older than the current downloaded bundle. Upload will be prevented by channel setting downgrade_under_native.
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
       * Native stats include update lifecycle events, app health signals such as crashes,
       * Android ANRs, low-memory exits, iOS memory warnings, and WebView health signals
       * such as JavaScript errors, unhandled promise rejections, resource load failures,
       * WebView renderer exits, unclean WebView restarts, app launch readiness timing,
       * and WebView load milestones when available.
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
       * Configure when the plugin should direct install updates. Only for autoUpdate mode.
       *
       * @deprecated Use {@link PluginsConfig.CapacitorUpdater.autoUpdate} string modes instead.
       * Works well for apps less than 10MB and with uploads done using --delta flag.
       * Zip or apps more than 10MB will be relatively slow for users to update.
       * - false: Never do direct updates
       * - atInstall: Same as `"atInstall"` for {@link autoUpdate}
       * - onLaunch: Same as `"onLaunch"` for {@link autoUpdate}
       * - always: Same as `"always"` for {@link autoUpdate}
       * - true: (deprecated) Same as "always" for backward compatibility
       *
       * Activate this flag will automatically make the CLI upload delta in CICD envs and will ask for confirmation in local uploads.
       * Only available for Android and iOS.
       *
       * @default false
       * @since  5.1.0
       */
      directUpdate?: boolean | 'atInstall' | 'always' | 'onLaunch';

      /**
       * Automatically handle splashscreen hiding when using directUpdate. When enabled, the plugin will automatically hide the splashscreen after updates are applied or when no update is needed.
       * This removes the need to manually listen for appReady events and call SplashScreen.hide().
       * Only works when autoUpdate is set to "atInstall", "always", or "onLaunch", or when the deprecated directUpdate option is set to "atInstall", "always", "onLaunch", or true.
       * Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false.
       * Requires Auto Update and Direct Update behavior to be enabled.
       *
       * Only available for Android and iOS.
       *
       * @default false
       * @since  7.6.0
       */
      autoSplashscreen?: boolean;

      /**
       * Display a native loading indicator on top of the splashscreen while automatic direct updates are running.
       * Only takes effect when {@link autoSplashscreen} is enabled.
       * Requires the @capacitor/splash-screen plugin to be installed and configured with launchAutoHide: false.
       *
       * Only available for Android and iOS.
       *
       * @default false
       * @since  7.19.0
       */
      autoSplashscreenLoader?: boolean;

      /**
       * Automatically hide the splashscreen after the specified number of milliseconds when using automatic direct updates.
       * If the timeout elapses, the update continues to download in the background while the splashscreen is dismissed.
       * Set to `0` (zero) to disable the timeout.
       * When the timeout fires, the direct update flow is skipped and the downloaded bundle is installed on the next background/launch.
       * Requires {@link autoSplashscreen} to be enabled.
       *
       * Only available for Android and iOS.
       *
       * @default 10000 // (10 seconds)
       * @since  7.19.0
       */
      autoSplashscreenTimeout?: number;

      /**
       * Configure the interval in seconds for repeating update checks while the app stays open.
       * Foreground checks still run when this is 0. Values below 600 are normalized to 600.
       *
       * Only available for Android and iOS.
       * Cannot be less than 600 seconds (10 minutes).
       *
       * @default 0 (disabled)
       * @example 3600 (1 hour)
       * @example 86400 (24 hours)
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
       * Allow the plugin to modify the appId dynamically from the JavaScript side.
       *
       *
       * @default false
       * @since  7.14.0
       */
      allowModifyAppId?: boolean;

      /**
       * Allow marking bundles as errored from JavaScript while using manual update flows.
       * When enabled, {@link CapacitorUpdaterPlugin.setBundleError} can change a bundle status to `error`.
       *
       * @default false
       * @since 7.20.0
       */
      allowManualBundleError?: boolean;

      /**
       * Allow JavaScript to start a native preview session and temporarily request updates for another app id.
       * This is intended for trusted container apps that implement Expo Go-style preview flows.
       *
       * Only available for Android and iOS.
       *
       * @default false
       * @since 8.47.0
       */
      allowPreview?: boolean;

      /**
       * Persist the customId set through {@link CapacitorUpdaterPlugin.setCustomId} across app restarts.
       *
       * Only available for Android and iOS.
       *
       * @default false (will be true by default in a future major release v8.x.x)
       * @since  7.17.3
       */
      persistCustomId?: boolean;

      /**
       * Persist the updateUrl, statsUrl and channelUrl set through {@link CapacitorUpdaterPlugin.setUpdateUrl},
       * {@link CapacitorUpdaterPlugin.setStatsUrl} and {@link CapacitorUpdaterPlugin.setChannelUrl} across app restarts.
       *
       * Only available for Android and iOS.
       *
       * @default false
       * @since  7.20.0
       */
      persistModifyUrl?: boolean;

      /**
       * Allow or disallow the {@link CapacitorUpdaterPlugin.setChannel} method to modify the defaultChannel.
       * When set to `false`, calling `setChannel()` will return an error with code `disabled_by_config`.
       *
       * @default true
       * @since 7.34.0
       */
      allowSetDefaultChannel?: boolean;

      /**
       * Keep the default channel stored by {@link CapacitorUpdaterPlugin.setChannel} or refreshed by
       * {@link CapacitorUpdaterPlugin.getChannel} when app data is restored into a new app install.
       *
       * `setChannel()` and a successful `getChannel()` still persist the selected channel across app
       * restarts. When this option is `false`, native startup clears that persisted channel when it
       * detects app data restored into a new installation. Native build cleanup also clears it when
       * `resetWhenUpdate` is enabled.
       *
       * Only available for Android and iOS.
       *
       * @default true
       * @since 8.51.0
       */
      persistDefaultChannelOnReinstall?: boolean;

      /**
       * Set the default channel for the app in the config. Case sensitive.
       * This will setting will override the default channel set in the cloud, but will still respect overrides made in the cloud.
       * This requires the channel to allow devices to self dissociate/associate in the channel settings. https://capgo.app/docs/public-api/channels/#channel-configuration-options
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

      /**
       * Disable the JavaScript logging of the plugin. if true, the plugin will not log to the JavaScript console. only the native log will be done
       *
       * @default false
       * @since  7.3.0
       */
      disableJSLogging?: boolean;

      /**
       * Enable OS-level logging. When enabled, logs are written to the system log which can be inspected in production builds.
       *
       * - **iOS**: Uses os_log instead of Swift.print, logs accessible via Console.app or Instruments
       * - **Android**: Logs to Logcat (android.util.Log)
       *
       * When set to false, system logging is disabled on both platforms (only JavaScript console logging will occur if enabled).
       *
       * This is useful for debugging production apps (App Store/TestFlight builds on iOS, or production APKs on Android).
       *
       * @default true
       * @since  8.42.0
       */
      osLogging?: boolean;

      /**
       * Enable the native preview menu gesture while a preview session is active.
       * Outside preview sessions this preview menu is ignored, unless
       * {@link PluginsConfig.CapacitorUpdater.allowShakeChannelSelector} is enabled.
       *
       * @default false
       * @since  7.5.0
       */
      shakeMenu?: boolean;

      /**
       * Choose which native gesture opens the preview/channel menu.
       * This applies to both {@link PluginsConfig.CapacitorUpdater.shakeMenu}
       * and {@link PluginsConfig.CapacitorUpdater.allowShakeChannelSelector}.
       *
       * Only available for Android and iOS.
       *
       * @default 'shake'
       * @since  8.48.0
       */
      shakeMenuGesture?: ShakeMenuGesture;

      /**
       * Enable the native menu gesture to show a channel selector menu for switching between update channels.
       * If {@link PluginsConfig.CapacitorUpdater.shakeMenu} is also enabled while a preview session is active,
       * the shake menu includes both preview actions and channel switching.
       * The native gesture can be changed with {@link PluginsConfig.CapacitorUpdater.shakeMenuGesture}.
       *
       * Only available for Android and iOS.
       *
       * @default false
       * @since 8.43.0
       */
      allowShakeChannelSelector?: boolean;
    };
  }
}

export interface CapacitorUpdaterPlugin {
  /**
   * Notify the native layer that JavaScript initialized successfully.
   *
   * **CRITICAL: You must call this method on every app launch to prevent automatic rollback.**
   *
   * This is a simple notification to confirm that your bundle's JavaScript loaded and executed.
   * The native web server successfully served the bundle files and your JS runtime started.
   * That's all it checks - nothing more complex.
   *
   * **What triggers rollback:**
   * - NOT calling this method within the timeout (default: 10 seconds)
   * - Complete JavaScript failure (bundle won't load at all)
   *
   * **What does NOT trigger rollback:**
   * - Runtime errors after initialization (API failures, crashes, etc.)
   * - Network request failures
   * - Application logic errors
   *
   * **IMPORTANT: Call this BEFORE any network requests.**
   * Don't wait for APIs, data loading, or async operations. Call it as soon as your
   * JavaScript bundle starts executing to confirm the bundle itself is valid.
   *
   * Best practices:
   * - Call immediately in your app entry point (main.js, app component mount, etc.)
   * - Don't put it after network calls or heavy initialization
   * - Don't wrap it in try/catch with conditions
   * - Adjust {@link PluginsConfig.CapacitorUpdater.appReadyTimeout} if you need more time
   *
   * @returns {Promise<AppReadyResult>} Always resolves successfully with current bundle info. This method never fails.
   */
  notifyAppReady(): Promise<AppReadyResult>;

  /**
   * Set the update URL for the app dynamically at runtime.
   *
   * This overrides the {@link PluginsConfig.CapacitorUpdater.updateUrl} config value.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.
   *
   * Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
   * Otherwise, the URL will reset to the config value on next app launch.
   *
   * @param options Contains the URL to use for checking for updates.
   * @returns {Promise<void>} Resolves when the URL is successfully updated.
   * @throws {Error} If `allowModifyUrl` is false or if the operation fails.
   * @since 5.4.0
   */
  setUpdateUrl(options: UpdateUrl): Promise<void>;

  /**
   * Set the statistics URL for the app dynamically at runtime.
   *
   * This overrides the {@link PluginsConfig.CapacitorUpdater.statsUrl} config value.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.
   *
   * Pass an empty string to disable statistics gathering entirely.
   * Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
   *
   * @param options Contains the URL to use for sending statistics, or an empty string to disable.
   * @returns {Promise<void>} Resolves when the URL is successfully updated.
   * @throws {Error} If `allowModifyUrl` is false or if the operation fails.
   * @since 5.4.0
   */
  setStatsUrl(options: StatsUrl): Promise<void>;

  /**
   * Set the channel URL for the app dynamically at runtime.
   *
   * This overrides the {@link PluginsConfig.CapacitorUpdater.channelUrl} config value.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowModifyUrl} to be set to `true`.
   *
   * Use {@link PluginsConfig.CapacitorUpdater.persistModifyUrl} to persist this value across app restarts.
   * Otherwise, the URL will reset to the config value on next app launch.
   *
   * @param options Contains the URL to use for channel operations.
   * @returns {Promise<void>} Resolves when the URL is successfully updated.
   * @throws {Error} If `allowModifyUrl` is false or if the operation fails.
   * @since 5.4.0
   */
  setChannelUrl(options: ChannelUrl): Promise<void>;

  /**
   * Download a new bundle from the provided URL for later installation.
   *
   * The downloaded bundle is stored locally but not activated. To use it:
   * - Call {@link next} to set it for installation on next app backgrounding/restart
   * - Call {@link set} to activate it immediately (destroys current JavaScript context)
   *
   * The URL should point to a zip file containing either:
   * - Your app files directly in the zip root, or
   * - A single folder containing all your app files
   *
   * The bundle must include an `index.html` file at the root level.
   *
   * For encrypted bundles, provide the `sessionKey` and `checksum` parameters.
   * For multi-file delta updates, provide the `manifest` array.
   *
   * **Android Background Runner note:** `@capacitor/background-runner` loads its
   * configured runner script from native APK assets. Live updates cannot replace
   * that runner script. Keep it stable across OTA updates and ship a native app
   * update when the runner code changes. When a bundle switch happens, Capacitor
   * Updater cancels and reschedules configured Background Runner WorkManager jobs
   * and syncs the bundled runner script into native `public/` storage when present.
   *
   * @example
   * const bundle = await CapacitorUpdater.download({
   *   url: `https://example.com/versions/${version}/dist.zip`,
   *   version: version
   * });
   * // Bundle is downloaded but not active yet
   * await CapacitorUpdater.next({ id: bundle.id }); // Will activate on next background
   *
   * @param options The {@link DownloadOptions} for downloading a new bundle zip.
   * @returns {Promise<BundleInfo>} The {@link BundleInfo} for the downloaded bundle.
   * @throws {Error} If the download fails or the bundle is invalid.
   */
  download(options: DownloadOptions): Promise<BundleInfo>;

  /**
   * Set the next bundle to be activated when the app backgrounds or restarts.
   *
   * This is the recommended way to apply updates as it doesn't interrupt the user's current session.
   * The bundle will be activated when:
   * - The app is backgrounded (user switches away), or
   * - The app is killed and relaunched, or
   * - {@link reload} is called manually
   *
   * Unlike {@link set}, this method does NOT destroy the current JavaScript context immediately.
   * Your app continues running normally until one of the above events occurs.
   *
   * Use {@link setMultiDelay} to add additional conditions before the update is applied.
   *
   * @param options Contains the ID of the bundle to set as next. Use {@link BundleInfo.id} from a downloaded bundle.
   * @returns {Promise<BundleInfo>} The {@link BundleInfo} for the specified bundle.
   * @throws {Error} When there is no index.html file inside the bundle folder or the bundle doesn't exist.
   */
  next(options: BundleId): Promise<BundleInfo>;

  /**
   * Set the current bundle and immediately reloads the app.
   *
   * **IMPORTANT: This is a terminal operation that destroys the current JavaScript context.**
   *
   * When you call this method:
   * - The entire JavaScript context is immediately destroyed
   * - The app reloads from a different folder with different files
   * - NO code after this call will execute
   * - NO promises will resolve
   * - NO callbacks will fire
   * - Event listeners registered after this call are unreliable and may never fire
   *
   * The reload happens automatically - you don't need to do anything else.
   * If you need to preserve state like the current URL path, use the {@link PluginsConfig.CapacitorUpdater.keepUrlPathAfterReload} config option.
   * For other state preservation needs, save your data before calling this method (e.g., to localStorage).
   *
   * **Do not** try to execute additional logic after calling `set()` - it won't work as expected.
   *
   * @param options A {@link BundleId} object containing the new bundle id to set as current.
   * @returns {Promise<void>} A promise that will never resolve because the JavaScript context is destroyed.
   * @throws {Error} When there is no index.html file inside the bundle folder.
   */
  set(options: BundleId): Promise<void>;

  /**
   * Start a temporary preview/testing session.
   *
   * This stores the currently active bundle as the pending fallback, enables the
   * native shake menu, and makes the next applied bundle show a native notice
   * explaining that shaking the device can reload or leave the preview.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowPreview} to be `true`.
   * When `appId` is provided, the preview session temporarily uses that app id
   * for update checks until the user leaves the preview. Native updater stats are
   * skipped while the preview session is active.
   *
   * Use this before calling {@link set} for Expo Go-style preview flows.
   * Use {@link listPreviews}, {@link setPreview}, {@link resetPreview},
   * {@link deletePreview}, {@link checkPreviewUpdate}, and
   * {@link updatePreview} to manage saved local previews.
   *
   * @param options Optional preview session options.
   * @returns {Promise<void>} Resolves when preview session state is prepared.
   * @since 8.47.0
   */
  startPreviewSession(options?: StartPreviewSessionOptions): Promise<void>;

  /**
   * Get every locally available preview bundle that was registered by
   * {@link startPreviewSession} and later applied with {@link set}.
   *
   * This only returns previews whose bundles are still available locally. It is
   * safe to show this in a preview switcher or native debug menu.
   *
   * @returns {Promise<PreviewListResult>} Locally available previews and current preview state.
   * @throws {Error} If preview sessions are not enabled by config.
   * @since 8.49.0
   */
  listPreviews(): Promise<PreviewListResult>;

  /**
   * Switch to a locally available preview bundle and reload the WebView.
   *
   * If the app is not already in a preview session, the current live bundle is
   * saved as the fallback so {@link resetPreview} or the native shake menu can
   * return to it later.
   *
   * @param options A {@link BundleId} object containing the preview bundle ID.
   * @returns {Promise<void>} Resolves once the preview switch is staged.
   * @throws {Error} If preview sessions are disabled or the preview is not available locally.
   * @since 8.49.0
   */
  setPreview(options: BundleId): Promise<void>;

  /**
   * Leave the active preview session and reload the saved live bundle.
   *
   * This does not delete any saved previews. Use {@link deletePreview} to remove
   * a preview from local storage.
   *
   * @returns {Promise<void>} Resolves once the live bundle reload is staged.
   * @throws {Error} If there is no preview fallback bundle available.
   * @since 8.49.0
   */
  resetPreview(): Promise<void>;

  /**
   * Delete a locally saved preview and its bundle when possible.
   *
   * Active previews cannot be deleted until you switch away from them or call
   * {@link resetPreview}. If only the preview metadata can be removed, the
   * method still resolves with `deleted: false`.
   *
   * @param options A {@link BundleId} object containing the preview bundle ID.
   * @returns {Promise<DeletePreviewResult>} Whether the underlying bundle was deleted.
   * @throws {Error} If preview sessions are disabled.
   * @since 8.49.0
   */
  deletePreview(options: BundleId): Promise<DeletePreviewResult>;

  /**
   * Check whether a saved preview's payload URL points to a newer preview bundle.
   *
   * Only previews started with a `payloadUrl` can be checked natively. Direct URL
   * previews can still be switched or deleted locally, but the updater does not
   * know where to check for newer versions.
   *
   * @param options A {@link BundleId} object containing the preview bundle ID.
   * @returns {Promise<PreviewUpdateResult>} Update status for the preview.
   * @throws {Error} If preview sessions are disabled or the preview has no payload URL.
   * @since 8.49.0
   */
  checkPreviewUpdate(options: BundleId): Promise<PreviewUpdateResult>;

  /**
   * Download the newest bundle for a saved preview payload URL.
   *
   * If the preview being updated is active, the new bundle is applied and the
   * WebView reloads. Otherwise, the saved preview entry is moved to the newly
   * downloaded bundle and can be selected later with {@link setPreview}.
   *
   * @param options A {@link BundleId} object containing the preview bundle ID.
   * @returns {Promise<PreviewUpdateResult>} The update result and saved preview metadata.
   * @throws {Error} If preview sessions are disabled or the preview cannot be updated.
   * @since 8.49.0
   */
  updatePreview(options: BundleId): Promise<PreviewUpdateResult>;

  /**
   * Delete a bundle from local storage to free up disk space.
   *
   * You cannot delete:
   * - The currently active bundle
   * - The `builtin` bundle (the version shipped with your app)
   * - The bundle set as `next` (call {@link next} with a different bundle first)
   *
   * Use {@link list} to get all available bundle IDs.
   *
   * **Note:** The bundle ID is NOT the same as the version name.
   * Use the `id` field from {@link BundleInfo}, not the `version` field.
   *
   * @param options A {@link BundleId} object containing the bundle ID to delete.
   * @returns {Promise<void>} Resolves when the bundle is successfully deleted.
   * @throws {Error} If the bundle is currently in use or doesn't exist.
   */
  delete(options: BundleId): Promise<void>;

  /**
   * Manually mark a bundle as failed/errored in manual update mode.
   *
   * This is useful when you detect that a bundle has critical issues and want to prevent
   * it from being used again. The bundle status will be changed to `error` and the plugin
   * will avoid using this bundle in the future.
   *
   * **Requirements:**
   * - {@link PluginsConfig.CapacitorUpdater.allowManualBundleError} must be set to `true`
   * - Only works in manual update mode (when autoUpdate is disabled)
   *
   * Common use case: After downloading and testing a bundle, you discover it has critical
   * bugs and want to mark it as failed so it won't be retried.
   *
   * @param options A {@link BundleId} object containing the bundle ID to mark as errored.
   * @returns {Promise<BundleInfo>} The updated {@link BundleInfo} with status set to `error`.
   * @throws {Error} When the bundle does not exist or `allowManualBundleError` is false.
   * @since 7.20.0
   */
  setBundleError(options: BundleId): Promise<BundleInfo>;

  /**
   * Get all locally downloaded bundles stored in your app.
   *
   * This returns all bundles that have been downloaded and are available locally, including:
   * - The currently active bundle
   * - The `builtin` bundle (shipped with your app)
   * - Any downloaded bundles waiting to be activated
   * - Failed bundles (with `error` status)
   *
   * Use this to:
   * - Check available disk space by counting bundles
   * - Delete old bundles with {@link delete}
   * - Monitor bundle download status
   *
   * @param options The {@link ListOptions} for customizing the bundle list output.
   * @returns {Promise<BundleListResult>} A promise containing the array of {@link BundleInfo} objects.
   * @throws {Error} If the operation fails.
   */
  list(options?: ListOptions): Promise<BundleListResult>;

  /**
   * Reset the app to a known good bundle.
   *
   * This method helps recover from problematic updates by reverting to either:
   * - The `builtin` bundle (the original version shipped with your app to App Store/Play Store)
   * - The last successfully loaded bundle (most recent bundle that worked correctly)
   *
   * **IMPORTANT: This triggers an immediate app reload, destroying the current JavaScript context.**
   * See {@link set} for details on the implications of this operation.
   *
   * Use cases:
   * - Emergency recovery when an update causes critical issues
   * - Testing rollback functionality
   * - Providing users a "reset to factory" option
   *
   * @param options {@link ResetOptions} to control reset behavior.
   * If `toLastSuccessful` is `false` (or omitted), resets to builtin.
   * If `true`, resets to last successful bundle.
   * If `usePendingBundle` is `true`, applies the pending bundle set via {@link next} and clears it.
   * @returns {Promise<void>} A promise that may never resolve because the app will be reloaded.
   * @throws {Error} If the reset operation fails.
   */
  reset(options?: ResetOptions): Promise<void>;

  /**
   * Get information about the currently active bundle.
   *
   * Returns:
   * - `bundle`: The currently active bundle information
   * - `native`: The version of the builtin bundle (the original app version from App/Play Store)
   *
   * If no updates have been applied, `bundle.id` will be `"builtin"`, indicating the app
   * is running the original version shipped with the native app.
   *
   * Use this to:
   * - Display the current version to users
   * - Check if an update is currently active
   * - Compare against available updates
   * - Log the active bundle for debugging
   *
   * @returns {Promise<CurrentBundleResult>} A promise with the current bundle and native version info.
   * @throws {Error} If the operation fails.
   */
  current(): Promise<CurrentBundleResult>;

  /**
   * Manually reload the app to apply a pending update.
   *
   * This triggers the same reload behavior that happens automatically when the app backgrounds.
   * If you've called {@link next} to queue an update, calling `reload()` will apply it immediately.
   *
   * **IMPORTANT: This destroys the current JavaScript context immediately.**
   * See {@link set} for details on the implications of this operation.
   *
   * Common use cases:
   * - Applying an update immediately after download instead of waiting for backgrounding
   * - Providing a "Restart now" button to users after an update is ready
   * - Testing update flows during development
   *
   * If no update is pending (no call to {@link next}), this simply reloads the current bundle.
   *
   * @returns {Promise<void>} A promise that may never resolve because the app will be reloaded.
   * @throws {Error} If the reload operation fails.
   */
  reload(): Promise<void>;

  /**
   * Configure conditions that must be met before a pending update is applied.
   *
   * After calling {@link next} to queue an update, use this method to control when it gets applied.
   * The update will only be installed after ALL specified conditions are satisfied.
   *
   * Available condition types:
   * - `background`: Wait for the app to be backgrounded. Optionally specify duration in milliseconds.
   * - `kill`: Wait for the app to be killed and relaunched (**Note:** Current behavior triggers update immediately on kill, not on next background. This will be fixed in v8.)
   * - `date`: Wait until a specific date/time (ISO 8601 format)
   * - `nativeVersion`: Wait until the native app is updated to a specific version
   *
   * Condition value formats:
   * - `background`: Number in milliseconds (e.g., `"300000"` for 5 minutes), or omit for immediate
   * - `kill`: No value needed
   * - `date`: ISO 8601 date string (e.g., `"2025-12-31T23:59:59Z"`)
   * - `nativeVersion`: Version string (e.g., `"2.0.0"`)
   *
   * @example
   * // Update after user kills app OR after 5 minutes in background
   * await CapacitorUpdater.setMultiDelay({
   *   delayConditions: [
   *     { kind: 'kill' },
   *     { kind: 'background', value: '300000' }
   *   ]
   * });
   *
   * @example
   * // Update after a specific date
   * await CapacitorUpdater.setMultiDelay({
   *   delayConditions: [{ kind: 'date', value: '2025-12-31T23:59:59Z' }]
   * });
   *
   * @example
   * // Default behavior: update on next background
   * await CapacitorUpdater.setMultiDelay({
   *   delayConditions: [{ kind: 'background' }]
   * });
   *
   * @param options Contains the {@link MultiDelayConditions} array of conditions.
   * @returns {Promise<void>} Resolves when the delay conditions are set.
   * @throws {Error} If the operation fails or conditions are invalid.
   * @since 4.3.0
   */
  setMultiDelay(options: MultiDelayConditions): Promise<void>;

  /**
   * Cancel all delay conditions and apply the pending update immediately.
   *
   * If you've set delay conditions with {@link setMultiDelay}, this method clears them
   * and triggers the pending update to be applied on the next app background or restart.
   *
   * This is useful when:
   * - User manually requests to update now (e.g., clicks "Update now" button)
   * - Your app detects it's a good time to update (e.g., user finished critical task)
   * - You want to override a time-based delay early
   *
   * @returns {Promise<void>} Resolves when the delay conditions are cleared.
   * @throws {Error} If the operation fails.
   * @since 4.0.0
   */
  cancelDelay(): Promise<void>;

  /**
   * Trigger the native auto-update check/download pipeline immediately.
   *
   * This starts the same background update flow used when the app moves to the
   * foreground with auto-update enabled. It is useful for native integrations
   * such as a silent push notification asking the app to check for a Capgo
   * bundle without reimplementing the update protocol in JavaScript.
   *
   * The promise resolves after the native background work has been queued, not
   * after the update has been downloaded or installed. Listen to updater events
   * such as `updateAvailable`, `downloadComplete`, `downloadFailed`, and
   * `noNeedUpdate` for the final result.
   *
   * Native support is available on iOS and Android. On Web, this method returns
   * a result with `status: 'unavailable'`. Native platforms also return
   * `unavailable` when the native auto-update system is disabled.
   *
   * @returns {Promise<TriggerUpdateCheckResult>} Whether a native update check was queued.
   */
  triggerUpdateCheck(): Promise<TriggerUpdateCheckResult>;

  /**
   * Check the update server for the latest available bundle version.
   *
   * This queries your configured update URL (or Capgo backend) to see if a newer bundle
   * is available for download. It does NOT download the bundle automatically.
   *
   * The response includes:
   * - `version`: The latest available version identifier
   * - `url`: Download URL for the bundle (if available)
   * - `breaking`: Whether this update is marked as incompatible (requires native app update)
   * - `message`: Optional message from the server
   * - `manifest`: File list for delta updates (if using multi-file downloads)
   *
   * After receiving the latest version info, you can:
   * 1. Compare it with your current version
   * 2. Download it using {@link download}
   * 3. Apply it using {@link next} or {@link set}
   *
   * **Important: Handling "no new version available"**
   *
   * When the device's current version matches the latest version on the server (i.e., the device is already
   * up-to-date), the server returns a 200 response with `error: "no_new_version_available"` and
   * `message: "No new version available"`. This is a normal, expected condition and resolves with
   * `kind: "up_to_date"` when the backend provides that classification.
   *
   * You should check `kind` and `error` before attempting to download:
   *
   * ```typescript
   * const latest = await CapacitorUpdater.getLatest();
   * if (latest.kind === 'up_to_date') {
   *   console.log('Already up to date');
   * } else if (latest.kind === 'blocked') {
   *   console.log('Update is blocked:', latest.error);
   * } else if (latest.url) {
   *   // New version is available, proceed with download
   * }
   * ```
   *
   * In this scenario, the server:
   * - Logs the request with a "No new version available" message
   * - Sends a "noNew" stat action to track that the device checked for updates but was already current (done on the backend)
   *
   * @param options Optional {@link GetLatestOptions} to specify which channel to check.
   * @returns {Promise<LatestVersion>} Information about the latest available bundle version.
   * @throws {Error} Throws for failed update checks or transport/request failures.
   * @since 4.0.0
   */
  getLatest(options?: GetLatestOptions): Promise<LatestVersion>;

  /**
   * Return the manifest entries that still need to be downloaded for a partial update.
   *
   * Pass the result from {@link getLatest} directly when it includes a `manifest`.
   * The native plugin compares each manifest entry with the files already available
   * in the builtin bundle and the local delta cache. Entries that can be reused are
   * omitted from the returned `missing` list.
   *
   * For encrypted manifests, pass the `sessionKey` returned by {@link getLatest} so
   * encrypted file hashes can be checked against local files.
   *
   * ```typescript
   * const latest = await CapacitorUpdater.getLatest();
   * const missing = await CapacitorUpdater.getMissingBundleFiles(latest);
   * ```
   *
   * @param options A {@link GetMissingBundleFilesOptions} object, or a {@link LatestVersion} response containing `manifest`.
   * @returns {Promise<GetMissingBundleFilesResult>} The manifest entries that require network download.
   * @throws {Error} If the manifest is missing or invalid.
   * @since 8.47.0
   */
  getMissingBundleFiles(options: GetMissingBundleFilesOptions): Promise<GetMissingBundleFilesResult>;

  /**
   * Estimate the download size for manifest entries before downloading them.
   *
   * This method sends the provided manifest entries to the Capgo update endpoint
   * once and reads the stored manifest `file_size` metadata. It does not perform
   * per-file `HEAD` requests from the app.
   *
   * Use this after {@link getMissingBundleFiles} to estimate only the files this
   * device still needs:
   *
   * ```typescript
   * const latest = await CapacitorUpdater.getLatest();
   * const missing = await CapacitorUpdater.getMissingBundleFiles(latest);
   * const size = await CapacitorUpdater.getBundleDownloadSize({
   *   version: latest.version,
   *   manifest: missing.missing,
   * });
   * ```
   *
   * @param options A {@link GetBundleDownloadSizeOptions} object containing manifest entries.
   * @returns {Promise<GetBundleDownloadSizeResult>} Known byte totals and per-file size results.
   * @throws {Error} If the manifest is missing or invalid.
   * @since 8.47.0
   */
  getBundleDownloadSize(options: GetBundleDownloadSizeOptions): Promise<GetBundleDownloadSizeResult>;

  /**
   * Assign this device to a specific update channel at runtime.
   *
   * Channels allow you to distribute different bundle versions to different groups of users
   * (e.g., "production", "beta", "staging"). This method switches the device to a new channel.
   *
   * **Device Override UI:** `setChannel()` validates the channel with the backend, then stores the
   * selected channel locally on the device for future app restarts. It does not create or update
   * a backend Device Override, so the device will not appear as overridden in the Capgo dashboard.
   * Only assignments created from the dashboard or the Public API are shown in the Device Override UI.
   *
   * **Requirements:**
   * - The target channel must allow self-assignment (configured in your Capgo dashboard or backend)
   * - The backend may accept or reject the request based on channel settings
   *
   * **When to use:**
   * - After the app is ready and the user has interacted (e.g., opted into beta program)
   * - To implement in-app channel switching (beta toggle, tester access, etc.)
   * - For user-driven channel changes
   *
   * **When NOT to use:**
   * - At app boot/initialization - use {@link PluginsConfig.CapacitorUpdater.defaultChannel} config instead
   * - Before user interaction
   *
   * **Important: Listen for the `channelPrivate` event**
   *
   * When a user attempts to set a channel that doesn't allow device self-assignment, the method will
   * throw an error AND fire a {@link addListener}('channelPrivate') event. You should listen to this event
   * to provide appropriate feedback to users:
   *
   * ```typescript
   * CapacitorUpdater.addListener('channelPrivate', (data) => {
   *   console.warn(`Cannot access channel "${data.channel}": ${data.message}`);
   *   // Show user-friendly message
   * });
   * ```
   *
   * This sends a request to the Capgo backend to validate the specified channel, then stores the
   * channel locally on the device for future app restarts.
   *
   * @param options The {@link SetChannelOptions} containing the channel name and optional auto-update trigger.
   * @returns {Promise<ChannelRes>} Channel operation result with status and optional error/message.
   * @throws {Error} If the channel doesn't exist or doesn't allow self-assignment.
   * @since 4.7.0
   */
  setChannel(options: SetChannelOptions): Promise<ChannelRes>;

  /**
   * Remove the plugin-managed local channel assignment and return to the default channel.
   *
   * This clears only the channel stored locally by {@link setChannel}; it does not delete Dashboard or Public API Device Override records. After the local assignment is cleared, normal channel precedence applies:
   * - An existing Dashboard or Public API Device Override, if one exists
   * - The {@link PluginsConfig.CapacitorUpdater.defaultChannel} if configured, or
   * - Your backend default channel for this app
   *
   * Use this when:
   * - Users opt out of beta/testing programs
   * - You want to reset a device to standard update distribution
   * - Testing channel switching behavior
   *
   * @param options {@link UnsetChannelOptions} containing optional auto-update trigger.
   * @returns {Promise<void>} Resolves when the channel is successfully unset.
   * @throws {Error} If the operation fails.
   * @since 4.7.0
   */
  unsetChannel(options: UnsetChannelOptions): Promise<void>;

  /**
   * Get the current channel assigned to this device.
   *
   * Returns information about:
   * - `channel`: The currently assigned channel name (if any)
   * - `allowSet`: Whether the channel allows self-assignment
   * - `status`: Operation status
   * - `error`/`message`: Additional information (if applicable)
   *
   * Use this to:
   * - Display current channel to users (e.g., "You're on the Beta channel")
   * - Check if a device is on a specific channel before showing features
   * - Verify channel assignment after calling {@link setChannel}
   *
   * On native platforms, a successful response also refreshes the default channel used by update checks.
   * This refresh is persisted across app restarts.
   *
   * @returns {Promise<GetChannelRes>} The current channel information.
   * @throws {Error} If the operation fails.
   * @since 4.8.0
   */
  getChannel(): Promise<GetChannelRes>;

  /**
   * Get a list of all channels available for this device to self-assign to.
   *
   * Only returns channels where `allow_self_set` is `true`. These are channels that
   * users can switch to using {@link setChannel} without backend administrator intervention.
   *
   * Each channel includes:
   * - `id`: Unique channel identifier
   * - `name`: Human-readable channel name
   * - `public`: Whether the channel is publicly visible
   * - `allow_self_set`: Always `true` in results (filtered to only self-assignable channels)
   *
   * Use this to:
   * - Build a channel selector UI for users (e.g., "Join Beta" button)
   * - Show available testing/preview channels
   * - Implement channel discovery features
   *
   * @returns {Promise<ListChannelsResult>} List of channels the device can self-assign to.
   * @throws {Error} If the operation fails or the request to the backend fails.
   * @since 7.5.0
   */
  listChannels(): Promise<ListChannelsResult>;

  /**
   * Set a custom identifier for this device.
   *
   * This allows you to identify devices by your own custom ID (user ID, account ID, etc.)
   * instead of or in addition to the device's unique hardware ID. The custom ID is sent
   * to your update server and can be used for:
   * - Targeting specific users for updates
   * - Analytics and user tracking
   * - Debugging and support (correlating devices with users)
   * - A/B testing or feature flagging
   *
   * **Persistence:**
   * - When {@link PluginsConfig.CapacitorUpdater.persistCustomId} is `true`, the ID persists across app restarts
   * - When `false`, the ID is only kept for the current session
   *
   * **Clearing the custom ID:**
   * - Pass an empty string `""` to remove any stored custom ID
   *
   * @param options The {@link SetCustomIdOptions} containing the custom identifier string.
   * @returns {Promise<void>} Resolves immediately (synchronous operation).
   * @throws {Error} If the operation fails.
   * @since 4.9.0
   */
  setCustomId(options: SetCustomIdOptions): Promise<void>;

  /**
   * Get the builtin bundle version (the original version shipped with your native app).
   *
   * This returns the version of the bundle that was included when the app was installed
   * from the App Store or Play Store. This is NOT the currently active bundle version -
   * use {@link current} for that.
   *
   * Returns:
   * - The {@link PluginsConfig.CapacitorUpdater.version} config value if set, or
   * - The native app version from platform configs (package.json, Info.plist, build.gradle)
   *
   * Use this to:
   * - Display the "factory" version to users
   * - Compare against downloaded bundle versions
   * - Determine if any updates have been applied
   * - Debugging version mismatches
   *
   * @returns {Promise<BuiltinVersion>} The builtin bundle version string.
   * @since 5.2.0
   */
  getBuiltinVersion(): Promise<BuiltinVersion>;

  /**
   * Get the unique, privacy-friendly identifier for this device.
   *
   * This ID is used to identify the device when communicating with update servers.
   * It's automatically generated and stored securely by the plugin.
   *
   * **Privacy & Security characteristics:**
   * - Generated as a UUID (not based on hardware identifiers)
   * - Stored securely in platform-specific secure storage
   * - Android: mirrored into backup-restorable app preferences for reinstall restore
   * - iOS: Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
   * - Not synced to cloud (iOS)
   * - Follows Apple and Google privacy best practices
   * - Users can clear it via system settings (Android) or keychain access (iOS)
   *
   * **Persistence:**
   * The device ID persists across app reinstalls to maintain consistent device identity
   * for update tracking and analytics when platform storage is preserved. On Android,
   * apps with custom backup rules must keep the plugin app preferences eligible for
   * backup/restore; disabling Android backup or clearing app data creates a new ID.
   *
   * Use this to:
   * - Debug update delivery issues (check what ID the server sees)
   * - Implement device-specific features
   * - Correlate server logs with specific devices
   *
   * @returns {Promise<DeviceId>} The unique device identifier string.
   * @throws {Error} If the operation fails.
   */
  getDeviceId(): Promise<DeviceId>;

  /**
   * Get the version of the Capacitor Updater plugin installed in your app.
   *
   * This returns the version of the native plugin code (Android/iOS), which is sent
   * to the update server with each request. This is NOT your app version or bundle version.
   *
   * Use this to:
   * - Debug plugin-specific issues (when reporting bugs)
   * - Verify plugin installation and version
   * - Check compatibility with backend features
   * - Display in debug/about screens
   *
   * @returns {Promise<PluginVersion>} The Capacitor Updater plugin version string.
   * @throws {Error} If the operation fails.
   */
  getPluginVersion(): Promise<PluginVersion>;

  /**
   * Check if automatic updates are currently enabled.
   *
   * Returns `true` if {@link PluginsConfig.CapacitorUpdater.autoUpdate} is enabled,
   * meaning the plugin will automatically check for, download, and apply updates.
   *
   * Returns `false` if in manual mode, where you control the update flow using
   * {@link getLatest}, {@link download}, {@link next}, and {@link set}.
   *
   * Use this to:
   * - Determine which update flow your app is using
   * - Show/hide manual update UI based on mode
   * - Debug update behavior
   *
   * @returns {Promise<AutoUpdateEnabled>} `true` if auto-update is enabled, `false` if in manual mode.
   * @throws {Error} If the operation fails.
   */
  isAutoUpdateEnabled(): Promise<AutoUpdateEnabled>;

  /**
   * Remove all event listeners registered for this plugin.
   *
   * This unregisters all listeners added via {@link addListener} for all event types:
   * - `download`
   * - `noNeedUpdate`
   * - `updateCheckResult`
   * - `updateAvailable`
   * - `downloadComplete`
   * - `downloadFailed`
   * - `breakingAvailable` / `majorAvailable`
   * - `updateFailed`
   * - `appReloaded`
   * - `appReady`
   *
   * Use this during cleanup (e.g., when unmounting components or closing screens)
   * to prevent memory leaks from lingering event listeners.
   *
   * @returns {Promise<void>} Resolves when all listeners are removed.
   * @since 1.0.0
   */
  removeAllListeners(): Promise<void>;

  /**
   * Listen for bundle download event in the App. Fires once a download has started, during downloading and when finished.
   * This will return you all download percent during the download
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
   * Listen for update check results before the updater decides whether to download.
   * The backend can classify the UpdateCheckResultEvent payload as `up_to_date`, `blocked`, or `failed`.
   *
   * This event is emitted alongside legacy events. For `up_to_date` and `blocked`, it is emitted before
   * `noNeedUpdate` and does not emit `downloadFailed`. For `failed`, it is emitted before the legacy
   * `downloadFailed` event and keeps the existing failure stats behavior.
   *
   * @since 8.45.11
   */
  addListener(
    eventName: 'updateCheckResult',
    listenerFunc: (state: UpdateCheckResultEvent) => void,
  ): Promise<PluginListenerHandle>;

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
   * Listen for breaking update events when the backend flags an update as incompatible with the current app.
   * Emits the same payload as the legacy `majorAvailable` listener.
   *
   * @since 7.22.0
   */
  addListener(
    eventName: 'breakingAvailable',
    listenerFunc: (state: BreakingAvailableEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for Major update event in the App, let you know when major update is blocked by setting disableAutoUpdateBreaking
   *
   * @deprecated Deprecated alias for {@link addListener} with `breakingAvailable`. Emits the same payload. will be removed in v8
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
   * Listen for set event in the App, let you know when a bundle has been applied successfully.
   * This event is retained natively until JavaScript consumes it, so if the app reloads before your
   * listener is attached, the last pending `set` event is delivered once the listener subscribes.
   *
   * @since 8.43.12
   */
  addListener(eventName: 'set', listenerFunc: (state: SetEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Listen for set next event in the App, let you know when a bundle is queued as the next bundle to install.
   *
   * @since 6.14.0
   */
  addListener(eventName: 'setNext', listenerFunc: (state: SetNextEvent) => void): Promise<PluginListenerHandle>;

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
   * Listen for app ready event in the App, let you know when app is ready to use.
   * This event is retained natively until JavaScript consumes it, so it can still be delivered after
   * a reload even if the listener is attached later in app startup.
   *
   * @since 5.1.0
   */
  addListener(eventName: 'appReady', listenerFunc: (state: AppReadyEvent) => void): Promise<PluginListenerHandle>;

  /**
   * Listen for channel private event, fired when attempting to set a channel that doesn't allow device self-assignment.
   *
   * This event is useful for:
   * - Informing users they don't have permission to switch to a specific channel
   * - Implementing custom error handling for channel restrictions
   * - Logging unauthorized channel access attempts
   *
   * @since 7.34.0
   */
  addListener(
    eventName: 'channelPrivate',
    listenerFunc: (state: ChannelPrivateEvent) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Listen for flexible update state changes on Android.
   *
   * This event fires during the flexible update download process, providing:
   * - Download progress (bytes downloaded / total bytes)
   * - Installation status changes
   *
   * **Install status values:**
   * - `UNKNOWN` (0): Unknown status
   * - `PENDING` (1): Download pending
   * - `DOWNLOADING` (2): Download in progress
   * - `INSTALLING` (3): Installing the update
   * - `INSTALLED` (4): Update installed (app restart needed)
   * - `FAILED` (5): Update failed
   * - `CANCELED` (6): Update was canceled
   * - `DOWNLOADED` (11): Download complete, ready to install
   *
   * When status is `DOWNLOADED`, you should prompt the user and call
   * {@link completeFlexibleUpdate} to finish the installation.
   *
   * @since 8.0.0
   */
  addListener(
    eventName: 'onFlexibleUpdateStateChange',
    listenerFunc: (state: FlexibleUpdateState) => void,
  ): Promise<PluginListenerHandle>;

  /**
   * Check if the auto-update feature is available (not disabled by custom server configuration).
   *
   * Returns `false` when a custom `updateUrl` is configured, as this typically indicates
   * you're using a self-hosted update server that may not support all auto-update features.
   *
   * Returns `true` when using the default Capgo backend or when the feature is available.
   *
   * This is different from {@link isAutoUpdateEnabled}:
   * - `isAutoUpdateEnabled()`: Checks if auto-update MODE is turned on/off
   * - `isAutoUpdateAvailable()`: Checks if auto-update is SUPPORTED with your current configuration
   *
   * @returns {Promise<AutoUpdateAvailable>} `false` when custom updateUrl is set, `true` otherwise.
   * @throws {Error} If the operation fails.
   */
  isAutoUpdateAvailable(): Promise<AutoUpdateAvailable>;

  /**
   * Get information about the bundle queued to be activated on next reload.
   *
   * Returns:
   * - {@link BundleInfo} object if a bundle has been queued via {@link next}
   * - `null` if no update is pending
   *
   * This is useful to:
   * - Check if an update is waiting to be applied
   * - Display "Update pending" status to users
   * - Show version info of the queued update
   * - Decide whether to show a "Restart to update" prompt
   *
   * The queued bundle will be activated when:
   * - The app is backgrounded (default behavior)
   * - The app is killed and restarted
   * - {@link reload} is called manually
   * - Delay conditions set by {@link setMultiDelay} are met
   *
   * @returns {Promise<BundleInfo | null>} The pending bundle info, or `null` if none is queued.
   * @throws {Error} If the operation fails.
   * @since 6.8.0
   */
  getNextBundle(): Promise<BundleInfo | null>;

  /**
   * Retrieve information about the most recent bundle that failed to load.
   *
   * When a bundle fails to load (e.g., JavaScript errors prevent initialization, missing files),
   * the plugin automatically rolls back and stores information about the failure. This method
   * retrieves that failure information.
   *
   * **IMPORTANT: The stored value is cleared after being retrieved once.**
   * Calling this method multiple times will only return the failure info on the first call,
   * then `null` on subsequent calls until another failure occurs.
   *
   * Returns:
   * - {@link UpdateFailedEvent} with bundle info if a failure was recorded
   * - `null` if no failure has occurred or if it was already retrieved
   *
   * Use this to:
   * - Show users why an update failed
   * - Log failure information for debugging
   * - Implement custom error handling/reporting
   * - Display rollback notifications
   *
   * @returns {Promise<UpdateFailedEvent | null>} The failed update info (cleared after first retrieval), or `null`.
   * @throws {Error} If the operation fails.
   * @since 7.22.0
   */
  getFailedUpdate(): Promise<UpdateFailedEvent | null>;

  /**
   * Enable or disable the native preview menu gesture.
   *
   * During preview sessions, users can use the configured native gesture to:
   * - Reload the current preview
   * - Leave the test app and return to the fallback bundle
   * - Switch update channel, when {@link PluginsConfig.CapacitorUpdater.allowShakeChannelSelector} is also enabled
   *
   * Outside preview sessions, this preview menu is ignored. The channel selector can still be
   * shown outside preview sessions when {@link PluginsConfig.CapacitorUpdater.allowShakeChannelSelector} is enabled.
   *
   * **Important:** Disable this in production builds or only enable for internal testers.
   *
   * This can also be configured via {@link PluginsConfig.CapacitorUpdater.shakeMenu}.
   * The native gesture is configured via {@link PluginsConfig.CapacitorUpdater.shakeMenuGesture}.
   *
   * @param options {@link SetShakeMenuOptions} with `enabled: true` to enable or `enabled: false` to disable.
   * @returns {Promise<void>} Resolves when the setting is applied.
   * @throws {Error} If the operation fails.
   * @since 7.5.0
   */
  setShakeMenu(options: SetShakeMenuOptions): Promise<void>;

  /**
   * Check if the native preview menu gesture is currently enabled.
   *
   * Returns the current state of the shake menu feature that can be toggled via
   * {@link setShakeMenu} or configured via {@link PluginsConfig.CapacitorUpdater.shakeMenu}.
   *
   * Use this to:
   * - Check if debug features are enabled
   * - Show/hide debug settings UI
   * - Verify configuration during testing
   *
   * @returns {Promise<ShakeMenuEnabled>} Object with the current enabled state and gesture.
   * @throws {Error} If the operation fails.
   * @since 7.5.0
   */
  isShakeMenuEnabled(): Promise<ShakeMenuEnabled>;

  /**
   * Enable or disable the channel selector menu gesture at runtime.
   *
   * When enabled, the configured native gesture can show a channel selector, including outside preview sessions.
   * If {@link setShakeMenu} is also enabled while a preview session is active, the shake menu includes
   * both preview actions and channel switching.
   *
   * This can also be configured via {@link PluginsConfig.CapacitorUpdater.allowShakeChannelSelector}.
   * The native gesture is configured via {@link PluginsConfig.CapacitorUpdater.shakeMenuGesture}.
   *
   * @param options {@link SetShakeChannelSelectorOptions} with `enabled: true` to enable or `enabled: false` to disable.
   * @returns {Promise<void>} Resolves when the setting is applied.
   * @throws {Error} If the operation fails.
   * @since 8.43.0
   */
  setShakeChannelSelector(options: SetShakeChannelSelectorOptions): Promise<void>;

  /**
   * Check if the shake channel selector is currently enabled.
   *
   * Returns the current state of the shake channel selector feature that can be toggled via
   * {@link setShakeChannelSelector} or configured via {@link PluginsConfig.CapacitorUpdater.allowShakeChannelSelector}.
   *
   * @returns {Promise<ShakeChannelSelectorEnabled>} Object with `enabled: true` or `enabled: false`.
   * @throws {Error} If the operation fails.
   * @since 8.43.0
   */
  isShakeChannelSelectorEnabled(): Promise<ShakeChannelSelectorEnabled>;

  /**
   * Get the currently configured App ID used for update server communication.
   *
   * Returns the App ID that identifies this app to the update server. This can be:
   * - The value set via {@link setAppId}, or
   * - The {@link PluginsConfig.CapacitorUpdater.appId} config value, or
   * - The default app identifier from your native app configuration
   *
   * Use this to:
   * - Verify which App ID is being used for updates
   * - Debug update delivery issues
   * - Display app configuration in debug screens
   * - Confirm App ID after calling {@link setAppId}
   *
   * @returns {Promise<GetAppIdRes>} Object containing the current `appId` string.
   * @throws {Error} If the operation fails.
   * @since 7.14.0
   */
  getAppId(): Promise<GetAppIdRes>;

  /**
   * Dynamically change the App ID used for update server communication.
   *
   * This overrides the App ID used to identify your app to the update server, allowing you
   * to switch between different app configurations at runtime (e.g., production vs staging
   * app IDs, or multi-tenant configurations).
   *
   * **Requirements:**
   * - {@link PluginsConfig.CapacitorUpdater.allowModifyAppId} must be set to `true`
   *
   * **Important considerations:**
   * - Changing the App ID will affect which updates this device receives
   * - The new App ID must exist on your update server
   * - This is primarily for advanced use cases (multi-tenancy, environment switching)
   * - Most apps should use the config-based {@link PluginsConfig.CapacitorUpdater.appId} instead
   *
   * @param options {@link SetAppIdOptions} containing the new App ID string.
   * @returns {Promise<void>} Resolves when the App ID is successfully changed.
   * @throws {Error} If `allowModifyAppId` is false or the operation fails.
   * @since 7.14.0
   */
  setAppId(options: SetAppIdOptions): Promise<void>;

  // ============================================================================
  // App Store / Play Store Update Methods
  // ============================================================================

  /**
   * Get information about the app's availability in the App Store or Play Store.
   *
   * This method checks the native app stores to see if a newer version of the app
   * is available for download. This is different from Capgo's OTA updates - this
   * checks for native app updates that require going through the app stores.
   *
   * **Platform differences:**
   * - **Android**: Uses Play Store's In-App Updates API for accurate update information
   * - **iOS**: Queries the App Store lookup API (requires country code for accurate results)
   *
   * **Returns information about:**
   * - Current installed version
   * - Available version in the store (if any)
   * - Whether an update is available
   * - Update priority (Android only)
   * - Whether immediate/flexible updates are allowed (Android only)
   *
   * Use this to:
   * - Check if users need to update from the app store
   * - Show "Update Available" prompts for native updates
   * - Implement version gating (require minimum native version)
   * - Combine with Capgo OTA updates for a complete update strategy
   *
   * @param options Optional {@link GetAppUpdateInfoOptions} with country code for iOS.
   * @returns {Promise<AppUpdateInfo>} Information about the current and available app versions.
   * @throws {Error} If the operation fails or store information is unavailable.
   * @since 8.0.0
   */
  getAppUpdateInfo(options?: GetAppUpdateInfoOptions): Promise<AppUpdateInfo>;

  /**
   * Open the app's page in the App Store or Play Store.
   *
   * This navigates the user to your app's store listing where they can manually
   * update the app. Use this as a fallback when in-app updates are not available
   * or when the user needs to update on iOS.
   *
   * **Platform behavior:**
   * - **Android**: Opens Play Store to the app's page
   * - **iOS**: Opens App Store to the app's page
   *
   * **Customization options:**
   * - `appId`: Specify a custom App Store ID (iOS) - useful for opening a different app's page
   * - `packageName`: Specify a custom package name (Android) - useful for opening a different app's page
   *
   * @param options Optional {@link OpenAppStoreOptions} to customize which app's store page to open.
   * @returns {Promise<void>} Resolves when the store is opened.
   * @throws {Error} If the store cannot be opened.
   * @since 8.0.0
   */
  openAppStore(options?: OpenAppStoreOptions): Promise<void>;

  /**
   * Perform an immediate in-app update on Android.
   *
   * This triggers Google Play's immediate update flow, which:
   * 1. Shows a full-screen update UI
   * 2. Downloads and installs the update
   * 3. Restarts the app automatically
   *
   * The user cannot continue using the app until the update is complete.
   * This is ideal for critical updates that must be installed immediately.
   *
   * **Requirements:**
   * - Android only (throws error on iOS)
   * - An update must be available (check with {@link getAppUpdateInfo} first)
   * - The update must allow immediate updates (`immediateUpdateAllowed: true`)
   *
   * **User experience:**
   * - Full-screen blocking UI
   * - Progress shown during download
   * - App automatically restarts after installation
   *
   * @returns {Promise<AppUpdateResult>} Result indicating success, cancellation, or failure.
   * @throws {Error} If not on Android, no update is available, or immediate updates not allowed.
   * @since 8.0.0
   */
  performImmediateUpdate(): Promise<AppUpdateResult>;

  /**
   * Start a flexible in-app update on Android.
   *
   * This triggers Google Play's flexible update flow, which:
   * 1. Downloads the update in the background
   * 2. Allows the user to continue using the app
   * 3. Notifies when download is complete
   * 4. Requires calling {@link completeFlexibleUpdate} to install
   *
   * Monitor the download progress using the `onFlexibleUpdateStateChange` listener.
   *
   * **Requirements:**
   * - Android only (throws error on iOS)
   * - An update must be available (check with {@link getAppUpdateInfo} first)
   * - The update must allow flexible updates (`flexibleUpdateAllowed: true`)
   *
   * **Typical flow:**
   * 1. Call `startFlexibleUpdate()` to begin download
   * 2. Listen to `onFlexibleUpdateStateChange` for progress
   * 3. When status is `DOWNLOADED`, prompt user to restart
   * 4. Call `completeFlexibleUpdate()` to install and restart
   *
   * @returns {Promise<AppUpdateResult>} Result indicating the update was started, cancelled, or failed.
   * @throws {Error} If not on Android, no update is available, or flexible updates not allowed.
   * @since 8.0.0
   */
  startFlexibleUpdate(): Promise<AppUpdateResult>;

  /**
   * Complete a flexible in-app update on Android.
   *
   * After a flexible update has been downloaded (status `DOWNLOADED` in
   * `onFlexibleUpdateStateChange`), call this method to install the update
   * and restart the app.
   *
   * **Important:** This will immediately restart the app. Make sure to:
   * - Save any user data before calling
   * - Prompt the user before restarting
   * - Only call when the download status is `DOWNLOADED`
   *
   * @returns {Promise<void>} Resolves when the update installation begins (app will restart).
   * @throws {Error} If not on Android or no downloaded update is pending.
   * @since 8.0.0
   */
  completeFlexibleUpdate(): Promise<void>;
}

/**
 * pending: The bundle is pending to be **SET** as the next bundle.
 * downloading: The bundle is being downloaded.
 * success: The bundle has been downloaded and is ready to be **SET** as the next bundle.
 * error: The bundle has failed to download.
 */
export type BundleStatus = 'success' | 'error' | 'pending' | 'downloading';

export type DelayUntilNext = 'background' | 'kill' | 'nativeVersion' | 'date';

/**
 * Classification for update-check responses that do not provide a downloadable bundle.
 * The update backend provides this field directly. Missing or unknown values are treated as
 * failed by native clients.
 *
 * @since 8.45.11
 */
export type UpdateResponseKind = 'up_to_date' | 'blocked' | 'failed';

export interface NoNeedEvent {
  /**
   * Current status of download, between 0 and 100.
   *
   * @since  4.0.0
   */
  bundle: BundleInfo;
}

export interface UpdateCheckResultEvent {
  /**
   * Classification for the update check result, provided by the backend.
   *
   * @since 8.45.11
   */
  kind: UpdateResponseKind;
  /**
   * Backend error code, when provided.
   *
   * @since 8.45.11
   */
  error?: string;
  /**
   * Backend message, when provided.
   *
   * @since 8.45.11
   */
  message?: string;
  /**
   * HTTP status code returned by the update endpoint.
   *
   * @since 8.45.11
   */
  statusCode?: number;
  /**
   * Version referenced by the update check result.
   *
   * @since 8.45.11
   */
  version?: string;
  /**
   * Current bundle on the device.
   *
   * @since 8.45.11
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

export interface ChannelInfo {
  /**
   * The channel ID
   *
   * @since 7.5.0
   */
  id: number;
  /**
   * The channel name
   *
   * @since 7.5.0
   */
  name: string;
  /**
   * Whether this is a public channel
   *
   * @since 7.5.0
   */
  public: boolean;
  /**
   * Whether devices can self-assign to this channel
   *
   * @since 7.5.0
   */
  allow_self_set: boolean;
}

export interface ListChannelsResult {
  /**
   * List of available channels
   *
   * @since 7.5.0
   */
  channels: ChannelInfo[];
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
   * Emit when a breaking update is available.
   *
   * @deprecated Deprecated alias for {@link BreakingAvailableEvent}. Receives the same payload.
   * @since  4.0.0
   */
  version: string;
}

/**
 * Payload emitted by {@link CapacitorUpdaterPlugin.addListener} with `breakingAvailable`.
 *
 * @since 7.22.0
 */
export type BreakingAvailableEvent = MajorAvailableEvent;

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

export interface SetEvent {
  /**
   * Emit when a bundle has been applied successfully.
   * This event uses native `retainUntilConsumed` behavior.
   *
   * @since 8.43.12
   */
  bundle: BundleInfo;
}

export interface SetNextEvent {
  /**
   * Emit when a bundle is queued as the next bundle to install.
   *
   * @since 6.14.0
   */
  bundle: BundleInfo;
}

export interface AppReadyEvent {
  /**
   * Emitted when the app is ready to use.
   * This event uses native `retainUntilConsumed` behavior.
   *
   * @since  5.2.0
   */
  bundle: BundleInfo;
  status: string;
}

export interface ChannelPrivateEvent {
  /**
   * Emitted when attempting to set a channel that doesn't allow device self-assignment.
   *
   * @since 7.34.0
   */
  channel: string;
  message: string;
}

export interface ManifestEntry {
  file_name: string | null;
  file_hash: string | null;
  download_url: string | null;
}

export interface GetMissingBundleFilesOptions {
  /**
   * Manifest returned by {@link getLatest}. Passing the full {@link LatestVersion}
   * response is supported because it contains this field.
   *
   * @since 8.47.0
   */
  manifest?: ManifestEntry[];
  /**
   * Target bundle version. Passing the full {@link LatestVersion} response is
   * supported because it contains this field.
   *
   * @since 8.47.0
   */
  version?: string;
  /**
   * Session key returned by {@link getLatest}, required only when file hashes are encrypted.
   *
   * @since 8.47.0
   */
  sessionKey?: string;
}

export interface GetMissingBundleFilesResult {
  /**
   * Entries that are not available locally and need to be downloaded.
   *
   * @since 8.47.0
   */
  missing: ManifestEntry[];
  /**
   * Total entries in the provided manifest.
   *
   * @since 8.47.0
   */
  total: number;
  /**
   * Number of entries that need to be downloaded.
   *
   * @since 8.47.0
   */
  missingCount: number;
  /**
   * Number of entries that can be reused from builtin files or local cache.
   *
   * @since 8.47.0
   */
  reusableCount: number;
}

export interface GetBundleDownloadSizeOptions {
  /**
   * Manifest entries to estimate. Pass `missing.missing` from {@link getMissingBundleFiles}
   * to estimate only the bytes this device still needs to download.
   *
   * @since 8.47.0
   */
  manifest?: ManifestEntry[];
  /**
   * Target bundle version. Pass `latest.version` when estimating files returned
   * by {@link getLatest}.
   *
   * @since 8.47.0
   */
  version?: string;
}

export interface BundleFileSize {
  /**
   * File name from the manifest entry.
   *
   * @since 8.47.0
   */
  file_name: string | null;
  /**
   * File hash from the manifest entry.
   *
   * @since 8.47.0
   */
  file_hash: string | null;
  /**
   * Download URL from the manifest entry.
   *
   * @since 8.47.0
   */
  download_url: string | null;
  /**
   * Estimated bytes to download when the server exposes a size.
   *
   * @since 8.47.0
   */
  size?: number;
  /**
   * Error for this entry when the size could not be determined.
   *
   * @since 8.47.0
   */
  error?: string;
}

export interface GetBundleDownloadSizeResult {
  /**
   * Sum of all known file sizes in bytes.
   *
   * @since 8.47.0
   */
  totalSize: number;
  /**
   * Number of files with a known size.
   *
   * @since 8.47.0
   */
  knownFiles: number;
  /**
   * Number of files whose size could not be determined.
   *
   * @since 8.47.0
   */
  unknownFiles: number;
  /**
   * Per-file size results.
   *
   * @since 8.47.0
   */
  files: BundleFileSize[];
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
  /**
   * Indicates whether the update was flagged as breaking by the backend.
   *
   * @since 7.22.0
   */
  breaking?: boolean;
  /**
   * @deprecated Use {@link LatestVersion.breaking} instead.
   */
  major?: boolean;
  /**
   * Optional message from the server.
   * When no new version is available, this will be "No new version available".
   */
  message?: string;
  sessionKey?: string;
  /**
   * Error code from the server, if any. Use `kind` for classification instead of parsing this value.
   */
  error?: string;
  /**
   * Classification for this response, provided by the backend.
   *
   * @since 8.45.11
   */
  kind?: UpdateResponseKind;
  /**
   * HTTP status code returned by the update server for classified update-check responses.
   *
   * @since 8.45.11
   */
  statusCode?: number;
  /**
   * The previous/current version name (provided for reference).
   */
  old?: string;
  /**
   * Download URL for the bundle (when a new version is available).
   */
  url?: string;
  /**
   * File list for delta updates (when using multi-file downloads).
   * @since 6.1
   */
  manifest?: ManifestEntry[];
  /**
   * Missing manifest entries for this device when {@link GetLatestOptions.includeBundleSize}
   * is enabled.
   *
   * @since 8.47.0
   */
  missing?: GetMissingBundleFilesResult;
  /**
   * Estimated download size for missing manifest entries when
   * {@link GetLatestOptions.includeBundleSize} is enabled.
   *
   * @since 8.47.0
   */
  downloadSize?: GetBundleDownloadSizeResult;
  /**
   * Optional link associated with this bundle version (e.g., release notes URL, changelog, GitHub release).
   * @since 7.35.0
   */
  link?: string;
  /**
   * Optional comment or description for this bundle version.
   * @since 7.35.0
   */
  comment?: string;
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
  /**
   * Custom identifier to associate with the device. Use an empty string to clear any saved value.
   */
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
  /**
   * Temporarily use another app id for this update check while using a trusted preview container.
   * This only changes the app id sent by this request; it does not persist a preview session.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowPreview} to be `true`.
   * @since 8.47.0
   * @default undefined
   */
  appId?: string;
  /**
   * When true, the native plugin computes which manifest files are missing on
   * this device and asks the Capgo update endpoint for their stored sizes before
   * resolving {@link getLatest}.
   *
   * This adds one backend request only when the update response contains a
   * manifest. It does not perform per-file network checks.
   *
   * @since 8.47.0
   * @default false
   */
  includeBundleSize?: boolean;
}

export interface StartPreviewSessionOptions {
  /**
   * App id to use while the preview session is active.
   * The previous app id is restored when leaving the preview session.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowPreview} to be `true`.
   * @since 8.47.0
   * @default undefined
   */
  appId?: string;
  /**
   * HTTP(S) URL returning a preview download payload.
   * When provided, the native shake reload action fetches this payload again
   * before reloading so channel previews can move to the latest bundle.
   * Requires {@link PluginsConfig.CapacitorUpdater.allowPreview} to be `true`.
   * @since 8.48.0
   * @default undefined
   */
  payloadUrl?: string;
  /**
   * Human-readable preview name stored with the next preview bundle applied by
   * {@link set}. Native preview menus and {@link listPreviews} can display it.
   * @since 8.49.0
   * @default undefined
   */
  name?: string;
  /**
   * Optional source label for the preview, such as `channel`, `bundle`, `url`,
   * or `payload`. This is stored as metadata only.
   * @since 8.49.0
   * @default undefined
   */
  source?: string;
}

export interface PreviewInfo {
  /**
   * Preview bundle id.
   *
   * @since 8.49.0
   */
  id: string;
  /**
   * Locally downloaded bundle backing this preview.
   *
   * @since 8.49.0
   */
  bundle: BundleInfo;
  /**
   * Human-readable name supplied when the preview was started.
   *
   * @since 8.49.0
   */
  name?: string;
  /**
   * Metadata source label supplied when the preview was started.
   *
   * @since 8.49.0
   */
  source?: string;
  /**
   * Preview app id, when the session uses an app id override.
   *
   * @since 8.49.0
   */
  appId?: string;
  /**
   * Payload URL used to refresh this preview.
   *
   * @since 8.49.0
   */
  payloadUrl?: string;
  /**
   * ISO timestamp for when this preview was first saved.
   *
   * @since 8.49.0
   */
  createdAt: string;
  /**
   * ISO timestamp for the last metadata or bundle update.
   *
   * @since 8.49.0
   */
  updatedAt: string;
  /**
   * ISO timestamp for the last time this preview was activated.
   *
   * @since 8.49.0
   */
  lastUsedAt: string;
  /**
   * Whether this preview is the currently active bundle in a preview session.
   *
   * @since 8.49.0
   */
  isActive: boolean;
}

export interface PreviewListResult {
  /**
   * Locally available preview bundles.
   *
   * @since 8.49.0
   */
  previews: PreviewInfo[];
  /**
   * Current preview when a preview session is active.
   *
   * @since 8.49.0
   */
  current?: PreviewInfo;
  /**
   * Bundle currently loaded by the WebView.
   *
   * @since 8.49.0
   */
  currentBundle: BundleInfo;
  /**
   * Bundle that will be restored when leaving preview mode.
   *
   * @since 8.49.0
   */
  liveBundle?: BundleInfo;
}

export interface DeletePreviewResult {
  /**
   * Whether preview metadata was removed.
   *
   * @since 8.49.0
   */
  removed: boolean;
  /**
   * Whether the underlying local bundle was deleted.
   *
   * @since 8.49.0
   */
  deleted: boolean;
}

export interface PreviewUpdateResult {
  /**
   * Saved preview metadata after the check or update.
   *
   * @since 8.49.0
   */
  preview: PreviewInfo;
  /**
   * Latest version returned by the preview payload endpoint.
   *
   * @since 8.49.0
   */
  latestVersion?: string;
  /**
   * Whether the saved preview already matches the latest payload version.
   *
   * @since 8.49.0
   */
  upToDate: boolean;
  /**
   * Whether a newer bundle was downloaded and saved.
   *
   * @since 8.49.0
   */
  updated: boolean;
  /**
   * New bundle when {@link updatePreview} downloaded one.
   *
   * @since 8.49.0
   */
  bundle?: BundleInfo;
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

/**
 * This URL and versions are used to download the bundle from the server, If you use backend all information will be given by the method getLatest.
 * If you don't use backend, you need to provide the URL and version of the bundle. Checksum and sessionKey are required if you encrypted the bundle with the CLI command encrypt, you should receive them as result of the command.
 */
export interface DownloadOptions {
  /**
   * The URL of the bundle zip file (e.g: dist.zip) to be downloaded. (This can be any URL. E.g: Amazon S3, a GitHub tag, any other place you've hosted your bundle.)
   */
  url: string;
  /**
   * The version code/name of this bundle/version
   */
  version: string;
  /**
   * The session key for the update, when the bundle is encrypted with a session key
   * @since 4.0.0
   * @default undefined
   */
  sessionKey?: string;
  /**
   * The checksum for the update, it should be in sha256 and encrypted with private key if the bundle is encrypted
   * @since 4.0.0
   * @default undefined
   */
  checksum?: string;
  /**
   * The manifest for multi-file downloads
   * @since 6.1.0
   * @default undefined
   */
  manifest?: ManifestEntry[];
}

export interface BundleId {
  id: string;
}

export interface BundleListResult {
  bundles: BundleInfo[];
}

export interface ResetOptions {
  /**
   * Reset to the last successfully loaded bundle instead of the builtin one.
   * @default false
   */
  toLastSuccessful?: boolean;
  /**
   * Apply the pending bundle set via {@link next} while resetting.
   *
   * When `true`, the plugin will switch to the pending bundle immediately and clear the pending flag.
   * If no pending bundle exists, the reset will fail.
   * @default false
   */
  usePendingBundle?: boolean;
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

/**
 * Result returned after requesting an immediate native auto-update check.
 *
 * @property status - Native trigger state: `queued` when a check was queued,
 * `already_running` when the native update pipeline is already active, or
 * `unavailable` on Web or when native auto-update is disabled.
 * @property queued - Whether a new native update check was queued. This is
 * `true` only when `status` is `queued`; otherwise it is `false`.
 */
export interface TriggerUpdateCheckResult {
  /**
   * Native trigger state: `queued` when a check was queued, `already_running`
   * when the native update pipeline is already active, or `unavailable` on Web
   * or when native auto-update is disabled.
   */
  status: 'queued' | 'already_running' | 'unavailable';
  /**
   * Whether a new native update check was queued. This is `true` only when
   * `status` is `queued`; otherwise it is `false`.
   */
  queued: boolean;
}

/**
 * Native gesture options that open the shake menu.
 *
 * Supported values are `shake` and `threeFingerPinch`.
 *
 * @public
 */
export type ShakeMenuGesture = 'shake' | 'threeFingerPinch';

export interface SetShakeMenuOptions {
  enabled: boolean;
}

export interface ShakeMenuEnabled {
  enabled: boolean;
  /**
   * The currently configured native gesture used to open the preview/channel menu.
   * Undefined means consumers should treat the gesture as the default `shake` behavior.
   *
   * @since 8.48.0
   */
  gesture?: ShakeMenuGesture;
}

export interface SetShakeChannelSelectorOptions {
  enabled: boolean;
}

export interface ShakeChannelSelectorEnabled {
  enabled: boolean;
}

export interface GetAppIdRes {
  appId: string;
}

export interface SetAppIdOptions {
  appId: string;
}

// ============================================================================
// App Store / Play Store Update Types
// ============================================================================

/**
 * Options for {@link CapacitorUpdaterPlugin.getAppUpdateInfo}.
 *
 * @since 8.0.0
 */
export interface GetAppUpdateInfoOptions {
  /**
   * Two-letter country code (ISO 3166-1 alpha-2) for the App Store lookup.
   *
   * This is required on iOS to get accurate App Store information, as app
   * availability and versions can vary by country.
   *
   * Examples: "US", "GB", "DE", "JP", "FR"
   *
   * On Android, this option is ignored as the Play Store handles region
   * detection automatically.
   *
   * @since 8.0.0
   */
  country?: string;
}

/**
 * Information about app updates available in the App Store or Play Store.
 *
 * @since 8.0.0
 */
export interface AppUpdateInfo {
  /**
   * The currently installed version name (e.g., "1.2.3").
   *
   * @since 8.0.0
   */
  currentVersionName: string;

  /**
   * The version name available in the store, if an update is available.
   * May be undefined if no update information is available.
   *
   * @since 8.0.0
   */
  availableVersionName?: string;

  /**
   * The currently installed version code (Android) or build number (iOS).
   *
   * @since 8.0.0
   */
  currentVersionCode: string;

  /**
   * The version code available in the store (Android only).
   * On iOS, this will be the same as `availableVersionName`.
   *
   * @since 8.0.0
   */
  availableVersionCode?: string;

  /**
   * The release date of the available version (iOS only).
   * Format: ISO 8601 date string.
   *
   * @since 8.0.0
   */
  availableVersionReleaseDate?: string;

  /**
   * The current update availability status.
   *
   * @since 8.0.0
   */
  updateAvailability: AppUpdateAvailability;

  /**
   * The priority of the update as set by the developer in Play Console (Android only).
   * Values range from 0 (default/lowest) to 5 (highest priority).
   *
   * Use this to decide whether to show an update prompt or force an update.
   *
   * @since 8.0.0
   */
  updatePriority?: number;

  /**
   * Whether an immediate update is allowed (Android only).
   *
   * If `true`, you can call {@link CapacitorUpdaterPlugin.performImmediateUpdate}.
   *
   * @since 8.0.0
   */
  immediateUpdateAllowed?: boolean;

  /**
   * Whether a flexible update is allowed (Android only).
   *
   * If `true`, you can call {@link CapacitorUpdaterPlugin.startFlexibleUpdate}.
   *
   * @since 8.0.0
   */
  flexibleUpdateAllowed?: boolean;

  /**
   * Number of days since the update became available (Android only).
   *
   * Use this to implement "update nagging" - remind users more frequently
   * as the update ages.
   *
   * @since 8.0.0
   */
  clientVersionStalenessDays?: number;

  /**
   * The current install status of a flexible update (Android only).
   *
   * @since 8.0.0
   */
  installStatus?: FlexibleUpdateInstallStatus;

  /**
   * The minimum OS version required for the available update (iOS only).
   *
   * @since 8.0.0
   */
  minimumOsVersion?: string;
}

/**
 * Options for {@link CapacitorUpdaterPlugin.openAppStore}.
 *
 * @since 8.0.0
 */
export interface OpenAppStoreOptions {
  /**
   * The Android package name to open in the Play Store.
   *
   * If not specified, uses the current app's package name.
   * Use this to open a different app's store page.
   *
   * Only used on Android.
   *
   * @since 8.0.0
   */
  packageName?: string;

  /**
   * The iOS App Store ID to open.
   *
   * If not specified, uses the current app's bundle identifier to look up the app.
   * Use this to open a different app's store page or when automatic lookup fails.
   *
   * Only used on iOS.
   *
   * @since 8.0.0
   */
  appId?: string;
}

/**
 * State information for flexible update progress (Android only).
 *
 * @since 8.0.0
 */
export interface FlexibleUpdateState {
  /**
   * The current installation status.
   *
   * @since 8.0.0
   */
  installStatus: FlexibleUpdateInstallStatus;

  /**
   * Number of bytes downloaded so far.
   * Only available during the `DOWNLOADING` status.
   *
   * @since 8.0.0
   */
  bytesDownloaded?: number;

  /**
   * Total number of bytes to download.
   * Only available during the `DOWNLOADING` status.
   *
   * @since 8.0.0
   */
  totalBytesToDownload?: number;
}

/**
 * Result of an app update operation.
 *
 * @since 8.0.0
 */
export interface AppUpdateResult {
  /**
   * The result code of the update operation.
   *
   * @since 8.0.0
   */
  code: AppUpdateResultCode;
}

/**
 * Update availability status.
 *
 * @since 8.0.0
 */
export enum AppUpdateAvailability {
  /**
   * Update availability is unknown.
   * This typically means the check hasn't completed or failed.
   */
  UNKNOWN = 0,

  /**
   * No update is available.
   * The installed version is the latest.
   */
  UPDATE_NOT_AVAILABLE = 1,

  /**
   * An update is available for download.
   */
  UPDATE_AVAILABLE = 2,

  /**
   * An update is currently being downloaded or installed.
   */
  UPDATE_IN_PROGRESS = 3,
}

/**
 * Installation status for flexible updates (Android only).
 *
 * @since 8.0.0
 */
export enum FlexibleUpdateInstallStatus {
  /**
   * Unknown install status.
   */
  UNKNOWN = 0,

  /**
   * Download is pending and will start soon.
   */
  PENDING = 1,

  /**
   * Download is in progress.
   * Check `bytesDownloaded` and `totalBytesToDownload` for progress.
   */
  DOWNLOADING = 2,

  /**
   * The update is being installed.
   */
  INSTALLING = 3,

  /**
   * The update has been installed.
   * The app needs to be restarted to use the new version.
   */
  INSTALLED = 4,

  /**
   * The update failed to download or install.
   */
  FAILED = 5,

  /**
   * The update was canceled by the user.
   */
  CANCELED = 6,

  /**
   * The update has been downloaded and is ready to install.
   * Call {@link CapacitorUpdaterPlugin.completeFlexibleUpdate} to install.
   */
  DOWNLOADED = 11,
}

/**
 * Result codes for app update operations.
 *
 * @since 8.0.0
 */
export enum AppUpdateResultCode {
  /**
   * The update completed successfully.
   */
  OK = 0,

  /**
   * The user canceled the update.
   */
  CANCELED = 1,

  /**
   * The update failed.
   */
  FAILED = 2,

  /**
   * No update is available.
   */
  NOT_AVAILABLE = 3,

  /**
   * The requested update type is not allowed.
   * For example, trying to perform an immediate update when only flexible is allowed.
   */
  NOT_ALLOWED = 4,

  /**
   * Required information is missing.
   * This can happen if {@link CapacitorUpdaterPlugin.getAppUpdateInfo} wasn't called first.
   */
  INFO_MISSING = 5,
}
