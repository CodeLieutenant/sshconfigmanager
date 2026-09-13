//
//  CodeEditorTests.swift
//  sshconfigmanagerTests
//
//  Regression coverage for audit #31: restoring a text view's selection
//  verbatim after a programmatic string swap can raise NSRangeException if
//  the new string is shorter than the old one. `clampSelectedRanges` is the
//  pure half of that fix — the AppKit integration (no exception on a real
//  `NSTextView`) needs a `@MainActor` text view and isn't covered here.
//

import Foundation
import Testing

@testable import SSHConfigMacUI

struct CodeEditorTests {
    private func ranges(_ pairs: [(Int, Int)]) -> [NSValue] {
        pairs.map { NSValue(range: NSRange(location: $0.0, length: $0.1)) }
    }

    private func unpack(_ values: [NSValue]) -> [NSRange] {
        values.map(\.rangeValue)
    }

    @Test func rangeFullyWithinBoundsIsUnchanged() {
        let clamped = CodeEditor.clampSelectedRanges(ranges([(2, 5)]), toLength: 20)
        #expect(unpack(clamped) == [NSRange(location: 2, length: 5)])
    }

    @Test func rangeExtendingPastTheNewLengthIsTruncated() {
        // Old string was 20 chars, selection covered chars 15...20; new string
        // is only 10 chars — the tail of the old selection no longer exists.
        let clamped = CodeEditor.clampSelectedRanges(ranges([(15, 5)]), toLength: 10)
        #expect(unpack(clamped) == [NSRange(location: 10, length: 0)])
    }

    @Test func locationPastTheNewLengthCollapsesToTheEnd() {
        let clamped = CodeEditor.clampSelectedRanges(ranges([(50, 3)]), toLength: 10)
        #expect(unpack(clamped) == [NSRange(location: 10, length: 0)])
    }

    @Test func emptyNewStringCollapsesEveryRangeToZero() {
        let clamped = CodeEditor.clampSelectedRanges(ranges([(0, 5), (3, 2)]), toLength: 0)
        #expect(unpack(clamped) == [NSRange(location: 0, length: 0), NSRange(location: 0, length: 0)])
    }

    @Test func multipleRangesAreEachClampedIndependently() {
        let clamped = CodeEditor.clampSelectedRanges(ranges([(0, 3), (8, 10)]), toLength: 10)
        #expect(unpack(clamped) == [NSRange(location: 0, length: 3), NSRange(location: 8, length: 2)])
    }

    @Test func exactBoundaryRangeIsUnchanged() {
        // A collapsed caret sitting exactly at the new end is valid, not "past" it.
        let clamped = CodeEditor.clampSelectedRanges(ranges([(10, 0)]), toLength: 10)
        #expect(unpack(clamped) == [NSRange(location: 10, length: 0)])
    }
}
