/// Text that comes from the user's files reaches GTK through widgets that do not
/// all treat it as plain text. The two escapes below are the whole answer, and
/// `CLAUDE.md` records which widget needs which.
extension String {
    /// Escapes the characters Pango treats as markup. A label that parses markup
    /// drops the whole string when the parse fails, so one ampersand in a host
    /// name empties the label.
    public var markupEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes the underscore GTK reads as a keyboard mnemonic. Menu item labels
    /// are the one place this applies, and an underscore in a host alias or a
    /// file name is ordinary.
    public var mnemonicEscaped: String {
        replacingOccurrences(of: "_", with: "__")
    }
}
