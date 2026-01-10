//
//  KeyboardViewController.swift
//  Dkeys2
//
//  Created by Sambath Kumar Logakrishnan on 18/10/2025.
//

import UIKit
import SwiftUI
import Combine

// MARK: - Grammar Check Models
struct GrammarCorrection: Codable, Identifiable {
    let id = UUID()
    var location: CorrectionLocation
    let oldText: String
    let newText: String
    let explanation: String
    
    enum CodingKeys: String, CodingKey {
        case location, oldText, newText, explanation
    }
}

struct CorrectionLocation: Codable {
    var start: Int
    var end: Int
}

struct GrammarCheckResponse: Codable {
    let corrections: [GrammarCorrection]
    let count: Int
}

class TextDocumentProxyWrapper: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    
    weak var proxy: UITextDocumentProxy?
    // suggestions that the toolbar will present
    var suggestions: [String] = []

    // Added initializer to allow injecting a proxy at creation time
    init(proxy: UITextDocumentProxy? = nil) {
        self.proxy = proxy
    }

    func insertText(_ text: String, updateSuggestions: Bool = true) {
        proxy?.insertText(text)
        // Update suggestions after typing
        if(updateSuggestions){
            updateSuggestionsFromContext()
        }
    }
    
    func deleteBackwardWord(){
        guard let proxy = proxy else { return }
        if let context = proxy.documentContextBeforeInput, !context.isEmpty {
            // Extract last token (word) from context
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            let parts = context.components(separatedBy: separators).filter { !$0.isEmpty }
            if let last = parts.last {
                for _ in 0..<last.count {
                    proxy.deleteBackward()
                }}
        }
    }
    
    func deleteBackward() {
        proxy?.deleteBackward()
        // Update suggestions after deleting
        updateSuggestionsFromContext()
    }

    // Compute Levenshtein edit distance (small helper)
    private func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a.lowercased())
        let bChars = Array(b.lowercased())
        let n = aChars.count
        let m = bChars.count
        if n == 0 { return m }
        if m == 0 { return n }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                if aChars[i - 1] == bChars[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = min(dp[i - 1][j - 1] + 1, min(dp[i - 1][j] + 1, dp[i][j - 1] + 1))
                }
            }
        }
        return dp[n][m]
    }

    // Update suggestions by looking at the current partial word before the cursor
    func updateSuggestionsFromContext() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let context = self.proxy?.documentContextBeforeInput, !context.isEmpty else {
                if self?.suggestions.isEmpty == false {
                    self?.suggestions = []
                    self?.objectWillChange.send()
                }
                return
            }

            // Extract last token (partial word) from context
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            let parts = context.components(separatedBy: separators).filter { !$0.isEmpty }
            guard let last = parts.last, !last.isEmpty else {
                if self.suggestions.isEmpty == false {
                    self.suggestions = []
                    self.objectWillChange.send()
                }
                return
            }

            let lastLower = last.lowercased()

            // Use UITextChecker to get completions for the partial word (English)
            let checker = UITextChecker()
            let nsLast = last as NSString
            let range = NSRange(location: 0, length: nsLast.length)
            var foundSuggestions: [String] = []

            if let completions = checker.completions(forPartialWordRange: range, in: last, language: "en_US") {
                foundSuggestions = completions
            }

            // If completions empty, try guesses (corrections) as fallback
            if foundSuggestions.isEmpty {
                if let guesses = checker.guesses(forWordRange: range, in: last, language: "en_US") {
                    foundSuggestions = guesses
                }
            }

            // Normalize, filter duplicates and the exact match
            var normalized: [String] = []
            for s in foundSuggestions {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed.lowercased() == lastLower { continue }
                if !normalized.contains(trimmed) { normalized.append(trimmed) }
            }

            // If nothing found, clear suggestions
            if normalized.isEmpty {
                if self.suggestions.isEmpty == false {
                    self.suggestions = []
                    self.objectWillChange.send()
                }
                return
            }

            // Score candidates: prefer prefix matches, then by edit distance to the partial word
            let scored = normalized.map { candidate -> (String, Bool, Int) in
                let isPrefix = candidate.lowercased().hasPrefix(lastLower)
                let dist = self.editDistance(candidate, last)
                return (candidate, isPrefix, dist)
            }

            let sorted = scored.sorted { a, b in
                if a.1 != b.1 { return a.1 && !b.1 } // prefix matches first
                if a.2 != b.2 { return a.2 < b.2 } // then smaller distance
                return a.0.count < b.0.count // shorter word as tiebreaker
            }

            let top = Array(sorted.prefix(3)).map { $0.0 }
            self.suggestions = top
            self.objectWillChange.send()
        }
    }

    // Grammar corrections from API
    @Published var grammarCorrections: [GrammarCorrection] = []
    @Published var showGrammarCanvas = false
    @Published var isLoadingGrammar = false
    
    // Perform grammar check using the API endpoint
    func performGrammarCheck() {
        guard let proxy = proxy else { return }
        
        // Get the text context to check
        let contextBefore = proxy.documentContextBeforeInput ?? ""
        let contextAfter = proxy.documentContextAfterInput ?? ""
        let fullText = contextBefore + contextAfter
        
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        isLoadingGrammar = true
        objectWillChange.send()
        
        // Create the API request
        guard let url = URL(string: "http://80.68.231.165:3000/grammar/fix") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["text": fullText]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            isLoadingGrammar = false
            objectWillChange.send()
            return
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoadingGrammar = false
                
                guard let data = data, error == nil else {
                    self?.objectWillChange.send()
                    return
                }
                
                do {
                    let result = try JSONDecoder().decode(GrammarCheckResponse.self, from: data)
                    self?.grammarCorrections = result.corrections
                    self?.showGrammarCanvas = !result.corrections.isEmpty
                    self?.objectWillChange.send()
                } catch {
                    print("Failed to decode grammar response: \(error)")
                    self?.objectWillChange.send()
                }
            }
        }.resume()
    }

    // Placeholder: populate rephrase suggestions (keeps an explicit action; uses a simple fallback)
    func performRephrase() {
        // Simple placeholder rephrases based on the last sentence. Replace with a backend/model.
        // For now call updateSuggestionsFromContext as a fallback to produce something sensible.
        updateSuggestionsFromContext()
    }

    // Optionally clear suggestions
    func clearSuggestions() {
        self.suggestions = []
        objectWillChange.send()
    }
}

// Small reusable key view now implemented as a SwiftUI View
struct DButton: View {
    let key: String
    let action: (String) -> Void

    var body: some View {
        Button(action: { action(key) }) {
            Text(key)
                .frame(width: 34, height: 44)
                .font(Font.system(size: 20, design: .default))
                .fontWeight(Font.Weight.semibold)
                .fontWidth(Font.Width.standard)
                .foregroundColor(Color(UIColor.black))
                .background(Color.white.opacity(0.9))
                .cornerRadius(8)
        }
    }
}

// KeySpec allows either simple string keys or keys with a custom action
struct KeySpec {
    let text: String
    // optional per-button action; if nil, the row's shared action is used
    let btAction: ((String) -> Void)?

    init(_ text: String, btAction: ((String) -> Void)? = nil) {
        self.text = text
        self.btAction = btAction
    }
}

struct KeyboardRow: View {
    // Internal storage as KeySpec; provide initializers for convenience
    let items: [KeySpec]
    let rowAction: ((String) -> Void)?

    init(keys: [String], action: @escaping (String) -> Void) {
        self.items = keys.map { KeySpec($0) }
        self.rowAction = action
    }

    // Accept items with an optional fallback action. This lets callers pass
    // either `[String]` via `init(keys:action:)` or `[KeySpec]` via this initializer.
    init(items: [KeySpec], action: ((String) -> Void)? = nil) {
        self.items = items
        self.rowAction = action
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.text) { item in
                // choose per-key action if provided, otherwise use rowAction
                let handler: (String) -> Void = item.btAction ?? rowAction ?? { _ in }
                DButton(key: item.text, action: handler)
            }
        }
    }
}

// New: KeyboardRow with a trailing delete button (used on numbers/symbol pages)
struct KeyboardRowWithDelete: View {
    let keys: [String]
    let action: (String) -> Void
    let deleteAction: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Button(action: { action(key) }) {
                    Text(key)
                        .frame(width: 34, height: 44)
                        .font(Font.system(size: 20, design: .default))
                        .fontWeight(Font.Weight.semibold)
                        .foregroundColor(Color(UIColor.black))
                        .background(Color.white.opacity(0.9))
                        .cornerRadius(8)
                }
            }
            Button(action: deleteAction) {
                Image(systemName: "delete.left")
                    .frame(width: 34, height: 44)
                    .background(Color.white.opacity(0.9))
                    .cornerRadius(8)
            }
        }
    }
}

struct SuggestionChip: View {
    let text: String
    let action: (String) -> Void
    var body: some View {
        Button(action: { action(text) }) {
            Text(text)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white)
                .foregroundColor(.black)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

struct EnglishKeyboardView: View {
    @ObservedObject var proxyWrapper: TextDocumentProxyWrapper
    @State private var isUppercase = false
    @State private var showNumbers = false
    @State private var showSymbols = false
    @State private var isCapsLock = false
    @State private var showEmoji = false

    let lettersRows = [
        ["Q","W","E","R","T","Y","U","I","O","P"],
        ["A","S","D","F","G","H","J","K","L"],
       // ["Z","X","C","V","B","N","M"]
    ]
    let numbersRow = ["1","2","3","4","5","6","7","8","9","0"]
    // Rows requested by user for the numeric keyboard
    let numbersSecondRow = ["-","/",":",";","(",")","$","&","@","\""]
    let numbersThirdRow = ["#+=",".",",","?","!","'"]

    // Symbol keyboard: rest of special characters split into three rows
    let symbolsRow1 = ["[","]","{","}","|","\\","<",">","/","="]
    let symbolsRow2 = ["_","-","+","*","^","%","$","&","@","#"]
    let symbolsRow3 = ["123",".",",","?","!","'"]

    var body: some View {
        VStack(spacing: 6) {
            // Top toolbar: grammar button (left), suggestions (center), rephrase (right)
            HStack(spacing: 8) {
                Button(action: {
                    proxyWrapper.performGrammarCheck()
                }) {
                    Image(systemName: "service.dog.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(Color(UIColor.darkGray))
                        .frame(width: 30, height: 30)
                }
                .background(Color(UIColor.systemGray5))
                .cornerRadius(8)

                // Suggestions scroll area
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if proxyWrapper.suggestions.isEmpty {
                            Text("Suggestions")
                                .foregroundColor(Color.gray)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(Color(UIColor.systemGray6))
                                .cornerRadius(12)
                        } else {
                            ForEach(proxyWrapper.suggestions, id: \.self) { suggestion in
                                SuggestionChip(text: suggestion) { text in
                                    proxyWrapper.deleteBackwardWord()
                                    // Insert suggestion and then clear suggestions
                                    proxyWrapper.insertText(text + " ", updateSuggestions: false)
                                    proxyWrapper.clearSuggestions()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }

                Button(action: {
                    proxyWrapper.performRephrase()
                }) {
                    Image(systemName: "text.badge.star")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 30, height: 30)
                        .foregroundColor(Color(UIColor.darkGray))
                }
                .background(Color(UIColor.systemGray5))
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 0)
            .background(Color(UIColor.systemGray5))
            
            if(showEmoji){
                EmojiKeyboardView(proxyWrapper: proxyWrapper, onClose: {
                    showEmoji = false
                })
            }
            else if showNumbers {
                // Split numeric/symbol pages: numbers page vs symbol page
                if showSymbols {
                    // Symbol page (three rows) - the third row's first button switches back to numbers
                    KeyboardRow(keys: symbolsRow1, action: insertText)
                    KeyboardRow(keys: symbolsRow2, action: insertText)
                    
                    // Third row: first button = switch to numbers, others insert text
                    HStack(spacing: 4) {
                        Button(action: { showNumbers = true; showSymbols = false }) {
                            Text("123")
                                .frame(width: 48, height: 44)
                                .font(Font.system(size: 20, design: .default))
                                .fontWeight(Font.Weight.semibold)
                                .fontWidth(Font.Width.standard)
                                .foregroundColor(Color(UIColor.black))
                                .background(Color.white.opacity(0.9))
                                .cornerRadius(8)
                        }
                        Spacer()
                        ForEach(symbolsRow3.dropFirst(), id: \.self) { key in
                            Button(action: { insertText(key) }) {
                                Text(key)
                                    .frame(width: 44, height: 44)
                                    .font(Font.system(size: 20, design: .default))
                                    .fontWeight(Font.Weight.semibold)
                                    .fontWidth(Font.Width.standard)
                                    .foregroundColor(Color(UIColor.black))
                                    .background(Color.white.opacity(0.9))
                                    .cornerRadius(8)
                            }
                        }
                        Spacer()
                        // Delete as last button on third row
                        Button(action: { proxyWrapper.deleteBackward() }) {
                            Image(systemName: "delete.left")
                                .frame(width: 48, height: 44)
                                .font(Font.system(size: 20, design: .default))
                                .fontWeight(Font.Weight.semibold)
                                .fontWidth(Font.Width.standard)
                                .foregroundColor(Color(UIColor.black))
                                .background(Color.white.opacity(0.9))
                                .cornerRadius(8)
                        }
                    }
                 } else {
                     // Numbers page (exact rows requested)
                     KeyboardRow(keys: numbersRow, action: insertText)
                     KeyboardRow(keys: numbersSecondRow, action: insertText)
                     
                     
                     // Third row: first button toggles to symbols (#+=), others insert punctuation
                     HStack(spacing: 4) {
                        Button(action: { showSymbols = true }) {
                            Text("#+=")
                                .frame(width: 48, height: 44)
                                .font(Font.system(size: 20, design: .default))
                                .fontWeight(Font.Weight.semibold)
                                .fontWidth(Font.Width.standard)
                                .foregroundColor(Color(UIColor.black))
                                .background(Color.white.opacity(0.9))
                                .cornerRadius(8)
                        }
                         Spacer()
                         ForEach(numbersThirdRow.dropFirst(), id: \.self) { key in
                             Button(action: { insertText(key) }) {
                                 Text(key)
                                     .frame(width: 44, height: 44)
                                     .font(Font.system(size: 20, design: .default))
                                     .fontWeight(Font.Weight.semibold)
                                     .fontWidth(Font.Width.standard)
                                     .foregroundColor(Color(UIColor.black))
                                     .background(Color.white.opacity(0.9))
                                     .cornerRadius(8)
                             }
                         }
                    
                       
                        Spacer()
                        // Delete as last button on third row
                        Button(action: { proxyWrapper.deleteBackward() }) {
                            Image(systemName: "delete.left")
                                .frame(width: 48, height: 44)
                                .font(Font.system(size: 20, design: .default))
                                .fontWeight(Font.Weight.semibold)
                                .fontWidth(Font.Width.standard)
                                .foregroundColor(Color(UIColor.black))
                                .background(Color.white.opacity(0.9))
                                .cornerRadius(8)
                        }
                    }
                 }
             } else {
                ForEach(0..<lettersRows.count, id: \.self) { i in
                    KeyboardRow(keys: isUppercase ? lettersRows[i].map { $0.uppercased() } : lettersRows[i].map { $0.lowercased() }, action: insertText)
                }
                HStack(spacing: 4) {
                    // Shift / Caps Lock: single-tap toggles shift, double-tap toggles caps lock
                    Group {
                        let doubleTap = TapGesture(count: 2).onEnded {
                            // Toggle caps lock
                            isCapsLock.toggle()
                            isUppercase = isCapsLock
                        }
                        let singleTap = TapGesture(count: 1).onEnded {
                            // Single tap: toggle shift for the next letter (unless caps lock is active)
                            if isCapsLock {
                                // If caps lock is active, a single tap should turn it off
                                isCapsLock = false
                                isUppercase = false
                            } else {
                                isUppercase.toggle()
                            }
                        }

                        // Use ExclusiveGesture so double-tap takes precedence over single-tap
                        Image(systemName: isCapsLock ? "capslock.fill" : "capslock")
                             .frame(width: 32, height: 44)
                             .contentShape(Rectangle())
                             .gesture(ExclusiveGesture(doubleTap, singleTap))
                             .accessibility(label: Text(isCapsLock ? "Caps Lock" : "Shift"))
                     }
                      KeyboardRow(keys: isUppercase ? ["Z","X","C","V","B","N","M"] : ["z","x","c","v","b","n","m"], action: insertText)
                      Button(action: { proxyWrapper.deleteBackward() }) {
                          Image(systemName: "delete.left")
                              .frame(width: 32, height: 44)
                      }
                  }
              }
             HStack(spacing: 4) {
                 if(showEmoji == false){
                     // Left-side toggles: when not showing numbers, show a 123 button to enter numbers page.
                     // When in numbers page, provide both an ABC button (to go back to letters) and a #+= / 123 toggle.
                     if showNumbers {
                         Button(action: { showNumbers = false; showSymbols = false }) {
                             Text("ABC")
                                 .frame(width: 50, height: 44)
                                 .background(Color.gray.opacity(0.2))
                                 .cornerRadius(8)
                         }
                         Button(action: { showEmoji = true }) {
                             Image(systemName: "face.smiling")
                         }
                     } else {
                         Button(action: { showNumbers = true; showSymbols = false }) {
                             Text("123")
                                 .frame(width: 50, height: 44)
                                 .background(Color.gray.opacity(0.2))
                                 .cornerRadius(8)
                         }
                         Button(action: { showEmoji = true }) {
                             Image(systemName: "face.smiling")
                         }
                     }
                     
                     Button(action: { proxyWrapper.insertText(" ") }) {
                         Text("space")
                             .frame(minWidth: 120, maxWidth: .infinity, minHeight: 44)
                             .background(Color.gray.opacity(0.2))
                             .cornerRadius(8)
                     }
                     Button(action: { proxyWrapper.insertText("\n") }) {
                         Text("return")
                             .frame(width: 70, height: 44)
                             .background(Color.blue.opacity(0.8))
                             .foregroundColor(.white)
                             .cornerRadius(8)
                     }
                 }
             }
         }
         .padding(8)
         .background(Color(UIColor.systemGray5))
         .overlay(
             // Grammar Canvas Overlay
             Group {
                 if proxyWrapper.showGrammarCanvas {
                     GrammarCanvasView(proxyWrapper: proxyWrapper)
                 }
             }
         )
         .overlay(
             // Loading indicator for grammar check
             Group {
                 if proxyWrapper.isLoadingGrammar {
                     ZStack {
                         Color.black.opacity(0.3)
                             .edgesIgnoringSafeArea(.all)
                         
                         VStack {
                             ProgressView()
                                 .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                 .scaleEffect(1.2)
                             
                             Text("Checking grammar...")
                                 .foregroundColor(.white)
                                 .font(.caption)
                                 .padding(.top, 8)
                         }
                         .padding()
                         .background(Color.black.opacity(0.7))
                         .cornerRadius(12)
                     }
                 }
             }
         )
         
     }

     func insertText(_ text: String) {
         proxyWrapper.insertText(text)
         // If caps lock isn't enabled, reset single-shift after inserting a letter
         if isUppercase && !showNumbers && !isCapsLock {
             isUppercase = false
         }
     }
 }



 class KeyboardViewController: UIInputViewController {

    @IBOutlet var nextKeyboardButton: UIButton!
    // Hosting controller for the SwiftUI keyboard view
    private var keyboardHostingController: UIHostingController<EnglishKeyboardView>?
    // Keep a strong reference to the wrapper so we can update its `proxy` later
    private var proxyWrapper: TextDocumentProxyWrapper?
    
    override func updateViewConstraints() {
        super.updateViewConstraints()
        
        // Add custom view sizing constraints here
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Create a wrapper bound to the system textDocumentProxy and host the SwiftUI keyboard view
        self.proxyWrapper = TextDocumentProxyWrapper(proxy: self.textDocumentProxy)
        guard let wrapper = self.proxyWrapper else { return }
        let host = UIHostingController(rootView: EnglishKeyboardView(proxyWrapper: wrapper))
        self.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
        self.keyboardHostingController = host
        
        // Perform custom UI setup here
        self.nextKeyboardButton = UIButton(type: .system)
        
        self.nextKeyboardButton.setTitle(NSLocalizedString("Next Keyboard", comment: "Title for 'Next Keyboard' button"), for: [])
        self.nextKeyboardButton.sizeToFit()
        self.nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false
        
        self.nextKeyboardButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        
        self.view.addSubview(self.nextKeyboardButton)
        
        // Layout: host view fills the controller's view; nextKeyboardButton is anchored to bottom-left
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.leftAnchor.constraint(equalTo: self.view.leftAnchor),
            host.view.rightAnchor.constraint(equalTo: self.view.rightAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            self.nextKeyboardButton.leftAnchor.constraint(equalTo: self.view.leftAnchor),
            self.nextKeyboardButton.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])

        // Ensure the system keyboard switch button stays on top of the hosted SwiftUI view
        self.view.bringSubviewToFront(self.nextKeyboardButton)
    }

    override func viewWillLayoutSubviews() {
        self.nextKeyboardButton.isHidden = !self.needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    override func textWillChange(_ textInput: UITextInput?) {
        // The app is about to change the document's contents. Perform any preparation here.
    }
    
    override func textDidChange(_ textInput: UITextInput?) {
        // The app has just changed the document's contents, the document context has been updated.
        
        // Update wrapper's proxy to ensure it points to the current system proxy
        self.proxyWrapper?.proxy = self.textDocumentProxy
        
        var textColor: UIColor
        let proxy = self.textDocumentProxy
        if proxy.keyboardAppearance == UIKeyboardAppearance.dark {
            textColor = UIColor.white
        } else {
            textColor = UIColor.black
        }
        self.nextKeyboardButton.setTitleColor(textColor, for: [])
        
        // Also update suggestions to reflect the current context
        self.proxyWrapper?.updateSuggestionsFromContext()
    }
}

// MARK: - Grammar Canvas View
struct GrammarCanvasView: View {
    @ObservedObject var proxyWrapper: TextDocumentProxyWrapper
    
    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    proxyWrapper.showGrammarCanvas = false
                }
            
            // Canvas card
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Grammar Check")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button("Done") {
                        proxyWrapper.showGrammarCanvas = false
                    }
                    .foregroundColor(.blue)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                Divider()
                
                // Corrections list
                if proxyWrapper.isLoadingGrammar {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Checking grammar...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if proxyWrapper.grammarCorrections.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No grammar issues found!")
                            .font(.title3)
                            .fontWeight(.medium)
                        Text("Your text looks good.")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(proxyWrapper.grammarCorrections) { correction in
                                CorrectionCardView(
                                    correction: correction,
                                    onApply: { appliedCorrection in
                                        applyCorrection(appliedCorrection)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .background(Color(UIColor.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 20)
            .padding(.vertical, 40)
        }
    }
    
    private func applyCorrection(_ correction: GrammarCorrection) {
        // Get current text context
        guard let proxy = proxyWrapper.proxy else { return }
        
        // Get the current full text to work with
        let contextBefore = proxy.documentContextBeforeInput ?? ""
        let contextAfter = proxy.documentContextAfterInput ?? ""
        let currentFullText = contextBefore + contextAfter
        
        // Apply the correction with proper position tracking
        let success = replaceTextAtPosition(
            fullText: currentFullText,
            correction: correction,
            proxy: proxy
        )
        
        if success {
            // Calculate the length change from this correction
            let lengthChange = correction.newText.count - correction.oldText.count
            
            // Update positions of all remaining corrections that come after this one
            for i in 0..<proxyWrapper.grammarCorrections.count {
                let otherCorrection = proxyWrapper.grammarCorrections[i]
                
                // Skip the correction we just applied
                if otherCorrection.id == correction.id { continue }
                
                // If the other correction starts after the end of this correction,
                // adjust its position by the length change
                if otherCorrection.location.start >= correction.location.end {
                    proxyWrapper.grammarCorrections[i].location.start += lengthChange
                    proxyWrapper.grammarCorrections[i].location.end += lengthChange
                }
                // If the other correction overlaps with this one, it may need special handling
                else if otherCorrection.location.start < correction.location.end &&
                        otherCorrection.location.end > correction.location.start {
                    // Mark overlapping corrections for removal or special handling
                    print("Warning: Overlapping correction detected for '\(otherCorrection.oldText)'")
                }
            }
            
            // Remove the applied correction from the list
            proxyWrapper.grammarCorrections.removeAll { $0.id == correction.id }
        } else {
            print("Failed to apply correction for '\(correction.oldText)'")
        }
        
        // Close canvas if no more corrections
        if proxyWrapper.grammarCorrections.isEmpty {
            proxyWrapper.showGrammarCanvas = false
        }
        
        proxyWrapper.objectWillChange.send()
    }
    
    private func replaceTextAtPosition(fullText: String, correction: GrammarCorrection, proxy: UITextDocumentProxy) -> Bool {
        // Validate correction bounds
        guard correction.location.start >= 0,
              correction.location.end <= fullText.count,
              correction.location.start < correction.location.end else {
            print("Invalid correction bounds: start=\(correction.location.start), end=\(correction.location.end), textLength=\(fullText.count)")
            return false
        }
        
        // Extract the text at the specified location
        let startIndex = fullText.index(fullText.startIndex, offsetBy: correction.location.start)
        let endIndex = fullText.index(fullText.startIndex, offsetBy: correction.location.end)
        let textAtLocation = String(fullText[startIndex..<endIndex])
        
        // Verify it matches what we expect
        guard textAtLocation == correction.oldText else {
            print("Text mismatch at location - expected: '\(correction.oldText)', found: '\(textAtLocation)'")
            // Try fallback search-based replacement
            return searchAndReplaceText(oldText: correction.oldText, newText: correction.newText, proxy: proxy)
        }
        
        // Calculate current cursor position
        let contextBefore = proxy.documentContextBeforeInput ?? ""
        let currentCursorPosition = contextBefore.count
        
        // Now perform the replacement based on where the error is relative to cursor
        if correction.location.end <= currentCursorPosition {
            // Error is entirely before the cursor
            return replaceTextBeforeCursor(correction: correction, cursorPosition: currentCursorPosition, proxy: proxy)
        } else if correction.location.start >= currentCursorPosition {
            // Error is entirely after the cursor
            return replaceTextAfterCursor(correction: correction, cursorPosition: currentCursorPosition, proxy: proxy)
        } else {
            // Error spans the cursor position
            return replaceTextSpanningCursor(correction: correction, cursorPosition: currentCursorPosition, proxy: proxy)
        }
    }
    
    private func replaceTextBeforeCursor(correction: GrammarCorrection, cursorPosition: Int, proxy: UITextDocumentProxy) -> Bool {
        // Move cursor back to the end of the error text
        let moveBackDistance = cursorPosition - correction.location.end
        
        // Use deleteBackward to move back and delete
        let totalDeleteCount = moveBackDistance + correction.oldText.count
        for _ in 0..<totalDeleteCount {
            proxy.deleteBackward()
        }
        
        // Insert the corrected text
        proxy.insertText(correction.newText)
        return true
    }
    
    private func replaceTextAfterCursor(correction: GrammarCorrection, cursorPosition: Int, proxy: UITextDocumentProxy) -> Bool {
        // For text after cursor, we have limited options with UITextDocumentProxy
        // Use a safer approach - try to select and replace if possible
        
        // Calculate how far forward the error is
        let moveForwardDistance = correction.location.start - cursorPosition
        
        // We can't easily move forward in UITextDocumentProxy, so use search-based fallback
        return searchAndReplaceText(oldText: correction.oldText, newText: correction.newText, proxy: proxy)
    }
    
    private func replaceTextSpanningCursor(correction: GrammarCorrection, cursorPosition: Int, proxy: UITextDocumentProxy) -> Bool {
        // Delete backwards to the start of the error
        let deleteBackCount = cursorPosition - correction.location.start
        for _ in 0..<deleteBackCount {
            proxy.deleteBackward()
        }
        
        // Calculate remaining characters to delete (after cursor position)
        let remainingDeleteCount = correction.location.end - cursorPosition
        for _ in 0..<remainingDeleteCount {
            proxy.deleteBackward()
        }
        
        // Insert the corrected text
        proxy.insertText(correction.newText)
        return true
    }
    
    private func searchAndReplaceText(oldText: String, newText: String, proxy: UITextDocumentProxy) -> Bool {
        // Fallback method using text search
        let contextBefore = proxy.documentContextBeforeInput ?? ""
        
        // Look for exact suffix match (most reliable)
        if contextBefore.hasSuffix(oldText) {
            for _ in 0..<oldText.count {
                proxy.deleteBackward()
            }
            proxy.insertText(newText)
            return true
        }
        
        // Look for the text anywhere in the context before cursor
        if let range = contextBefore.range(of: oldText, options: .backwards) {
            let suffixLength = contextBefore.distance(from: range.upperBound, to: contextBefore.endIndex)
            let totalDeleteCount = suffixLength + oldText.count
            
            for _ in 0..<totalDeleteCount {
                proxy.deleteBackward()
            }
            proxy.insertText(newText)
            return true
        }
        
        print("Could not find text '\(oldText)' to replace")
        return false
    }
}

// MARK: - Correction Card View
struct CorrectionCardView: View {
    let correction: GrammarCorrection
    let onApply: (GrammarCorrection) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Error text comparison
            HStack(spacing: 8) {
                // Original text (crossed out)
                Text(correction.oldText)
                    .strikethrough()
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                // Suggested text
                Text(correction.newText)
                    .foregroundColor(.green)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
            }
            
            // Explanation
            Text(correction.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Apply button
            HStack {
                Spacer()
                Button("Apply Fix") {
                    onApply(correction)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.blue)
                .cornerRadius(8)
                .font(.caption.weight(.medium))
            }
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(10)
    }
}

struct EmojiKeyboardView: View {
    @ObservedObject var proxyWrapper: TextDocumentProxyWrapper
    var onClose: () -> Void
    @State private var selectedCategory = 0

    let categories = ["😀", "🌟", "🍎", "⚽", "🚗", "💡", "🎵", "🏁"]
    let categoryNames = ["Smileys", "Nature", "Food", "Activity", "Travel", "Objects", "Symbols", "Flags"]

    let emojiData: [[String]] = [
        // Smileys & People
["😀","😃","😄","😁","😆","😅","🤣","😂","🙂","🙃","😉","😊","😇","🥰","😍","🤩","😘","😗","☺️","😚","😙","🥲","😋","😛","😜","🤪","😝","🤑","🤗","🤭","🤫","🤔","🤐","🤨","😐","😑","😶","😏","😒","🙄","😬","🤥","😔","😪","🤤","😴","😷","🤒","🤕","🤢","🤮","🤧","🥵","🥶","🥴","😵","🤯","🤠","🥳","🥸","😎","🤓","🧐","😕","😟","🙁","☹️","😮","😯","😲","😳","🥺","😦","😧","😨","😰","😥","😢","😭","😱","😖","😣","😞","😓","😩","😫","🥱","😤","😡","😠","🤬","😈","👿","💀","☠️","💩","🤡","👹","👺","👻","👽","👾","🤖","😺","😸","😹","😻","😼","😽","🙀","😿","😾"],

        // Nature
        ["🌱","🌿","🍀","🍃","🍂","🍁","🌾","🌵","🌴","🌳","🌲","🌰","🌻","🌺","🌸","🌼","🌷","🥀","🌹","🌻","💐","🌾","🍄","🌿","🐻","🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐻‍❄️","🐨","🐯","🦁","🐮","🐷","🐸","🐵","🙈","🙉","🙊","🐒","🐔","🐧","🐦","🐤","🐣","🐥","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐜","🦟","🦗","🕷️","🦂","🐢","🐍","🦎","🦖","🦕","🐙","🦑","🦐","🦞","🦀","🐡","🐠","🐟","🐬","🐳","🐋","🦈","🐊","🐅","🐆","🦓","🦍","🐘","🦛","🦏","🐪","🐫","🦒","🦘","🐃","🐂","🐄","🐎","🐖","🐏","🐑","🦙","🐐","🦌","🐕","🐩","🦮","🐕‍🦺","🐈","🐈‍⬛","🐓","🦃","🦚","🦜","🦢","🦩","🕊️","🐇","🦝","🦨","🦡","🦦","🦥","🐁","🐀","🐿️","🦔"],

        // Food & Drink
        ["🍎","🍐","🍊","🍋","🍌","🍉","🍇","🍓","🫐","🍈","🍒","🍑","🥭","🍍","🥥","🥝","🍅","🍆","🥑","🥦","🥬","🥒","🌶️","🫑","🌽","🥕","🫒","🧄","🧅","🥔","🍠","🥐","🥯","🍞","🥖","🥨","🧀","🥚","🍳","🧈","🥞","🧇","🥓","🥩","🍗","🍖","🦴","🌭","🍔","🍟","🍕","🫓","🥪","🥙","🧆","🌮","🌯","🫔","🥗","🥘","🫕","🍝","🍜","🍲","🍛","🍣","🍱","🥟","🦪","🍤","🍙","🍚","🍘","🍥","🥠","🥮","🍢","🍡","🍧","🍨","🍦","🥧","🧁","🍰","🎂","🍮","🍭","🍬","🍫","🍿","🍩","🍪","🌰","🥜","🍯","🥛","🍼","☕","🍵","🧃","🥤","🧋","🍶","🍺","🍻","🥂","🍷","🥃","🍸","🍹","🧉","🍾"],

        // Activity & Sports
        ["⚽","🏀","🏈","⚾","🥎","🎾","🏐","🏉","🥏","🎱","🪀","🏓","🏸","🏒","🏑","🥍","🏏","🪃","🥅","⛳","🪁","🏹","🎣","🤿","🥊","🥋","🎽","🛹","🛷","⛸️","🥌","🎿","⛷️","🏂","🪂","🏋️‍♀️","🏋️","🏋️‍♂️","🤼‍♀️","🤼","🤼‍♂️","🤸‍♀️","🤸","🤸‍♂️","⛹️‍♀️","⛹️","⛹️‍♂️","🤺","🤾‍♀️","🤾","🤾‍♂️","🏌️‍♀️","🏌️","🏌️‍♂️","🏇","🧘‍♀️","🧘","🧘‍♂️","🏄‍♀️","🏄","🏄‍♂️","🏊‍♀️","🏊","🏊‍♂️","🤽‍♀️","🤽","🤽‍♂️","🚣‍♀️","🚣","🚣‍♂️","🧗‍♀️","🧗","🧗‍♂️","🚵‍♀️","🚵","🚵‍♂️","🚴‍♀️","🚴","🚴‍♂️","🏆","🥇","🥈","🥉","🏅","🎖️","🏵️","🎗️"],

        // Travel & Places
        ["🚗","🚕","🚙","🚌","🚎","🏎️","🚓","🚑","🚒","🚐","🛻","🚚","🚛","🚜","🏍️","🛵","🚲","🛴","🛹","🛼","🚁","🛸","🚀","🛰️","💺","🛶","⛵","🚤","🛥️","🛳️","⛴️","🚢","⚓","⛽","🚧","🚦","🚥","🗺️","🗿","🗽","🗼","🏰","🏯","🏟️","🎡","🎢","🎠","⛲","⛱️","🏖️","🏝️","🏜️","🌋","⛰️","🏔️","🗻","🏕️","⛺","🛖","🏠","🏡","🏘️","🏚️","🏗️","🏭","🏢","🏬","🏣","🏤","🏥","🏦","🏨","🏪","🏫","🏩","💒","🏛️","⛪","🕌","🕍","🛕","🕋","⛩️","🛤️","🛣️","🗾","🎑","🏞️","🌅","🌄","🌠","🎇","🎆","🌇","🌆","🏙️","🌃","🌌","🌉","🌁"],

        // Objects & Symbols
        ["⌚","📱","📲","💻","⌨️","🖥️","🖨️","🖱️","🖲️","🕹️","🗜️","💽","💾","💿","📀","📼","📷","📸","📹","🎥","📽️","🎞️","📞","☎️","📟","📠","📺","📻","🎙️","🎚️","🎛️","🧭","⏱️","⏲️","⏰","🕰️","⌛","⏳","📡","🔋","🔌","💡","🔦","🕯️","🪔","🧯","🛢️","💸","💵","💴","💶","💷","💰","💳","💎","⚖️","🧰","🔧","🔨","⚒️","🛠️","⛏️","🔩","⚙️","🧱","⛓️","🧲","🔫","💣","🧨","🪓","🔪","🗡️","⚔️","🛡️","🚬","⚰️","🪦","⚱️","🏺","🔮","📿","🧿","💈","⚗️","🔭","🔬","🕳️","🩹","🩺","💊","💉","🧬","🦠","🧫","🧪","🌡️","🧹","🧺","🧻","🚽","🚰","🚿","🛁","🛀","🧴","🧷","🧸","🧵","🪡","🧶","🪢","👓","🕶️","🥽","🥼","🦺","👔","👕","👖","🧣","🧤","🧥","🧦","👗","👘","🥻","🩱","🩲","🩳","👙","👚","👛","👜","👝","🛍️","🎒","👞","👟","🥾","🥿","👠","👡","🩰","👢","👑","👒","🎩","🎓","🧢","⛑️","📿","💄","💍","💎"],

        // Symbols
        ["❤️","🧡","💛","💚","💙","💜","🖤","🤍","🤎","💔","❣️","💕","💞","💓","💗","💖","💘","💝","💟","☮️","✝️","☪️","🕉️","☸️","✡️","🔯","🕎","☯️","☦️","🛐","⛎","♈","♉","♊","♋","♌","♍","♎","♏","♐","♑","♒","♓","🆔","⚛️","🉑","☢️","☣️","📴","📳","🈶","🈚","🈸","🈺","🈷️","✴️","🆚","💮","🉐","㊙️","㊗️","🈴","🈵","🈹","🈲","🅰️","🅱️","🆎","🆑","🅾️","🆘","❌","⭕","🛑","⛔","📛","🚫","💯","💢","♨️","🚷","🚯","🚳","🚱","🔞","📵","🚭","❗","❕","❓","❔","‼️","⁉️","🔅","🔆","〽️","⚠️","🚸","🔱","⚜️","🔰","♻️","✅","🈯","💹","❇️","✳️","❎","🌐","💠","Ⓜ️","🌀","💤","🏧","🚾","♿","🅿️","🈳","🈂️","🛂","🛃","🛄","🛅","🚹","🚺","🚼","🚻","🚮","🎦","📶","🈁","🔣","ℹ️","🔤","🔡","🔠","🆖","🆗","🆙","🆒","🆕","🆓","0️⃣","1️⃣","2️⃣","3️⃣","4️⃣","5️⃣","6️⃣","7️⃣","8️⃣","9️⃣","🔟"],

        // Flags
        ["🏁","🚩","🏴","🏳️","🏳️‍🌈","🏳️‍⚧️","🏴‍☠️","🇦🇫","🇦🇽","🇦🇱","🇩🇿","🇦🇸","🇦🇩","🇦🇴","🇦🇮","🇦🇶","🇦🇬","🇦🇷","🇦🇲","🇦🇼","🇦🇺","🇦🇹","🇦🇿","🇧🇸","🇧🇭","🇧🇩","🇧🇧","🇧🇾","🇧🇪","🇧🇿","🇧🇯","🇧🇲","🇧🇹","🇧🇴","🇧🇦","🇧🇼","🇧🇷","🇮🇴","🇻🇬","🇧🇳","🇧🇬","🇧🇫","🇧🇮","🇰🇭","🇨🇲","🇨🇦","🇮🇨","🇨🇻","🇧🇶","🇰🇾","🇨🇫","🇹🇩","🇨🇱","🇨🇳","🇨🇽","🇨🇨","🇨🇴","🇰🇲","🇨🇬","🇨🇩","🇨🇰","🇨🇷","🇨🇮","🇭🇷","🇨🇺","🇨🇼","🇨🇾","🇨🇿","🇩🇰","🇩🇯","🇩🇲","🇩🇴","🇪🇨","🇪🇬","🇸🇻","🇬🇶","🇪🇷","🇪🇪","🇪🇹","🇪🇺","🇫🇰","🇫🇷","🇫🇯","🇫🇮","🇫🇷","🇬🇫","🇵🇫","🇹🇫","🇬🇦","🇬🇲","🇬🇪","🇩🇪","🇬🇭","🇬🇮","🇬🇷","🇬🇱","🇬🇩","🇬🇵","🇬🇺","🇬🇹","🇬🇬","🇬🇳","🇬🇼","🇬🇾","🇭🇹","🇭🇳","🇭🇰","🇭🇺","🇮🇸","🇮🇳","🇮🇩","🇮🇷","🇮🇶","🇮🇪","🇮🇲","🇮🇱","🇮🇹","🇯🇲","🇯🇵","🎌","🇯🇪","🇯🇴","🇰🇿","🇰🇪","🇰🇮","🇽🇰","🇰🇼","🇰🇬","🇱🇦","🇱🇻","🇱🇧","🇱🇸","🇱🇷","🇱🇾","🇱🇮","🇱🇹","🇱🇺","🇲🇴","🇲🇰","🇲🇬","🇲🇼","🇲🇾","🇲🇻","🇲🇱","🇲🇹","🇲🇭","🇲🇶","🇲🇷","🇲🇺","🇾🇹","🇲🇽","🇫🇲","🇲🇩","🇲🇨","🇲🇳","🇲🇪","🇲🇸","🇲🇦","🇲🇿","🇲🇲","🇳🇦","🇳🇷","🇳🇵","🇳🇱","🇳🇨","🇳🇿","🇳🇮","🇳🇪","🇳🇬","🇳🇺","🇳🇫","🇰🇵","🇲🇵","🇳🇴","🇴🇲","🇵🇰","🇵🇼","🇵🇸","🇵🇦","🇵🇬","🇵🇾","🇵🇪","🇵🇭","🇵🇳","🇵🇱","🇵🇹","🇵🇷","🇶🇦","🇷🇪","🇷🇴","🇷🇺","🇷🇼","🇼🇸","🇸🇲","🇸🇹","🇸🇦","🇸🇳","🇷🇸","🇸🇨","🇸🇱","🇸🇬","🇸🇽","🇸🇰","🇸🇮","🇬🇸","🇸🇧","🇸🇴","🇿🇦","🇰🇷","🇸🇸","🇪🇸","🇱🇰","🇧🇱","🇸🇭","🇰🇳","🇱🇨","🇵🇲","🇻🇨","🇸🇩","🇸🇷","🇸🇯","🇸🇿","🇸🇪","🇨🇭","🇸🇾","🇹🇼","🇹🇯","🇹🇿","🇹🇭","🇹🇱","🇹🇬","🇹🇰","🇹🇴","🇹🇹","🇹🇳","🇹🇷","🇹🇲","🇹🇨","🇹🇻","🇻🇮","🇺🇬","🇺🇦","🇦🇪","🇬🇧","🏴","🏴","🏴","🇺🇸","🇺🇾","🇺🇿","🇻🇺","🇻🇦","🇻🇪","🇻🇳","🇼🇫","🇪🇭","🇾🇪","🇿🇲","🇿🇼"]
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Category tabs
            HStack(spacing: 2) {
                Button(action: onClose) {
                    Text("ABC")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 24)
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }
                ForEach(0..<categories.count, id: \.self) { index in
                    Button(action: { selectedCategory = index }) {
                        Text(categories[index])
                            .font(.system(size: 20))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .background(selectedCategory == index ? Color.gray.opacity(0.6) : Color.gray.opacity(0.1))
                            .cornerRadius(8)
                    }
                }
                Button(action: { proxyWrapper.deleteBackward() }) {
                    Image(systemName: "delete.left")
                        .frame(width: 40, height: 24)
                        .font(Font.system(size: 16, design: .default))
                        .fontWeight(Font.Weight.semibold)
                        .fontWidth(Font.Width.standard)
                        .foregroundColor(Color(UIColor.black))
                        .background(Color.gray.opacity(0.3))
                        .cornerRadius(8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            // Emoji grid
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 6) {
                    ForEach(emojiData[selectedCategory], id: \.self) { emoji in
                        Button(action: {
                            proxyWrapper.insertText(emoji)
                        }) {
                            Text(emoji)
                                .font(.system(size: 28))
                                .frame(width: 40, height: 40)
                                .background(Color.clear)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

        }
        .background(Color(UIColor.systemGray6))
        .cornerRadius(10)
    }
}
