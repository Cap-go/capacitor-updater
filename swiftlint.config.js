module.exports = {
  ...require('@ionic/swiftlint-config'),
  identifier_name: {
    excluded: ['id', 'ID_BUILTIN', 'VERSION_UNKNOWN', 'DOWNLOADED_BUILTIN'],
  },
};
