const Module = require('module');

const originalResolveFilename = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  if (
    request === 'typescript' &&
    (parent?.filename?.includes('@typescript-eslint') || parent?.filename?.includes('ts-api-utils'))
  ) {
    return originalResolveFilename.call(this, '@typescript/typescript6', parent, isMain, options);
  }

  return originalResolveFilename.call(this, request, parent, isMain, options);
};

const ionic = require('@ionic/eslint-config/recommended');

module.exports = [{ ignores: ['build', 'dist', 'example-app', 'docs'] }, ...ionic];
