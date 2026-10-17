const ionic = require('@ionic/eslint-config/recommended');

module.exports = [
  {
    ignores: [
      'build',
      'dist',
      'example-app',
      'docs',
      'core-c/build*',
      'core-c/.deps',
      'core/target',
      'core/fuzz/target',
    ],
  },
  ...ionic,
];
