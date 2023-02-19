import { WebPlugin } from "@capacitor/core";

import type {
  CapacitorUpdaterPlugin,
  BundleInfo,
  LatestVersion,
  DelayCondition,
  ChannelRes,
  SetChannelOptions,
  GetChannelRes,
  SetCustomIdOptions,
} from "./definitions";

const BUNDLE_BUILTIN: BundleInfo = {
  status: "success",
  version: "",
  downloaded: "1970-01-01T00:00:00.000Z",
  id: "builtin",
  checksum: "",
};

export class CapacitorUpdaterWeb
  extends WebPlugin
  implements CapacitorUpdaterPlugin
{
  async download(options: {
    url: string;
    version?: string;
  }): Promise<BundleInfo> {
    console.warn("Cannot download version in web", options);
    return BUNDLE_BUILTIN;
  }
  async next(options: { id: string }): Promise<BundleInfo> {
    console.warn("Cannot set next version in web", options);
    return BUNDLE_BUILTIN;
  }

  async isAutoUpdateEnabled(): Promise<{ enabled: boolean }> {
    console.warn("Cannot get isAutoUpdateEnabled in web");
    return { enabled: false };
  }
  async set(options: { id: string }): Promise<void> {
    console.warn("Cannot set active bundle in web", options);
  }
  async getDeviceId(): Promise<{ deviceId: string }> {
    console.warn("Cannot get ID in web");
    return { deviceId: "default" };
  }
  async getPluginVersion(): Promise<{ version: string }> {
    console.warn("Cannot get plugin version in web");
    return { version: "default" };
  }
  async delete(options: { id: string }): Promise<void> {
    console.warn("Cannot delete bundle in web", options);
  }
  async list(): Promise<{ bundles: BundleInfo[] }> {
    console.warn("Cannot list bundles in web");
    return { bundles: [] };
  }
  async reset(options?: { toLastSuccessful?: boolean }): Promise<void> {
    console.warn("Cannot reset version in web", options);
  }
  async current(): Promise<{ bundle: BundleInfo; native: string }> {
    console.warn("Cannot get current bundle in web");
    return { bundle: BUNDLE_BUILTIN, native: "0.0.0" };
  }
  async reload(): Promise<void> {
    console.warn("Cannot reload current bundle in web");
  }
  async getLatest(): Promise<LatestVersion> {
    console.warn("Cannot getLatest current bundle in web");
    return {
      version: "0.0.0",
      message: "Cannot getLatest current bundle in web",
    };
  }
  async setChannel(options: SetChannelOptions): Promise<ChannelRes> {
    console.warn("Cannot setChannel in web", options);
    return {
      status: "error",
      error: "Cannot setChannel in web",
    };
  }
  async setCustomId(options: SetCustomIdOptions): Promise<void> {
    console.warn("Cannot setCustomId in web", options);
  }
  async getChannel(): Promise<GetChannelRes> {
    console.warn("Cannot getChannel in web");
    return {
      status: "error",
      error: "Cannot getChannel in web",
    };
  }
  async notifyAppReady(): Promise<BundleInfo> {
    console.warn("Cannot notify App Ready in web");
    return BUNDLE_BUILTIN;
  }
  async setMultiDelay(options: {
    delayConditions: DelayCondition[];
  }): Promise<void> {
    console.warn("Cannot setMultiDelay in web", options?.delayConditions);
  }
  async setDelay(option: DelayCondition): Promise<void> {
    console.warn("Cannot setDelay in web", option);
  }
  async cancelDelay(): Promise<void> {
    console.warn("Cannot cancelDelay in web");
  }
}
