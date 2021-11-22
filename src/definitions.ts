export interface CapacitorUpdaterPlugin {
    /**
   * download new version from url
   * @returns {Promise<{version: string}>} an Promise with version name of the downloaded version
   * @param url The url where download the version, it can be S3 github tag or whatever, it should be a zip file
   */
  download(options: { url: string }): Promise<{ version: string }>;
    /**
   * set version as current version
   * @returns {Promise<void>} an empty Promise
   * @param version The version name to set as current version
   */
  set(options: { version: string }): Promise<void>;
    /**
   * delete version in storage
   * @returns {Promise<void>} an empty Promise
   * @param version The version name to delete
   */
  delete(options: { version: string }): Promise<void>;
    /**
   * get all avaible verisions
   * @returns {Promise<{version: string[]}>} an Promise witht the version list
   */
  list(): Promise<{ versions: string[] }>;
    /**
   * load current version
   * @returns {Promise<void>} an empty Promise
   */
  load(): Promise<void>;
}
