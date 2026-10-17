const ionic = require('@ionic/swiftlint-config');

module.exports = {
  ...ionic,
  excluded: [...ionic.excluded, '${PWD}/.context'],
};
