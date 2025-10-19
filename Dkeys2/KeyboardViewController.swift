//
//  KeyboardViewController.swift
//  Dkeys2
//
//  Created by Sambath Kumar Logakrishnan on 18/10/2025.
//

import UIKit
import SwiftUI
import Combine

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

    // Placeholder: populate suggestions after a grammar check (keeps behavior existing callers expect)
    func performGrammarCheck() {
        // For now reuse the dictionary-based suggestions to keep results consistent
        updateSuggestionsFromContext()
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
                    Image(systemName: "checkmark.shield")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .padding(8)
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
                    Image(systemName: "arrow.2.squarepath")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                        .padding(8)
                }
                .background(Color(UIColor.systemGray5))
                .cornerRadius(8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(UIColor.systemGray4))
            .cornerRadius(10)
            
            if showNumbers {
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
                 // Left-side toggles: when not showing numbers, show a 123 button to enter numbers page.
                 // When in numbers page, provide both an ABC button (to go back to letters) and a #+= / 123 toggle.
                 if showNumbers {
                     Button(action: { showSymbols.toggle() }) {
                         Text(showSymbols ? "123" : "#+=")
                             .frame(width: 50, height: 44)
                             .background(Color.gray.opacity(0.2))
                             .cornerRadius(8)
                     }
                     Button(action: { showNumbers = false; showSymbols = false }) {
                         Text("ABC")
                             .frame(width: 50, height: 44)
                             .background(Color.gray.opacity(0.2))
                             .cornerRadius(8)
                     }
                 } else {
                     Button(action: { showNumbers = true; showSymbols = false }) {
                         Text("123")
                             .frame(width: 50, height: 44)
                             .background(Color.gray.opacity(0.2))
                             .cornerRadius(8)
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
         .padding(8)
         .background(Color(UIColor.systemGray5))
         
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
