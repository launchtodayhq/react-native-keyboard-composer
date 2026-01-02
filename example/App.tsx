import { useState, useCallback } from "react";
import {
  View,
  Text,
  StyleSheet,
  useColorScheme,
  ScrollView,
  StatusBar,
  TouchableOpacity,
} from "react-native";
import { Feather } from "@expo/vector-icons";
import {
  SafeAreaProvider,
  useSafeAreaInsets,
} from "react-native-safe-area-context";
import {
  KeyboardComposer,
  KeyboardAwareWrapper,
  constants,
} from "@launchhq/react-native-keyboard-composer";
import { useResponsive } from "./hooks/useResponsive";

// Start with an empty conversation to verify pin-to-top behavior on first send
const INITIAL_MESSAGES: Message[] = [];

interface Message {
  id: string;
  text: string;
  role: "user" | "assistant";
  timestamp: number;
}

function ChatScreen() {
  const insets = useSafeAreaInsets();
  const colorScheme = useColorScheme();
  const isDark = colorScheme === "dark";
  const { isTablet, isDesktop, width, scaleFont } = useResponsive();

  const [messages, setMessages] = useState<Message[]>(INITIAL_MESSAGES);
  const [composerHeight, setComposerHeight] = useState(
    constants.defaultMinHeight
  );

  const handleHeightChange = useCallback((height: number) => {
    setComposerHeight(height);
  }, []);

  // Responsive layout
  const isLargeScreen = isTablet || isDesktop;
  const maxContentWidth = isLargeScreen ? Math.min(600, width - 48) : undefined;

  const colors = {
    background: isDark ? "#000000" : "#ffffff",
    // Match Launch app ChatBubble styling
    userBubble: isDark ? "#2a2a2a" : "#F4F4F4",
    userText: isDark ? "#ffffff" : "#000000",
    assistantText: isDark ? "#ffffff" : "#000000",
    timestamp: isDark ? "#8e8e93" : "#8e8e93",
    actionIcon: isDark ? "#8e8e93" : "#6e6e73",
  };

  const noop = useCallback(() => {}, []);

  const handleSend = useCallback((text: string) => {
    if (!text.trim()) return;

    const userMessage: Message = {
      id: Date.now().toString(),
      text: text.trim(),
      role: "user",
      timestamp: Date.now(),
    };

    setMessages((prev) => [...prev, userMessage]);

    // Simulate streaming assistant response
    const responses = [
      "That's interesting! Tell me more about what you're building. I'd love to hear more details about your project and how the keyboard handling fits into your app's UX.",
      "I see what you mean. Good keyboard handling really does make a difference in chat UX. The native feel of smooth animations and proper content insets creates a much more polished experience.",
      "Great observation! Notice how the content adjusts as you type. This library handles all the edge cases: keyboard show/hide, input growing, maintaining scroll position, and more.",
      "Thanks for trying out the keyboard composer! This demonstrates ChatGPT-style pin-to-top behavior where new messages appear at the top with room for the response to stream in below.",
    ];
    // Use the last (long) response for testing, or random for variety
    const fullResponse = responses[responses.length - 1]; // Always use long response for testing
    // const fullResponse = responses[Math.floor(Math.random() * responses.length)];
    const assistantId = (Date.now() + 1).toString();

    // Add empty assistant message first (like typing indicator)
    setTimeout(() => {
      setMessages((prev) => [
        ...prev,
        {
          id: assistantId,
          text: "",
          role: "assistant",
          timestamp: Date.now(),
        },
      ]);
    }, 500);

    // Stream the response word by word
    const words = fullResponse.split(" ");
    let currentText = "";

    words.forEach((word, index) => {
      setTimeout(() => {
        currentText += (index === 0 ? "" : " ") + word;
        const streamedText = currentText;
        setMessages((prev) =>
          prev.map((msg) =>
            msg.id === assistantId ? { ...msg, text: streamedText } : msg
          )
        );
      }, 600 + index * 50); // 50ms per word
    });
  }, []);

  const renderMessage = (item: Message) => {
    const isUser = item.role === "user";

    // Show typing indicator for empty assistant messages (streaming)
    if (!isUser && !item.text) {
      return (
        <View key={item.id} style={styles.typingIndicator}>
          <Text
            style={{ color: colors.assistantText, fontSize: scaleFont(16) }}
          >
            ...
          </Text>
        </View>
      );
    }

    const messageContent = isUser ? (
      <View style={[styles.messageContainer, styles.userMessage]}>
        <View style={[styles.bubble, { backgroundColor: colors.userBubble }]}>
          <Text
            style={[
              styles.messageText,
              {
                color: colors.userText,
                fontSize: scaleFont(16),
                lineHeight: scaleFont(22),
              },
            ]}
          >
            {item.text}
          </Text>
        </View>
      </View>
    ) : (
      // Match Launch app AI responses: no chat bubble, just text
      <View style={[styles.messageContainer, styles.assistantMessage]}>
        <Text
          style={[
            styles.messageText,
            {
              color: colors.assistantText,
              fontSize: scaleFont(16),
              lineHeight: scaleFont(22),
            },
          ]}
        >
          {item.text}
        </Text>
        <View style={styles.messageActions}>
          <TouchableOpacity
            style={styles.actionButton}
            onPress={noop}
            hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
          >
            <Feather name="copy" size={18} color={colors.actionIcon} />
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.actionButton}
            onPress={noop}
            hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
          >
            <Feather name="share" size={18} color={colors.actionIcon} />
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.actionButton}
            onPress={noop}
            hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
          >
            <Feather
              name="more-horizontal"
              size={18}
              color={colors.actionIcon}
            />
          </TouchableOpacity>
        </View>
      </View>
    );

    // Center content on large screens
    if (isLargeScreen && maxContentWidth) {
      return (
        <View key={item.id} style={styles.messageWrapper}>
          <View style={{ width: maxContentWidth }}>{messageContent}</View>
        </View>
      );
    }

    return <View key={item.id}>{messageContent}</View>;
  };

  // Bottom inset for scroll content - just composer height (gap handled natively)
  const baseBottomInset = composerHeight;

  // Debug log

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <StatusBar barStyle={isDark ? "light-content" : "dark-content"} />

      {/* Header */}
      <View style={[styles.header, { paddingTop: insets.top + 8 }]}>
        <Text
          style={[
            styles.headerTitle,
            { color: isDark ? "#fff" : "#000", fontSize: scaleFont(17) },
          ]}
        >
          Keyboard Composer Example
        </Text>
        <Text
          style={[
            styles.headerSubtitle,
            { color: colors.timestamp, fontSize: scaleFont(12) },
          ]}
        >
          Content-aware keyboard handling
        </Text>
      </View>

      {/* KeyboardAwareWrapper manages both scroll content AND composer animation */}
      <KeyboardAwareWrapper
        style={styles.chatArea}
        pinToTopEnabled={true}
        extraBottomInset={baseBottomInset}
      >
        {/* ScrollView with messages */}
        <ScrollView
          style={styles.scrollView}
          contentContainerStyle={[
            styles.messageList,
            isLargeScreen && styles.messageListCentered,
          ]}
        >
          {messages.map(renderMessage)}
        </ScrollView>

        {/* Composer - positioned absolutely, animated by native code */}
        {/* Note: Safe area padding is handled natively by KeyboardAwareWrapper */}
        <View
          style={[styles.composerContainer, { height: composerHeight }]}
          pointerEvents="box-none"
        >
          <View
            style={[
              styles.composerInner,
              isLargeScreen && styles.composerInnerCentered,
            ]}
            pointerEvents="box-none"
          >
            <View
              style={[
                styles.composerWrapper,
                { backgroundColor: isDark ? "#1C1C1E" : "#F2F2F7" },
                maxContentWidth ? { width: maxContentWidth } : undefined,
              ]}
            >
              <KeyboardComposer
                style={{ flex: 1 }}
                placeholder="Ask anything"
                onSend={handleSend}
                onHeightChange={handleHeightChange}
                minHeight={constants.defaultMinHeight}
                maxHeight={constants.defaultMaxHeight}
                sendButtonEnabled={true}
              />
            </View>
          </View>
        </View>
      </KeyboardAwareWrapper>
    </View>
  );
}

export default function App() {
  return (
    <SafeAreaProvider>
      <ChatScreen />
    </SafeAreaProvider>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  header: {
    paddingHorizontal: 16,
    paddingBottom: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#e5e5e5",
  },
  headerTitle: {
    fontWeight: "600",
    textAlign: "center",
  },
  headerSubtitle: {
    textAlign: "center",
    marginTop: 2,
  },
  chatArea: {
    flex: 1,
  },
  scrollView: {
    flex: 1,
  },
  messageList: {
    paddingHorizontal: 16,
    paddingTop: 16,
    // No paddingBottom needed - native code handles spacing via extraBottomInset
  },
  messageListCentered: {
    alignItems: "center",
  },
  messageWrapper: {
    alignItems: "center",
    width: "100%",
  },
  messageContainer: {
    marginBottom: 32,
  },
  userMessage: {
    alignItems: "flex-end",
  },
  assistantMessage: {
    alignItems: "flex-start",
  },
  typingIndicator: {
    marginBottom: 32,
    alignItems: "flex-start",
  },
  bubble: {
    maxWidth: "80%",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 20,
  },
  messageText: {
    // fontSize and lineHeight set dynamically via scaleFont
  },
  messageActions: {
    flexDirection: "row",
    gap: 4,
    marginTop: 8,
  },
  actionButton: {
    padding: 4,
  },
  // Composer styles - matches ai-chat.tsx pattern
  composerContainer: {
    position: "absolute",
    left: 0,
    right: 0,
    bottom: 0,
  },
  composerInner: {
    paddingHorizontal: 16,
    flex: 1,
  },
  composerInnerCentered: {
    alignItems: "center",
  },
  composerWrapper: {
    borderRadius: 24,
    overflow: "hidden",
    flex: 1,
  },
});
