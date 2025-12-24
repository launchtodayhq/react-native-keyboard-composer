// Learn more https://docs.expo.io/guides/customizing-metro
const { getDefaultConfig } = require("expo/metro-config");
const path = require("path");

const projectRoot = __dirname;
const workspaceRoot = path.resolve(projectRoot, "..");

const config = getDefaultConfig(projectRoot);

// Watch the parent directory for the library source files
config.watchFolders = [workspaceRoot];

// Block the ENTIRE parent node_modules to avoid duplicate modules
// Only the library source (src/) is needed from parent
config.resolver.blockList = [
  ...Array.from(config.resolver.blockList ?? []),
  new RegExp(path.resolve(workspaceRoot, "node_modules") + "/.*"),
];

// Only resolve modules from example's node_modules
config.resolver.nodeModulesPaths = [path.resolve(projectRoot, "node_modules")];

// Map the library to the parent directory source
config.resolver.extraNodeModules = {
  "@launchhq/react-native-keyboard-composer": workspaceRoot,
};

module.exports = config;
