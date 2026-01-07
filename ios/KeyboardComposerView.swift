import ExpoModulesCore
import UIKit

class KeyboardComposerView: ExpoView {

  // MARK: - Props (set from JS)
  var placeholder: String = "Type a message..." {
    didSet { placeholderLabel.text = placeholder }
  }

  var text: String {
    get { textView.text ?? "" }
    set {
      // Only update if text is actually different (prevents clearing on re-render)
      guard textView.text != newValue else { return }
      textView.text = newValue
      placeholderLabel.isHidden = !newValue.isEmpty
      updateHeight()
      updateSendButtonState()
    }
  }

  var minHeight: CGFloat = 48 {
    didSet { updateHeight() }
  }

  var maxHeight: CGFloat = 120 {
    didSet { updateHeight() }
  }

  var sendButtonEnabled: Bool = true {
    didSet { updateSendButtonState() }
  }

  var editable: Bool = true {
    didSet { textView.isEditable = editable }
  }

  var autoFocus: Bool = false {
    didSet {
      if autoFocus {
        requestFocusIfPossible()
      }
    }
  }

  var isStreaming: Bool = false {
    didSet {
      updateButtonAppearance()
    }
  }

  // MARK: - Events (sent to JS)
  let onChangeText = EventDispatcher()
  let onSend = EventDispatcher()
  let onStop = EventDispatcher()
  let onHeightChange = EventDispatcher()
  let onKeyboardHeightChange = EventDispatcher()
  let onComposerFocus = EventDispatcher()
  let onComposerBlur = EventDispatcher()

  // MARK: - UI Elements
  private let containerView = UIView()
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let sendButton = UIButton(type: .system)

  // MARK: - Keyboard tracking
  private var lastNotifiedKeyboardHeight: CGFloat = 0
  private var pendingAutoFocus: Bool = false
  
  // MARK: - Height tracking
  private var currentHeight: CGFloat = 48
  private var lastBoundsWidth: CGFloat = 0

  // MARK: - Init
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupUI()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Setup UI
  private func setupUI() {
    backgroundColor = .clear
    clipsToBounds = false

    // Container background is handled natively so consumers don't have to wrap in an extra view.
    containerView.backgroundColor = composerBackgroundColor()
    containerView.layer.cornerRadius = 0
    containerView.clipsToBounds = false

    addSubview(containerView)

    // TextView - configured for multiline auto-growing
    textView.delegate = self
    textView.font = .systemFont(ofSize: 16)
    textView.backgroundColor = .clear
    textView.textColor = .label
    textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 44)
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.lineBreakMode = .byWordWrapping
    textView.isScrollEnabled = false
    textView.showsVerticalScrollIndicator = false
    textView.showsHorizontalScrollIndicator = false
    textView.returnKeyType = .default
    textView.keyboardAppearance = .default
    textView.enablesReturnKeyAutomatically = false
    textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    containerView.addSubview(textView)
    
    // Swipe down gesture to dismiss keyboard
    let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
    swipeDown.direction = .down
    textView.addGestureRecognizer(swipeDown)
    
    // Swipe up gesture to focus and open keyboard
    let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
    swipeUp.direction = .up
    textView.addGestureRecognizer(swipeUp)

    // Placeholder
    placeholderLabel.text = placeholder
    placeholderLabel.font = .systemFont(ofSize: 16)
    placeholderLabel.textColor = placeholderColor()
    containerView.addSubview(placeholderLabel)

    // Send/Stop button
    sendButton.addTarget(self, action: #selector(handleButtonPress), for: .touchUpInside)
    containerView.addSubview(sendButton)
    updateButtonAppearance()

    setupConstraints()
    updateSendButtonState()
    
    // Emit initial height
    DispatchQueue.main.async { [weak self] in
      self?.onHeightChange(["height": self?.minHeight ?? 48])
    }
  }

  private func placeholderColor() -> UIColor {
    // Slightly darker than `.placeholderText` for better readability.
    // Keep platform-appropriate contrast in light/dark mode.
    return UIColor { traits in
      if traits.userInterfaceStyle == .dark {
        return UIColor(white: 0.72, alpha: 1.0)
      } else {
        return UIColor(white: 0.40, alpha: 1.0)
      }
    }
  }

  private func composerBackgroundColor() -> UIColor {
    return UIColor { traits in
      if traits.userInterfaceStyle == .dark {
        return UIColor(red: 28.0/255.0, green: 28.0/255.0, blue: 30.0/255.0, alpha: 1.0) // #1C1C1E
      } else {
        return UIColor(red: 242.0/255.0, green: 242.0/255.0, blue: 242.0/255.0, alpha: 1.0) // #F2F2F2
      }
    }
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // Ensure placeholder color stays correct when switching light/dark mode.
    placeholderLabel.textColor = placeholderColor()
    containerView.backgroundColor = composerBackgroundColor()
    textView.textColor = .label
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    
    guard bounds.width > 0, bounds.height > 0 else { return }
    
    containerView.frame = bounds
    
    textView.frame = CGRect(
      x: 0,
      y: 0,
      width: containerView.bounds.width,
      height: containerView.bounds.height
    )
    
    let placeholderHeight = placeholderLabel.intrinsicContentSize.height
    placeholderLabel.frame = CGRect(
      x: 17,
      y: 14,
      width: bounds.width - 60,
      height: placeholderHeight
    )
    
    let buttonSize: CGFloat = 32
    let buttonX = bounds.width - 40
    let bottomPlacementY = bounds.height - 42
    // Optical centering tweak. Negative moves the button up.
    // This is intentionally small and can be tuned by feel.
    let centerYOffset: CGFloat = -1
    let centeredY = ((bounds.height - buttonSize) / 2) + centerYOffset
    let isSingleLine = bounds.height <= (minHeight + 2)
    let buttonY = isSingleLine ? centeredY : bottomPlacementY

    sendButton.frame = CGRect(
      x: buttonX,
      y: buttonY,
      width: buttonSize,
      height: buttonSize
    )
    
    if bounds.width != lastBoundsWidth {
      lastBoundsWidth = bounds.width
      DispatchQueue.main.async { [weak self] in
        self?.updateHeight()
      }
    }
  }

  private func setupConstraints() {
    // Using frame-based layout in layoutSubviews
  }

  // MARK: - Keyboard Layout Guide Integration
  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    
    // If moving to nil window, view is being removed (e.g., navigating away)
    // Dismiss keyboard early to prevent it staying open during transition
    if newWindow == nil {
      textView.resignFirstResponder()
    }
  }
  
  override func didMoveToWindow() {
    super.didMoveToWindow()

    guard let window = window else {
      return
    }

    if (autoFocus || pendingAutoFocus) {
      pendingAutoFocus = false
      DispatchQueue.main.async { [weak self] in
        self?.textView.becomeFirstResponder()
      }
    }
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    var v: UIView? = superview
    while let current = v {
      if let wrapper = current as? KeyboardAwareWrapper {
        wrapper.registerComposerView(self)
        break
      }
      v = current.superview
    }
  }

  private func requestFocusIfPossible() {
    if window == nil {
      pendingAutoFocus = true
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.textView.becomeFirstResponder()
    }
  }

  func notifyKeyboardHeight(_ height: CGFloat) {
    if abs(height - lastNotifiedKeyboardHeight) <= 0.5 { return }
    lastNotifiedKeyboardHeight = height
    onKeyboardHeightChange(["height": height])
  }

  // MARK: - Actions
  @objc private func handleButtonPress() {
    if isStreaming {
      handleStop()
    } else {
      handleSend()
    }
  }

  private func handleSend() {
    guard !textView.text.isEmpty else { return }

    // Haptic feedback
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()

    onSend([
      "text": textView.text ?? ""
    ])

    NotificationCenter.default.post(
      name: .keyboardComposerDidSend,
      object: self
    )

    textView.text = ""
    placeholderLabel.isHidden = false
    textView.resignFirstResponder()
    updateHeight()
    updateSendButtonState()
  }

  private func handleStop() {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.impactOccurred()
    onStop([:])
  }

  private func updateButtonAppearance() {
    let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
    
    if isStreaming {
      let image = UIImage(systemName: "stop.circle.fill", withConfiguration: config)
      sendButton.setImage(image, for: .normal)
      sendButton.tintColor = .label
      sendButton.isEnabled = true
      sendButton.alpha = 1.0
    } else {
      let image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: config)
      sendButton.setImage(image, for: .normal)
      sendButton.tintColor = .label
      updateSendButtonState()
    }
  }

  private func updateHeight() {
    let availableWidth = bounds.width > 0 ? bounds.width : 280
    let fittingSize = CGSize(
      width: availableWidth,
      height: .greatestFiniteMagnitude
    )
    
    let size = textView.sizeThatFits(fittingSize)
    let contentHeight = max(size.height, minHeight)
    let newHeight = min(contentHeight, maxHeight)
    
    let shouldScroll = contentHeight > maxHeight
    if textView.isScrollEnabled != shouldScroll {
      textView.isScrollEnabled = shouldScroll
    }
    
    if abs(newHeight - currentHeight) > 0.5 {
      currentHeight = newHeight
      onHeightChange([
        "height": newHeight
      ])
    }
  }

  private func updateSendButtonState() {
    let hasText = !textView.text.isEmpty
    sendButton.isEnabled = sendButtonEnabled && hasText
    sendButton.alpha = sendButton.isEnabled ? 1.0 : 0.4
  }

  // MARK: - Gestures
  @objc private func handleSwipeDown() {
    textView.resignFirstResponder()
  }
  
  @objc private func handleSwipeUp() {
    textView.becomeFirstResponder()
  }
  
  // MARK: - Public methods for JS
  func focus() {
    textView.becomeFirstResponder()
  }

  func blur() {
    textView.resignFirstResponder()
  }

  func clear() {
    textView.text = ""
    placeholderLabel.isHidden = false
    updateHeight()
    updateSendButtonState()
    onChangeText(["text": ""])
  }
}

extension Notification.Name {
  static let keyboardComposerDidSend = Notification.Name("KeyboardComposerDidSend")
}

// MARK: - UITextViewDelegate
extension KeyboardComposerView: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    placeholderLabel.isHidden = !textView.text.isEmpty

    onChangeText([
      "text": textView.text ?? ""
    ])

    updateHeight()
    updateSendButtonState()
  }

  func textViewDidBeginEditing(_ textView: UITextView) {
    onComposerFocus([:])
    }

  func textViewDidEndEditing(_ textView: UITextView) {
    onComposerBlur([:])
  }
}
