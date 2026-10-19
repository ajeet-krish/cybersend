const { defineConfig } = require('eslint/config');
const expoConfig = require('eslint-config-expo/flat');

module.exports = defineConfig([
  expoConfig,
  {
    ignores: ['dist/*', '.expo/*'],
  },
  {
    rules: {
      // Screens load repository data on mount and setState after awaits, which is the standard
      // async pattern for local first apps. The rule cannot see through the async boundary, so
      // it is disabled project wide rather than sprinkling suppressions through every screen.
      'react-hooks/set-state-in-effect': 'off',
    },
  },
]);
