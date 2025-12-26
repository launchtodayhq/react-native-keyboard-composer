import ExpoModulesCore
import UIKit

class KeyboardComposerView: ExpoView {

  // MARK: - Props (set from JS)
  enum PTTState: String {
    case available
    case talking
    case listening
  }

  var placeholder: String = "Type a message..." {
    didSet { placeholderLabel.text = placeholder }
  }

  var text: String {
    get { textView.text ?? "" }
    set {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
          self?.textView.becomeFirstResponder()
        }
      }
    }
  }

  var isStreaming: Bool = false {
    didSet {
      updateButtonAppearance()
    }
  }

  var showPTTButton: Bool = false {
    didSet {
      pttButton.isHidden = !showPTTButton
      setNeedsLayout()
    }
  }

  var pttEnabled: Bool = true {
    didSet { updatePTTEnabledState() }
  }

  var pttState: String = PTTState.available.rawValue {
    didSet { updatePTTButtonAppearance() }
  }

  var pttPressedScale: CGFloat = 0.92
  var pttPressedOpacity: CGFloat = 0.85

  // MARK: - Events (sent to JS)
  let onChangeText = EventDispatcher()
  let onSend = EventDispatcher()
  let onStop = EventDispatcher()
  let onHeightChange = EventDispatcher()
  let onKeyboardHeightChange = EventDispatcher()
  let onComposerFocus = EventDispatcher()
  let onComposerBlur = EventDispatcher()
  let onPTTPress = EventDispatcher()
  let onPTTPressIn = EventDispatcher()
  let onPTTPressOut = EventDispatcher()

  // MARK: - UI Elements
  private let blurView: UIVisualEffectView = {
    let view = UIVisualEffectView(effect: nil)
    view.layer.cornerRadius = 24
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }()
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private let sendButton = UIButton(type: .system)
  private let pttButton = UIButton(type: .system)

  // MARK: - Keyboard tracking
  private var currentKeyboardHeight: CGFloat = 0
  private var displayLink: CADisplayLink?
  
  // MARK: - Height tracking
  private var currentHeight: CGFloat = 48
  private var lastBoundsWidth: CGFloat = 0
  
  // MARK: - Layout constants
  private let buttonSize: CGFloat = 48
  private let buttonPadding: CGFloat = 8
  private let buttonIconSize: CGFloat = 32
  private var isPTTPressed: Bool = false

  // MARK: - Init
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    setupUI()
  }

  deinit {
    displayLink?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Setup UI
  private func setupUI() {
    backgroundColor = .clear
    clipsToBounds = false

    // Configure blur effect based on iOS version
    configureBlurEffect()
    addSubview(blurView)

    // TextView - configured for multiline auto-growing
    textView.delegate = self
    textView.font = .systemFont(ofSize: 16)
    textView.backgroundColor = .clear
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
    blurView.contentView.addSubview(textView)
    
    // Swipe gestures
    let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown))
    swipeDown.direction = .down
    textView.addGestureRecognizer(swipeDown)
    
    let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeUp))
    swipeUp.direction = .up
    textView.addGestureRecognizer(swipeUp)

    // Placeholder
    placeholderLabel.text = placeholder
    placeholderLabel.font = .systemFont(ofSize: 16)
    placeholderLabel.textColor = .placeholderText
    blurView.contentView.addSubview(placeholderLabel)

    // PTT Button (left side) - circular like send button
    pttButton.addTarget(self, action: #selector(handlePTTTouchDown), for: .touchDown)
    pttButton.addTarget(self, action: #selector(handlePTTTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    pttButton.addTarget(self, action: #selector(handlePTTTap), for: .touchUpInside)
    pttButton.isHidden = true
    blurView.contentView.addSubview(pttButton)
    updatePTTButtonAppearance()
    updatePTTEnabledState()

    // Send/Stop button (right side)
    sendButton.addTarget(self, action: #selector(handleSendTouchDown), for: .touchDown)
    sendButton.addTarget(self, action: #selector(handleSendTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    sendButton.addTarget(self, action: #selector(handleButtonPress), for: .touchUpInside)
    blurView.contentView.addSubview(sendButton)
    updateButtonAppearance()

    updateSendButtonState()
    
    // Emit initial height
    DispatchQueue.main.async { [weak self] in
      self?.onHeightChange(["height": self?.minHeight ?? 48])
    }
  }

  private func configureBlurEffect() {
    if #available(iOS 26.0, *) {
      // Use Liquid Glass on iOS 26+
      let glassEffect = UIGlassEffect()
      blurView.effect = glassEffect
    } else {
      // Fall back to system material blur
      let blurEffect = UIBlurEffect(style: .systemThinMaterial)
      blurView.effect = blurEffect
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    
    guard bounds.width > 0, bounds.height > 0 else { return }
    
    // Blur fills entire view
    blurView.frame = bounds
    
    // Button Y position - centered within the bottom minHeight zone
    // Formula: bounds.height - (minHeight / 2) - (buttonSize / 2)
    let buttonY = bounds.height - (minHeight / 2) - (buttonSize / 2)
    
    // PTT button on left
    let pttX: CGFloat = buttonPadding
    pttButton.frame = CGRect(x: pttX, y: buttonY, width: buttonSize, height: buttonSize)
    
    // Send button on right
    let sendX = bounds.width - buttonSize - buttonPadding
    sendButton.frame = CGRect(x: sendX, y: buttonY, width: buttonSize, height: buttonSize)
    
    // Calculate text area bounds
    let leftInset: CGFloat = showPTTButton ? (buttonPadding + buttonSize + 8) : 16
    let rightInset: CGFloat = buttonPadding + buttonSize + 4
    
    // TextView frame - full width, with fixed vertical padding
    let textViewPadding: CGFloat = 8
    textView.frame = CGRect(
      x: leftInset,
      y: textViewPadding,
      width: bounds.width - leftInset - rightInset,
      height: bounds.height - (textViewPadding * 2)
    )
    textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    
    // Placeholder positioned at the same location as text
    let placeholderHeight = placeholderLabel.intrinsicContentSize.height
    placeholderLabel.frame = CGRect(
      x: leftInset + 5,
      y: textViewPadding + 6,
      width: textView.frame.width - 10,
      height: placeholderHeight
    )
    
    if bounds.width != lastBoundsWidth {
      lastBoundsWidth = bounds.width
      DispatchQueue.main.async { [weak self] in
        self?.updateHeight()
      }
    }
  }

  // MARK: - Keyboard Layout Guide Integration
  override func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)
    
    if newWindow == nil {
      textView.resignFirstResponder()
    }
  }
  
  override func didMoveToWindow() {
    super.didMoveToWindow()

    guard let window = window else {
      displayLink?.invalidate()
      displayLink = nil
      return
    }

    if #available(iOS 15.0, *) {
      setupKeyboardLayoutGuide(in: window)
    } else {
      setupKeyboardNotifications()
    }
  }

  @available(iOS 15.0, *)
  private func setupKeyboardLayoutGuide(in window: UIWindow) {
    window.keyboardLayoutGuide.followsUndockedKeyboard = true
    displayLink?.invalidate()
    displayLink = CADisplayLink(target: self, selector: #selector(trackKeyboardPosition))
    displayLink?.add(to: .main, forMode: .common)
  }

  @objc private func trackKeyboardPosition() {
    guard let window = window else { return }

    if #available(iOS 15.0, *) {
      let guideFrame = window.keyboardLayoutGuide.layoutFrame
      let keyboardHeight = max(0, window.bounds.height - guideFrame.minY)

      if abs(keyboardHeight - currentKeyboardHeight) > 0.5 {
        currentKeyboardHeight = keyboardHeight
        onKeyboardHeightChange([
          "height": keyboardHeight
        ])
      }
    }
  }

  private func setupKeyboardNotifications() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillShow),
      name: UIResponder.keyboardWillShowNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillHide),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
  }

  @objc private func keyboardWillShow(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
      return
    }
    let keyboardHeight = keyboardFrame.height
    if keyboardHeight != currentKeyboardHeight {
      currentKeyboardHeight = keyboardHeight
      onKeyboardHeightChange(["height": keyboardHeight])
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    if currentKeyboardHeight != 0 {
      currentKeyboardHeight = 0
      onKeyboardHeightChange(["height": 0])
    }
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

    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()

    onSend([
      "text": textView.text ?? ""
    ])

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

  @objc private func handleSendTouchDown() {
    animateButton(sendButton, pressed: true, scale: 0.92, opacity: 0.85)
  }

  @objc private func handleSendTouchUp() {
    animateButton(sendButton, pressed: false, scale: 0.92, opacity: 0.85)
  }

  // MARK: - PTT Actions
  @objc private func handlePTTTouchDown() {
    guard pttEnabled else { return }
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    isPTTPressed = true
    animateButton(pttButton, pressed: true, scale: pttPressedScale, opacity: pttPressedOpacity)
    onPTTPressIn([:])
  }

  @objc private func handlePTTTouchUp() {
    guard pttEnabled else { return }
    isPTTPressed = false
    animateButton(pttButton, pressed: false, scale: pttPressedScale, opacity: pttPressedOpacity)
    onPTTPressOut([:])
  }

  @objc private func handlePTTTap() {
    guard pttEnabled else { return }
    onPTTPress([:])
  }

  private func animateButton(_ button: UIButton, pressed: Bool, scale: CGFloat, opacity: CGFloat) {
    let targetTransform: CGAffineTransform = pressed ? CGAffineTransform(scaleX: scale, y: scale) : .identity
    let targetAlpha: CGFloat = pressed ? opacity : 1.0
    UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      button.transform = targetTransform
      button.alpha = targetAlpha
    }
  }

  private func updatePTTButtonAppearance() {
    // Create circular background image with waveform bars drawn manually
    let size = buttonIconSize
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    
    let labelColor = UIColor.label.resolvedColor(with: traitCollection)
    let bgColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
    let state = PTTState(rawValue: pttState.lowercased()) ?? .available
    let circleColor: UIColor = {
      switch state {
      case .available: return labelColor
      case .talking: return .systemRed
      case .listening: return .systemBlue
      }
    }()
    let iconColor: UIColor = (state == .available) ? bgColor : .white
    
    let image = renderer.image { context in
      let ctx = context.cgContext
      
      // Draw circle background
      ctx.setFillColor(circleColor.cgColor)
      ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
      
      // Draw waveform bars
      ctx.setStrokeColor(iconColor.cgColor)
      ctx.setLineWidth(2.5)
      ctx.setLineCap(.round)
      
      let centerX = size / 2
      let centerY = size / 2
      let barSpacing: CGFloat = 4.5
      let heights: [CGFloat] = [0.3, 0.55, 0.9, 0.55, 0.3]
      let maxBarHeight: CGFloat = size * 0.5
      
      var x = centerX - CGFloat(heights.count / 2) * barSpacing
      for heightFactor in heights {
        let barHeight = maxBarHeight * heightFactor
        ctx.move(to: CGPoint(x: x, y: centerY - barHeight / 2))
        ctx.addLine(to: CGPoint(x: x, y: centerY + barHeight / 2))
        ctx.strokePath()
        x += barSpacing
      }
    }
    
    pttButton.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
  }

  private func updateButtonAppearance() {
    let size = buttonIconSize
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let labelColor = UIColor.label.resolvedColor(with: traitCollection)
    let bgColor = UIColor.systemBackground.resolvedColor(with: traitCollection)

    let image = renderer.image { context in
      let ctx = context.cgContext
      ctx.setFillColor(labelColor.cgColor)
      ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))

      if isStreaming {
        // Stop: filled rounded square
        ctx.setFillColor(bgColor.cgColor)
        let squareSize = (size / 2) * 0.7
        let rect = CGRect(
          x: (size - squareSize) / 2,
          y: (size - squareSize) / 2,
          width: squareSize,
          height: squareSize
        )
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 2)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
      } else {
        // Send: arrow stroke
        ctx.setStrokeColor(bgColor.cgColor)
        ctx.setLineWidth(2.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let cx = size / 2
        let cy = size / 2
        let arrowSize = (size / 2) * 0.7

        ctx.move(to: CGPoint(x: cx, y: cy + arrowSize * 0.5))
        ctx.addLine(to: CGPoint(x: cx, y: cy - arrowSize * 0.5))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: cx - arrowSize * 0.5, y: cy - arrowSize * 0.1))
        ctx.addLine(to: CGPoint(x: cx, y: cy - arrowSize * 0.6))
        ctx.addLine(to: CGPoint(x: cx + arrowSize * 0.5, y: cy - arrowSize * 0.1))
        ctx.strokePath()
      }
    }

    sendButton.setImage(image.withRenderingMode(.alwaysOriginal), for: .normal)
    if isStreaming {
      sendButton.isEnabled = true
      sendButton.alpha = 1.0
    } else {
      updateSendButtonState()
    }
  }

  private func updateHeight() {
    let availableWidth = bounds.width > 0 ? bounds.width : 280
    let leftInset: CGFloat = showPTTButton ? (buttonPadding + buttonSize + 8) : 16
    let rightInset: CGFloat = buttonPadding + buttonSize + 4
    let textWidth = availableWidth - leftInset - rightInset
    
    let fittingSize = CGSize(
      width: textWidth,
      height: .greatestFiniteMagnitude
    )
    
    let size = textView.sizeThatFits(fittingSize)
    // Add padding for the text container
    let contentHeight = size.height + 16
    let newHeight = min(max(contentHeight, minHeight), maxHeight)
    
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

  private func updatePTTEnabledState() {
    pttButton.isEnabled = pttEnabled
    pttButton.alpha = pttEnabled ? 1.0 : 0.4
    if !pttEnabled && isPTTPressed {
      isPTTPressed = false
      pttButton.transform = .identity
    }
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

  // MARK: - Trait changes (for dark/light mode updates)
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
      // Update PTT button for new appearance
      updatePTTButtonAppearance()
    }
  }
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
