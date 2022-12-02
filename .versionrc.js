const bumpFiles = [
  {
    filename: "./package.json",
    type: "json",
  },
  {
    filename: "./package-lock.json",
    type: "json",
  },
  {
    filename:
      "./android/src/main/java/ee/forgr/capacitor_updater/CapacitorUpdater.java",
    updater: {
      readVersion: (contents) => {
        const marketingVersionString = contents.match(
          /String pluginVersion = "(.*)";/
        );
        const version = marketingVersionString.toString();
        return version;
      },
      writeVersion: (contents, version) => {
        const newContent = contents.replace(
          /String pluginVersion = ".*";/g,
          `String pluginVersion = "${version}";`
        );
        return newContent;
      },
    },
  },
  {
    filename: "./ios/Plugin/CapacitorUpdater.swift",
    updater: {
      readVersion: (contents) => {
        const marketingVersionString = contents.match(
          /let pluginVersion = "(.*)"/
        );
        const version = marketingVersionString.toString();
        return version;
      },
      writeVersion: (contents, version) => {
        const newContent = contents.replace(
          /let pluginVersion = ".*"/g,
          `let pluginVersion = "${version}"`
        );
        return newContent;
      },
    },
  },
];

module.exports = {
  noVerify: true,
  tagPrefix: "",
  bumpFiles: bumpFiles,
  packageFiles: [
    {
      filename: "./package.json",
      type: "json",
    },
  ],
};
