import AVFoundation
import AppKit
import Carbon.HIToolbox

let configDir = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent(".config/koe")

func readConfig(_ name: String) -> String? {
  guard let s = try? String(contentsOf: configDir.appendingPathComponent(name), encoding: .utf8)
  else { return nil }
  return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

let apiKeyQuery: [String: Any] = [
  kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: "me.moriyuu.koe",
  kSecAttrAccount as String: "api_key",
]

func readAPIKey() -> String? {
  var query = apiKeyQuery
  query[kSecReturnData as String] = true
  var item: CFTypeRef?
  guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data
  else { return nil }
  return String(decoding: data, as: UTF8.self)
}

func saveAPIKey(_ key: String) -> OSStatus {
  SecItemDelete(apiKeyQuery as CFDictionary)
  var item = apiKeyQuery
  item[kSecValueData as String] = Data(key.utf8)
  return SecItemAdd(item as CFDictionary, nil)
}

// xAI STT の上限
let maxKeyterms = 100
let maxKeytermLength = 50

func parseKeyterms(_ s: String) -> [String] {
  s.split(separator: "\n")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}

func debugLog(_ message: String) {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("koe.log")
  let line = Data("\(Date()) \(message)\n".utf8)
  if let h = try? FileHandle(forWritingTo: url) {
    h.seekToEndOfFile()
    h.write(line)
    try? h.close()
  } else {
    try? line.write(to: url)
  }
}

func caretRect() -> NSRect? {
  guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
  let appElement = AXUIElementCreateApplication(app.processIdentifier)
  // Electron 製アプリはこれを立てないとアクセシビリティの情報を出さない
  AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

  func fail(_ step: String, _ err: AXError) -> NSRect? {
    debugLog("キャレットの位置が取れない: \(app.localizedName ?? "?") \(step) \(err.rawValue)")
    return nil
  }
  var focused: CFTypeRef?
  var err = AXUIElementCopyAttributeValue(
    appElement, kAXFocusedUIElementAttribute as CFString, &focused)
  guard err == .success, let focused else { return fail("focused", err) }
  let element = focused as! AXUIElement
  var range: CFTypeRef?
  err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range)
  guard err == .success, let range else { return fail("range", err) }
  var cfRange = CFRange()
  guard AXValueGetValue(range as! AXValue, .cfRange, &cfRange) else { return fail("range", .success) }

  func bounds(_ r: CFRange) -> CGRect? {
    var r = r
    guard let value = AXValueCreate(.cfRange, &r) else { return nil }
    var bounds: CFTypeRef?
    var rect = CGRect.zero
    guard
      AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &bounds) == .success,
      let bounds, AXValueGetValue(bounds as! AXValue, .cgRect, &rect), rect.height > 0
    else { return nil }
    return rect
  }
  func elementFrame() -> CGRect? {
    var pos: CFTypeRef?
    var size: CFTypeRef?
    var origin = CGPoint.zero
    var extent = CGSize.zero
    guard
      AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
      AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
      let pos, let size, AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
      AXValueGetValue(size as! AXValue, .cgSize, &extent)
    else { return nil }
    return CGRect(origin: origin, size: extent)
  }

  // テキストマーカーはページ全体（AXWebArea）が持っている
  func webArea() -> AXUIElement? {
    var current: AXUIElement? = element
    while let e = current {
      var role: CFTypeRef?
      AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
      if role as? String == "AXWebArea" { return e }
      var parent: CFTypeRef?
      guard AXUIElementCopyAttributeValue(e, kAXParentAttribute as CFString, &parent) == .success
      else { return nil }
      current = (parent as! AXUIElement)
    }
    return nil
  }
  func markerBounds() -> CGRect? {
    guard let web = webArea() else {
      debugLog("caret marker: AXWebArea なし")
      return nil
    }
    func param(_ attr: String, _ value: CFTypeRef) -> CFTypeRef? {
      var result: CFTypeRef?
      guard
        AXUIElementCopyParameterizedAttributeValue(web, attr as CFString, value, &result)
          == .success
      else { return nil }
      return result
    }
    func markerRect(_ range: CFTypeRef) -> CGRect? {
      var rect = CGRect.zero
      guard let b = param("AXBoundsForTextMarkerRange", range),
        AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.height > 0
      else { return nil }
      return rect
    }
    var selected: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(web, "AXSelectedTextMarkerRange" as CFString, &selected)
        == .success,
      let selected
    else {
      debugLog("caret marker: AXSelectedTextMarkerRange なし")
      return nil
    }
    // 長さ 0 の範囲だと入力欄全体の矩形を返すことがある
    if let r = markerRect(selected), r.width <= 1 { return r }
    guard CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID() else { return nil }
    let caret = AXTextMarkerRangeCopyStartMarker(selected as! AXTextMarkerRange)
    func charRect(_ a: CFTypeRef, _ b: CFTypeRef) -> CGRect? {
      guard let range = param("AXTextMarkerRangeForUnorderedTextMarkers", [a, b] as CFArray),
        let r = markerRect(range),
        // 改行は 1 文字でも行全体の矩形を返すので、1 文字分より広いものは使わない
        r.width <= r.height * 2
      else { return nil }
      return r
    }
    if let prev = param("AXPreviousTextMarkerForTextMarker", caret) {
      if let r = charRect(prev, caret) {
        return CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
      }
      // 空の行。手前の改行のさらに手前の文字（前の行の最後）の次の行に出す
      if let prev2 = param("AXPreviousTextMarkerForTextMarker", prev), let r = charRect(prev2, prev) {
        return CGRect(x: elementFrame()?.minX ?? r.minX, y: r.maxY, width: 0, height: r.height)
      }
    }
    if let next = param("AXNextTextMarkerForTextMarker", caret), let r = charRect(caret, next) {
      return CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
    }
    debugLog("caret marker: 前後の文字の矩形なし selected=\(String(describing: markerRect(selected)))")
    return nil
  }

  // Electron 製アプリは長さ 0 の範囲だと大きさ 0 の矩形を返すので、前後の 1 文字から位置を取る
  let loc = cfRange.location
  let rect: CGRect
  if let r = markerBounds() {
    rect = r
  } else if let r = bounds(cfRange) {
    rect = r
  } else if loc > 0, let r = bounds(CFRange(location: loc - 1, length: 1)) {
    rect = CGRect(x: r.maxX, y: r.minY, width: 0, height: r.height)
  } else if let r = bounds(CFRange(location: loc, length: 1)) {
    rect = CGRect(x: r.minX, y: r.minY, width: 0, height: r.height)
  } else if let r = elementFrame() {
    debugLog("キャレットの代わりに入力欄の左端を使う: \(app.localizedName ?? "?") range=\(cfRange) frame=\(r)")
    // 空の入力欄は文字の位置が取れないので、入力欄の左端に出す
    rect = CGRect(x: r.minX, y: r.minY, width: 0, height: min(r.height, 20))
  } else {
    return fail("bounds", .success)
  }
  // AX は左上原点、AppKit は左下原点
  let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
  return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
}

/// キャレットの右に録音中（赤い点）と文字起こし中（スピナー）を出す
final class CaretIndicator {
  let panel = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 16, height: 16),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
  let dot = NSView(frame: NSRect(x: 4, y: 4, width: 8, height: 8))
  let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 16, height: 16))

  init() {
    // 応答しないアプリに問い合わせるとメインスレッドが既定で 6 秒止まる
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    dot.wantsLayer = true
    dot.layer?.backgroundColor = NSColor.systemRed.cgColor
    dot.layer?.cornerRadius = 4
    spinner.style = .spinning
    spinner.controlSize = .small
    panel.contentView?.addSubview(dot)
    panel.contentView?.addSubview(spinner)
  }

  func showRecording() {
    guard let caret = caretRect() else { return }
    panel.setFrameOrigin(NSPoint(x: caret.maxX + 4, y: caret.midY - 8))
    dot.isHidden = false
    spinner.isHidden = true
    panel.orderFrontRegardless()
  }

  func showTranscribing() {
    dot.isHidden = true
    spinner.isHidden = false
    spinner.startAnimation(nil)
  }

  func hide() {
    spinner.stopAnimation(nil)
    panel.orderOut(nil)
  }
}

/// 辞書の入力中に語数を出し、上限を超えた行を赤くして保存できなくする
final class KeytermsValidator: NSObject, NSTextViewDelegate {
  let label = NSTextField(labelWithString: "")
  weak var saveButton: NSButton?

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    update(textView)
  }

  func update(_ textView: NSTextView) {
    guard let storage = textView.textStorage else { return }
    let text = storage.string as NSString
    let all = NSRange(location: 0, length: text.length)
    storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: all)
    var count = 0
    var tooLong = 0
    text.enumerateSubstrings(in: all, options: .byLines) { line, range, _, _ in
      let term = line?.trimmingCharacters(in: .whitespaces) ?? ""
      guard !term.isEmpty else { return }
      count += 1
      if term.count > maxKeytermLength { tooLong += 1 }
      if term.count > maxKeytermLength || count > maxKeyterms {
        storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
      }
    }
    var problems: [String] = []
    if count > maxKeyterms { problems.append("\(count - maxKeyterms)語多い") }
    if tooLong > 0 { problems.append("\(tooLong)語が\(maxKeytermLength)文字を超えている") }
    label.stringValue = (["\(count) / \(maxKeyterms)語"] + problems).joined(separator: "  ")
    label.textColor = problems.isEmpty ? .secondaryLabelColor : .systemRed
    saveButton?.isEnabled = problems.isEmpty
  }
}

final class App: NSObject, NSApplicationDelegate {
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("koe.m4a")
  var recorder: AVAudioRecorder?
  var startedAt = Date()
  let indicator = CaretIndicator()

  func applicationDidFinishLaunching(_ notification: Notification) {
    setIcon("mic")
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "録音 開始/停止", action: #selector(toggle), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "辞書を編集…", action: #selector(editKeyterms), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "API キーを設定…", action: #selector(editAPIKey), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "設定フォルダを開く", action: #selector(openConfig), keyEquivalent: ""))
    menu.items.forEach { $0.target = self }
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    item.menu = menu

    // メインメニューがないとテキスト欄で ⌘C / ⌘V が効かない
    let edit = NSMenu()
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    let editItem = NSMenuItem()
    editItem.submenu = edit
    NSApp.mainMenu = NSMenu()
    NSApp.mainMenu?.addItem(editItem)

    watchFnKey()
    AVCaptureDevice.requestAccess(for: .audio) { _ in }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
  }

  func watchFnKey() {
    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { e in
      e.modifierFlags.contains(.function) ? self.start() : self.stop()
    }
    // fn+矢印などのショートカット中は録音を捨てる
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in self.cancel() }
  }

  @objc func toggle() {
    recorder == nil ? start() : stop()
  }

  func start() {
    guard recorder == nil else { return }
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
    ]
    guard let r = try? AVAudioRecorder(url: audioURL, settings: settings), r.record() else {
      fail("録音を開始できません（マイクの許可を確認）")
      return
    }
    recorder = r
    NSSound(named: "Morse")?.play()
    startedAt = Date()
    setIcon("mic.fill")
    indicator.showRecording()
  }

  func stop() {
    guard let r = recorder else { return }
    // fn を軽く押しただけのときは API を呼ばない
    if Date().timeIntervalSince(startedAt) < 0.3 { return cancel() }
    recorder = nil
    setIcon("ellipsis")
    indicator.showTranscribing()
    // 離すのと同時に話し終えると語尾が切れるので少し録り足す
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      r.stop()
      NSSound(named: "Frog")?.play()
      self.transcribe()
    }
  }

  func cancel() {
    recorder?.stop()
    recorder = nil
    setIcon("mic")
    indicator.hide()
  }

  func transcribe() {
    guard let key = readAPIKey(), !key.isEmpty else {
      fail("API キーが未設定です（メニューの「API キーを設定…」）")
      return
    }
    guard let audio = try? Data(contentsOf: audioURL) else {
      fail("録音ファイルを読めません")
      return
    }
    let boundary = UUID().uuidString
    var body = Data()
    func field(_ name: String, _ value: String) {
      body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }
    field("model", "grok-voice-transcribe-2.0")
    field("language", "ja")
    // true にすると「一旦」→「1旦」、「しませんか」→「しま1000か」のように数字でない語まで数字になる
    field("format", "false")
    // 既定の 0.5 だと短い発話や小さい声が無音扱いで消える
    field("vad_threshold", "0.2")
    // 上限を超えると API がエラーを返すので、手で編集されたファイルでも超えないようにする
    parseKeyterms(readConfig("keyterms.txt") ?? "")
      .filter { $0.count <= maxKeytermLength }
      .prefix(maxKeyterms)
      .forEach { field("keyterm", $0) }
    // file は最後のフィールドでないと他のフィールドが無視されることがある
    body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
    body.append(audio)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))

    var req = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body

    URLSession.shared.dataTask(with: req) { data, res, err in
      DispatchQueue.main.async {
        guard let data, let http = res as? HTTPURLResponse else {
          self.fail("通信エラー: \(err?.localizedDescription ?? "unknown")")
          return
        }
        guard http.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let text = json["text"] as? String
        else {
          self.fail("API エラー \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
          return
        }
        debugLog("trusted=\(AXIsProcessTrusted()) text=\(text)")
        self.indicator.hide()
        if !text.isEmpty { self.paste(text) }
        self.setIcon("mic")
      }
    }.resume()
  }

  func paste(_ text: String) {
    let pb = NSPasteboard.general
    let previous = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
      e?.flags = .maskCommand
      e?.post(tap: .cghidEventTap)
    }
    // ponytail: 文字列だけ復元する。画像などをコピーしていた場合は消える
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      guard let previous else { return }
      pb.clearContents()
      pb.setString(previous, forType: .string)
    }
  }

  @objc func editKeyterms() {
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = NSRect(x: 0, y: 24, width: 300, height: 200)
    let textView = scroll.documentView as! NSTextView
    textView.font = .systemFont(ofSize: 13)
    textView.string = readConfig("keyterms.txt") ?? ""

    let validator = KeytermsValidator()
    validator.label.frame = NSRect(x: 0, y: 0, width: 300, height: 18)
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 224))
    accessory.addSubview(scroll)
    accessory.addSubview(validator.label)

    let alert = NSAlert()
    alert.messageText = "辞書"
    alert.informativeText = "認識させたい言葉を1行に1つ（\(maxKeyterms)語まで、1語\(maxKeytermLength)文字まで）"
    alert.accessoryView = accessory
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "キャンセル")
    alert.window.initialFirstResponder = textView
    validator.saveButton = alert.buttons.first
    textView.delegate = validator
    validator.update(textView)
    NSApp.activate(ignoringOtherApps: true)

    // textView.delegate は weak なので、モーダルの間 validator を生かしておく
    let response = withExtendedLifetime(validator) { alert.runModal() }
    guard response == .alertFirstButtonReturn else { return }
    do {
      try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
      try (parseKeyterms(textView.string).joined(separator: "\n") + "\n").write(
        to: configDir.appendingPathComponent("keyterms.txt"), atomically: true, encoding: .utf8)
    } catch {
      fail("辞書を保存できません: \(error.localizedDescription)")
    }
  }

  @objc func editAPIKey() {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    field.placeholderString = readAPIKey() == nil ? "xai-..." : "設定済み（変えるときだけ入力）"
    let alert = NSAlert()
    alert.messageText = "xAI の API キー"
    alert.informativeText = "キーチェーンに保存します"
    alert.accessoryView = field
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "キャンセル")
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !input.isEmpty else { return }
    let status = saveAPIKey(input)
    if status != errSecSuccess { fail("API キーを保存できません: \(status)") }
  }

  @objc func openConfig() {
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    NSWorkspace.shared.open(configDir)
  }

  func setIcon(_ symbol: String) {
    item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    item.button?.toolTip = nil
  }

  func fail(_ message: String) {
    debugLog(message)
    indicator.hide()
    setIcon("exclamationmark.triangle")
    item.button?.toolTip = message
  }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
