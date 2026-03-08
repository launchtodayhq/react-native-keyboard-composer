// Optional local-dev toggle:
// USE_LOCAL_KEYBOARD_COMPOSER=1 will make Expo autolinking look for the module in ../
// so native Android/iOS changes in the package are picked up after a clean prebuild.
const base = require("./app.json");

module.exports = ({ config }) => {
  const expoConfig = {
    ...(base.expo ?? {}),
    ...(config ?? {}),
  };

  if (process.env.USE_LOCAL_KEYBOARD_COMPOSER === "1") {
    expoConfig.autolinking = {
      ...(expoConfig.autolinking ?? {}),
      nativeModulesDir: "..",
    };
  }

  const plugins = Array.isArray(expoConfig.plugins) ? expoConfig.plugins : [];
  if (!plugins.includes("expo-font")) {
    plugins.push("expo-font");
  }
  expoConfig.plugins = plugins;

  return expoConfig;
};
