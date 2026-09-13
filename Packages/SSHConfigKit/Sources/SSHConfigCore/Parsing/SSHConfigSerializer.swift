//
//  SSHConfigSerializer.swift
//  sshconfigmanager
//
//  Renders a document model back to ssh_config text.
//

import Foundation

/// Renders a `SSHConfigDocument` back to text.
///
/// Clean lines are emitted from their preserved raw text, so an unedited document
/// round-trips byte-for-byte. Edited and newly inserted directives are rendered
/// from their fields using the indentation captured from the surrounding block.
public enum SSHConfigSerializer {

    public static func serialize(_ document: SSHConfigDocument) -> String {
        var out: [String] = []

        for line in document.preamble {
            out.append(line.rendered)
        }

        for block in document.blocks {
            for line in block.leading {
                out.append(line.rendered)
            }
            out.append(block.header.rendered)
            for line in block.body {
                out.append(line.rendered)
            }
        }

        var text = out.joined(separator: "\n")
        if document.trailingNewline {
            text += "\n"
        }
        return text
    }
}
