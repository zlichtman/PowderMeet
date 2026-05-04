//
//  HUDSecureField.swift
//  PowderMeet
//
//  UITextField wrapper with `isSecureTextEntry = true` and explicit
//  `textColor`, used in place of SwiftUI's `SecureField` on the auth
//  screens. SwiftUI's SecureField has a long-standing bug: foreground
//  style isn't reliably applied to the bullet glyphs on first render,
//  on view-identity changes, and — most stubbornly — when text enters
//  via Apple Password AutoFill from the keyboard suggestion bar. The
//  AutoFill path produced a string of black bullets with the last
//  glyph in our accent color, because that last keystroke happened
//  to land after one of SwiftUI's color-binding refreshes.
//
//  UITextField has no such bug. Setting `textColor` once is enough
//  for every glyph at every moment regardless of how text was
//  inserted (typed, pasted, AutoFilled). Wrapping it costs ~80 lines
//  but the result is always-red dots. Cheap insurance for a
//  high-visibility surface.
//

import SwiftUI
import UIKit

struct HUDSecureField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var textColor: Color
    var placeholderColor: Color
    var tintColor: Color
    var isSecure: Bool
    var contentType: UITextContentType?
    var font: UIFont
    var onSubmit: (() -> Void)?

    init(
        text: Binding<String>,
        placeholder: String,
        textColor: Color,
        placeholderColor: Color,
        tintColor: Color,
        isSecure: Bool,
        contentType: UITextContentType? = nil,
        font: UIFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium),
        onSubmit: (() -> Void)? = nil
    ) {
        self._text = text
        self.placeholder = placeholder
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.tintColor = tintColor
        self.isSecure = isSecure
        self.contentType = contentType
        self.font = font
        self.onSubmit = onSubmit
    }

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField()
        tf.delegate = context.coordinator
        tf.font = font
        tf.textColor = UIColor(textColor)
        tf.tintColor = UIColor(tintColor)
        tf.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(placeholderColor)]
        )
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.isSecureTextEntry = isSecure
        tf.textContentType = contentType
        tf.returnKeyType = .done
        tf.clearButtonMode = .never
        tf.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // External binding → field. Guarded so we don't fight the
        // user's cursor when the binding update reflects a value
        // they just typed.
        if uiView.text != text {
            uiView.text = text
        }

        // Re-apply visual config. UITextField holds these correctly
        // across AutoFill / paste / selection — unlike SwiftUI's
        // SecureField, where foregroundStyle drifts in those flows.
        uiView.textColor = UIColor(textColor)
        uiView.tintColor = UIColor(tintColor)
        uiView.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(placeholderColor)]
        )
        uiView.font = font
        uiView.textContentType = contentType
        if uiView.isSecureTextEntry != isSecure {
            // Toggling secure entry mid-flight wipes the field on
            // some iOS versions; setting `text` again immediately
            // restores it without a flash.
            let preserved = uiView.text
            uiView.isSecureTextEntry = isSecure
            uiView.text = preserved
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: HUDSecureField

        init(_ parent: HUDSecureField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            // Push UIKit's text up to SwiftUI. Direct assignment;
            // SwiftUI's binding handles the diff.
            parent.text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit?()
            textField.resignFirstResponder()
            return true
        }
    }
}
