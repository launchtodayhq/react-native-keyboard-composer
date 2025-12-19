import { useWindowDimensions, PixelRatio, Platform } from "react-native";

const BASE_WIDTH = 375;

export interface ResponsiveInfo {
  width: number;
  height: number;
  isLandscape: boolean;
  isPhone: boolean;
  isTablet: boolean;
  isDesktop: boolean;
  isSmallPhone: boolean;
  scaleFont: (size: number) => number;
}

export function useResponsive(): ResponsiveInfo {
  const { width, height, fontScale = 1 } = useWindowDimensions();

  const isLandscape = width > height;

  // Use Platform.isPad for iOS (reliable), width-based for Android
  const isIOSTablet = Platform.OS === "ios" && Platform.isPad === true;
  const isAndroidTablet =
    Platform.OS === "android" && width >= 600 && width < 1024;
  const isTablet = isIOSTablet || isAndroidTablet;
  const isPhone = !isTablet && width < 1024;
  const isDesktop = width >= 1024;
  const isSmallPhone = isPhone && height < 700;

  const scaleFont = (size: number): number => {
    const scale = width / BASE_WIDTH;

    let scaleFactor: number;
    if (isPhone) {
      scaleFactor = 1.0 + (scale - 1) * 0.3;
    } else if (isTablet) {
      scaleFactor = 1.0 + (scale - 1) * 0.15;
    } else {
      scaleFactor = 1.0 + (scale - 1) * 0.25;
    }

    let scaledSize = size * scaleFactor * fontScale;
    const autoMin = size * 0.85;
    const autoMax = size * 1.25;

    scaledSize = Math.max(scaledSize, autoMin);
    scaledSize = Math.min(scaledSize, autoMax);

    return Math.round(PixelRatio.roundToNearestPixel(scaledSize));
  };

  return {
    width,
    height,
    isLandscape,
    isPhone,
    isTablet,
    isDesktop,
    isSmallPhone,
    scaleFont,
  };
}

