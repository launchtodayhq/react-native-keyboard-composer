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
    didSet {
      textView.isEditable = editable
      updateExpandedEditorButtonVisibility()
    }
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
      updateExpandedEditorButtonVisibility()
    }
  }

  // When enabled, shows an expand control once maxHeight is reached (iOS only).
  var expandedEditorEnabled: Bool = false {
    didSet {
      updateExpandedEditorButtonVisibility()
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
  private let expandButton = UIButton(type: .system)

  private var isExpandedEditorPresented: Bool = false
  private var expandedDraftText: String = ""
  private weak var expandedEditorNavigationController: UINavigationController?

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
    containerView.backgroundColor = .clear
    containerView.layer.cornerRadius = 0
    containerView.clipsToBounds = false

    addSubview(containerView)

    // TextView - configured for multiline auto-growing
    textView.delegate = self
    textView.font = .systemFont(ofSize: 16)
    textView.backgroundColor = .clear
    textView.textColor = .label
    // Leave room for the send button (bottom-right) and the expand button (top-right).
    textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
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

    // Expand-to-editor button (hidden unless enabled + at maxHeight)
    // Keep the tap target reasonable, but make the icon visually smaller.
    let expandConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    let expandImage = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: expandConfig)
    expandButton.setImage(expandImage, for: .normal)
    expandButton.tintColor = .label
    expandButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
    expandButton.isHidden = true
    expandButton.accessibilityLabel = "Expand editor"
    expandButton.addTarget(self, action: #selector(handleExpandPress), for: .touchUpInside)
    containerView.addSubview(expandButton)

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
    sendButton.layer.cornerRadius = buttonSize / 2
    sendButton.clipsToBounds = true

    let expandSize: CGFloat = 28
    let expandX = bounds.width - 36
    let expandY: CGFloat = 6
    expandButton.frame = CGRect(x: expandX, y: expandY, width: expandSize, height: expandSize)
    
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

  private func emitSend(text: String) {
    onSend([
      "text": text
    ])

    NotificationCenter.default.post(
      name: .keyboardComposerDidSend,
      object: self
    )
  }

  private func handleSend() {
    let currentText = textView.text ?? ""
    guard !currentText.isEmpty else { return }

    // Haptic feedback
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()

    emitSend(text: currentText)

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

  private func updateExpandedEditorButtonVisibility() {
    // Only show when content is tall enough to hit maxHeight. updateHeight() will compute exact visibility.
    // This method exists to react to prop changes without forcing a full re-measure.
    DispatchQueue.main.async { [weak self] in
      self?.updateHeight()
    }
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let current = responder {
      if let vc = current as? UIViewController {
        return vc
      }
      responder = current.next
    }
    return nil
  }

  @objc private func handleExpandPress() {
    guard expandedEditorEnabled, editable, !isStreaming else { return }
    guard !isExpandedEditorPresented else { return }
    guard let presenter = nearestViewController() else { return }

    isExpandedEditorPresented = true
    expandedDraftText = textView.text ?? ""
    textView.resignFirstResponder()

    let editor = ExpandedComposerViewController(initialText: expandedDraftText)
    editor.onTextChange = { [weak self] text in
      guard let self else { return }
      self.expandedDraftText = text
      self.onChangeText(["text": text])
    }
    editor.onDone = { [weak self] finalText in
      guard let self else { return }
      self.applyExpandedTextAndDismiss(finalText)
    }
    editor.onSend = { [weak self] sendText in
      guard let self else { return }
      self.handleExpandedSend(sendText)
    }

    let nav = UINavigationController(rootViewController: editor)
    nav.modalPresentationStyle = .pageSheet
    if #available(iOS 15.0, *) {
      if let sheet = nav.sheetPresentationController {
        sheet.detents = [.large()]
        sheet.prefersGrabberVisible = true
        sheet.preferredCornerRadius = 18
      }
    }
    nav.presentationController?.delegate = self
    expandedEditorNavigationController = nav
    presenter.present(nav, animated: true)
  }

  private func applyExpandedTextAndDismiss(_ finalText: String) {
    // Restore text into the composer.
    textView.text = finalText
    placeholderLabel.isHidden = !finalText.isEmpty
    updateHeight()
    updateSendButtonState()

    isExpandedEditorPresented = false
    expandedEditorNavigationController = nil
  }

  private func handleExpandedSend(_ sendText: String) {
    guard !sendText.isEmpty else { return }

    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()

    emitSend(text: sendText)

    // Clear composer text too.
    textView.text = ""
    expandedDraftText = ""
    placeholderLabel.isHidden = false
    onChangeText(["text": ""])
    updateHeight()
    updateSendButtonState()

    isExpandedEditorPresented = false
    expandedEditorNavigationController = nil
  }

  private func updateButtonAppearance() {
    let sendConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
    let stopConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    
    if isStreaming {
      let image = UIImage(systemName: "stop.fill", withConfiguration: stopConfig)
      sendButton.setImage(image, for: .normal)
      sendButton.tintColor = .white
      sendButton.backgroundColor = .black
      sendButton.contentEdgeInsets = UIEdgeInsets(top: 9, left: 9, bottom: 9, right: 9)
      sendButton.isEnabled = true
      sendButton.alpha = 1.0
    } else {
      let image = UIImage(systemName: "arrow.up.circle.fill", withConfiguration: sendConfig)
      sendButton.setImage(image, for: .normal)
      sendButton.tintColor = .label
      sendButton.backgroundColor = .clear
      sendButton.contentEdgeInsets = .zero
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

    let isAtMaxHeight = contentHeight >= (maxHeight - 0.5)
    let shouldShowExpand = expandedEditorEnabled && editable && !isStreaming && isAtMaxHeight
    expandButton.isHidden = !shouldShowExpand
    
    let shouldScroll = contentHeight > maxHeight
    if textView.isScrollEnabled != shouldScroll {
      textView.isScrollEnabled = shouldScroll
    }
    
    if abs(newHeight - currentHeight) > 0.5 {
      currentHeight = newHeight
      if !isExpandedEditorPresented {
        onHeightChange([
          "height": newHeight
        ])
      }
    }
  }

  private func updateSendButtonState() {
    if isStreaming {
      sendButton.isEnabled = true
      sendButton.alpha = 1.0
      return
    }
    let hasText = !textView.text.isEmpty
    sendButton.isEnabled = sendButtonEnabled && hasText
    sendButton.isHidden = !sendButtonEnabled
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

// MARK: - Expanded Editor

private final class ExpandedComposerViewController: UIViewController, UITextViewDelegate {
  var onTextChange: ((String) -> Void)?
  var onDone: ((String) -> Void)?
  var onSend: ((String) -> Void)?

  private let textView = UITextView()
  private let initialText: String

  init(initialText: String) {
    self.initialText = initialText
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    view.backgroundColor = .systemBackground
    navigationItem.title = "Edit"

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "Done",
      style: .done,
      target: self,
      action: #selector(handleDone)
    )

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Send",
      style: .done,
      target: self,
      action: #selector(handleSend)
    )

    textView.delegate = self
    textView.font = .systemFont(ofSize: 16)
    textView.backgroundColor = .clear
    textView.textColor = .label
    textView.text = initialText
    textView.alwaysBounceVertical = true
    textView.keyboardDismissMode = .interactive
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    view.addSubview(textView)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    textView.frame = view.bounds
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    textView.becomeFirstResponder()
  }

  func textViewDidChange(_ textView: UITextView) {
    onTextChange?(textView.text ?? "")
  }

  @objc private func handleDone() {
    onDone?(textView.text ?? "")
    dismiss(animated: true)
  }

  @objc private func handleSend() {
    onSend?(textView.text ?? "")
    dismiss(animated: true)
  }
}

extension KeyboardComposerView: UIAdaptivePresentationControllerDelegate {
  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    // User dismissed via swipe.
    guard isExpandedEditorPresented else { return }
    applyExpandedTextAndDismiss(expandedDraftText)
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
