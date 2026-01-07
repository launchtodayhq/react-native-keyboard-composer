// Local-dev Metro config: resolves the library from the parent workspace (../),
// so you can iterate on the package source without publishing.
const { getDefaultConfig } = require("expo/metro-config");
const path = require("path");

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, "..");

const config = getDefaultConfig(projectRoot);

config.watchFolders = [workspaceRoot];

// Block the parent node_modules to avoid duplicate React / RN copies.
config.resolver.blockList = [
  ...Array.from(config.resolver.blockList ?? []),
  new RegExp(path.resolve(workspaceRoot, "node_modules") + "/.*"),
];

config.resolver.nodeModulesPaths = [path.resolve(projectRoot, "node_modules")];

config.resolver.extraNodeModules = {
  "@launchhq/react-native-keyboard-composer": workspaceRoot,
};

module.exports = config;
