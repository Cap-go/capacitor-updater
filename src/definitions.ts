export interface CapacitorUpdaterPlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
