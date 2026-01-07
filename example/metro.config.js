// Learn more https://docs.expo.dev/guides/customizing-metro/
//
// This example supports two modes:
// - default: behaves like a real consumer (resolves the published package from node_modules)
// - local: resolves the package from the parent workspace for library development

if (process.env.USE_LOCAL_KEYBOARD_COMPOSER === "1") {
  module.exports = require("./metro.config.local");
} else {
  const { getDefaultConfig } = require("expo/metro-config");
  module.exports = getDefaultConfig(__dirname);
}
