import Foundation
import Testing
@testable import HeydayKit

private func crlf(_ text: String) -> Data {
    Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

@Suite struct MIMEHeaderTests {
    @Test func foldedHeadersAreJoinedAndNamesAreCaseInsensitive() {
        let headers = MIMEHeaders(crlf("Subject: A long\n subject line\nFROM: jane@example.com\n"))

        #expect(headers.text("subject") == "A long subject line")
        #expect(headers.raw("From") == "jane@example.com")
    }

    @Test func encodedWordsDecodeInBase64AndQuotedPrintable() {
        #expect(EncodedWord.decode("=?UTF-8?B?7JWI64WV7ZWY7IS47JqU?=") == "안녕하세요")
        #expect(EncodedWord.decode("=?ISO-8859-1?Q?Caf=E9_au_lait?=") == "Café au lait")
        // Whitespace between two encoded words is not part of the text.
        #expect(EncodedWord.decode("=?UTF-8?B?7JWI?= =?UTF-8?B?64WV?=") == "안녕")
    }

    @Test func koreanLegacyCharsetsAreHonoured() {
        // "한글" in EUC-KR.
        #expect(EncodedWord.decode("=?EUC-KR?B?x9Gx2w==?=") == "한글")
    }

    @Test func nonASCIIHeadersAreEncodedForSendingAndRoundTrip() {
        let subject = "회의 일정 안내드립니다 — 다음 주 목요일 오후 세 시"

        let encoded = EncodedWord.encode(subject)

        let isASCII = encoded.allSatisfy(\.isASCII)
        let longestWord = encoded.split(separator: " ").map(\.count).max() ?? 0
        #expect(isASCII)
        #expect(longestWord <= 75)
        #expect(EncodedWord.decode(encoded) == subject)
        #expect(EncodedWord.encode("Plain subject") == "Plain subject")
    }

    @Test func addressListsKeepNamesWithCommasAndEncodedWords() {
        let headers = MIMEHeaders(crlf(#"To: "Doe, Jane" <jane@example.com>, sam@example.com, =?UTF-8?B?67CV7LCs7Z2s?= <bak@example.kr>"# + "\n"))

        #expect(headers.addresses("to") == [
            EmailAddress(name: "Doe, Jane", address: "jane@example.com"),
            EmailAddress(address: "sam@example.com"),
            EmailAddress(name: "박찬희", address: "bak@example.kr"),
        ])
    }

    @Test func messageIDsAreReadFromReferences() {
        let headers = MIMEHeaders(crlf("References: <a@x> <b@x>\n\t<c@x>\n"))

        #expect(headers.messageIDs("references") == ["<a@x>", "<b@x>", "<c@x>"])
    }

    @Test func datesParseWithAndWithoutWeekdayAndZoneComment() {
        let expected = Date(timeIntervalSince1970: 1_795_624_357)

        #expect(MailDate.parse("Wed, 25 Nov 2026 16:32:37 +0000 (UTC)") == expected)
        #expect(MailDate.parse("26 Nov 2026 01:32:37 +0900") == expected)
        #expect(MailDate.parse(MailDate.format(expected)) == expected)
    }

    @Test func theServersArrivalTimeParsesWithAPaddedDay() {
        #expect(MailDate.parseInternal("26-Nov-2026 01:32:37 +0900") == Date(timeIntervalSince1970: 1_795_624_357))
        #expect(MailDate.parseInternal(" 7-Jul-2026 02:44:25 +0000") == Date(timeIntervalSince1970: 1_783_392_265))
    }

    @Test func contentTypeParametersAreUnquotedAndRFC2231Decoded() {
        let type = ContentType(#"Multipart/Mixed; boundary="a;b"; name*=UTF-8''%EB%B3%B4%EA%B3%A0%EC%84%9C.pdf"#)

        #expect(type.type == "multipart/mixed")
        #expect(type.parameters["boundary"] == "a;b")
        #expect(type.parameters["name"] == "보고서.pdf")
    }
}

@Suite struct MIMEMessageTests {
    @Test func aPlainTextMessageKeepsItsLineBreaksAndIsEscaped() {
        let message = MIMEMessage(crlf("Subject: Hi\n\nLine one\n<b>not bold</b>\n"))

        #expect(message.html == "<div style=\"white-space: pre-wrap\">Line one\r\n&lt;b&gt;not bold&lt;/b&gt;\r\n</div>")
        #expect(message.attachments.isEmpty)
    }

    @Test func theHTMLAlternativeIsPreferredAndQuotedPrintableIsDecoded() {
        let raw = crlf("""
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/plain; charset=utf-8

        plain version
        --alt
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <p>caf=C3=A9 =
        latte</p>
        --alt--
        """)

        #expect(MIMEMessage(raw).html == "<p>café latte</p>")
    }

    @Test func attachmentsAreListedAndEmbeddedPicturesAreInlined() {
        let raw = crlf("""
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: multipart/related; boundary="rel"

        --rel
        Content-Type: text/html

        <img src="cid:logo@x">
        --rel
        Content-Type: image/png
        Content-Transfer-Encoding: base64
        Content-ID: <logo@x>

        iVBORw==
        --rel--
        --mix
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0=
        --mix--
        """)

        let message = MIMEMessage(raw)

        #expect(message.html == "<img src=\"data:image/png;base64,iVBORw==\">")
        #expect(message.attachments == [Attachment(id: 0, filename: "report.pdf", mimeType: "application/pdf", data: Data("%PDF-".utf8))])
    }

    @Test func aBodyInALegacyCharsetIsReadAsText() {
        var raw = crlf("Content-Type: text/plain; charset=EUC-KR\n\n")
        raw.append(contentsOf: [0xC7, 0xD1, 0xB1, 0xDB])

        #expect(MIMEMessage(raw).html.contains("한글"))
    }

    @Test func aPreviewSurvivesABodyCutOffMidPart() {
        let headers = MIMEHeaders(crlf("Content-Type: multipart/alternative; boundary=\"alt\"\n"))
        let partial = crlf("""
        --alt
        Content-Type: text/html; charset=utf-8

        <html><head><style>p { color: red }</style></head><body><p>Hello&nbsp;there,</p>
        <p>your order has shi
        """)

        #expect(MIMEMessage.preview(headers: headers, partialBody: partial) == "Hello there, your order has shi")
    }

    @Test func aPreviewDecodesBase64ThatStopsBetweenGroups() {
        let headers = MIMEHeaders(crlf("Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n"))
        // "Hello, world" is SGVsbG8sIHdvcmxk; the fetch stopped two characters into the last group.
        let partial = Data("SGVsbG8sIHdvcm".utf8)

        #expect(MIMEMessage.preview(headers: headers, partialBody: partial) == "Hello, wo")
    }
}

@Suite struct MailBodyColoursTests {
    @Test func anEmailOfWordsAndLinksSetsNoColours() {
        #expect(!MailBodyColours.areSet(in: "<p>Hi Chan,</p><p>Lunch on <b>Thursday</b>? <a href=\"https://example.com/menu\">Menu</a></p>"))
        #expect(!MailBodyColours.areSet(in: "<div style=\"font-family: Helvetica; margin: 0\">Booked.</div>"))
    }

    @Test func aColourInAStyleOrAnAttributeIsSeenWhateverItsCase() {
        #expect(MailBodyColours.areSet(in: "<td style=\"background:#1f2937\">Orbit</td>"))
        #expect(MailBodyColours.areSet(in: "<p style=\"COLOR : #6b7280\">small print</p>"))
        #expect(MailBodyColours.areSet(in: "<table bgcolor=\"#ffffff\"><tr><td>x</td></tr></table>"))
        #expect(MailBodyColours.areSet(in: "<font color=red>Sale</font>"))
        #expect(MailBodyColours.areSet(in: "<style>.a { background-color: #eee }</style>"))
        #expect(MailBodyColours.areSet(in: "<body text=\"#000000\" link=\"#0000ee\"><p>Hello</p></body>"))
    }

    @Test func wordsThatOnlyContainTheNameOfAColourPropertySetNone() {
        #expect(!MailBodyColours.areSet(in: "<p>The colors of the background were lovely.</p>"))
    }
}
