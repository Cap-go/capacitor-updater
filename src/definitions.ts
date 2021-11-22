export interface CapacitorUpdaterPlugin {
  download(options: { url: string }): Promise<{ version: string }>;
  setVersion(options: { version: string }): Promise<void>;
  load(): Promise<void>;
}
