export interface CapacitorUpdaterPlugin {
  updateApp(options: { url: string }): Promise<{ done: boolean }>;
}
