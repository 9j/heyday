import Foundation
import Testing
@testable import HeydayKit

@Suite struct HTMLTagsTests {
    @Test func tagsAreReadWithQuotedBareAndUnquotedAttributes() {
        var seen: [HTMLTag] = []

        _ = HTMLTags.rewrite(#"<IMG SRC='a.png' Width=600 hidden alt="A &amp; B"><br/>"#) { tag in
            seen.append(tag)
            return nil
        }

        #expect(seen.map(\.name) == ["img", "br"])
        #expect(seen[0]["src"] == "a.png")
        #expect(seen[0]["width"] == "600")
        #expect(seen[0]["hidden"] == "")
        #expect(seen[0]["alt"] == "A & B")
    }

    @Test func onlyTheTagsReplacedChangeAndTheRestIsLeftByteForByte() {
        let html = "<p class=x>Héllo <b>there</b></p>\n<hr>"

        #expect(HTMLTags.rewrite(html) { $0.name == "b" ? "<strong>" : nil } == "<p class=x>Héllo <strong>there</b></p>\n<hr>")
        #expect(HTMLTags.rewrite(html) { _ in nil } == html)
    }

    @Test func whatLooksLikeATagInsideACommentScriptOrStyleSheetIsNotOne() {
        let html = "<!-- <img src=a> --><style>p > a { content: '<img src=b>' }</style><SCRIPT>if (a<img) {}</SCRIPT><img src=c>"
        var sources: [String?] = []

        _ = HTMLTags.rewrite(html) { tag in
            if tag.name == "img" { sources.append(tag["src"]) }
            return nil
        }

        #expect(sources == ["c"])
    }

    @Test func aDocumentThatEndsInsideATagIsLeftAlone() {
        #expect(HTMLTags.rewrite("<p>text <img src=\"a") { _ in "" } == "text <img src=\"a")
    }

    @Test func aRewrittenTagEscapesItsValues() {
        var tag = HTMLTag(name: "a", attributes: [])
        tag.set("href", to: "https://example.com/?a=1&b=\"2\"")

        #expect(tag.html == "<a href=\"https://example.com/?a=1&amp;b=&quot;2&quot;\">")
    }
}

@Suite struct TrackerRulesTests {
    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test func aKnownOpenTrackerIsNamed() {
        #expect(TrackerRules.openTracker(at: url("https://acme.us1.list-manage.com/track/open.php?u=1&id=2&e=3"))?.service == "Mailchimp")
        #expect(TrackerRules.openTracker(at: url("https://email.shop.example/wf/open?upn=abc"))?.service == "SendGrid")
        #expect(TrackerRules.openTracker(at: url("https://cdn.example.com/hero.png")) == nil)
    }

    /// Address shapes taken from real mail, with the identifiers replaced.
    @Test func aServicesTrackersAreKnownOnTheSendersOwnDomainToo() {
        #expect(TrackerRules.openTracker(at: url("https://us.list-manage.com/AbCdEfGhIjKlMnOpQr_Stu?e=1234567890&c2id=0123abcd"))?.service == "Mailchimp")
        #expect(MailTracker.tracking(link: url("https://us.list-manage.com/tHAbCdEfGhI?e=1234567890&c2id=0123abcd"))?.name == "Mailchimp")
        #expect(TrackerRules.openTracker(at: url("https://ab1cd.r.ag.d.sendibm3.com/mk/op/sh/AbCdEfGh/iJkLmN"))?.service == "Brevo")
        #expect(MailTracker.tracking(link: url("https://ab1cd.r.ag.d.sendibm3.com/mk/cl/f/sh/AbCdEfGh/iJkLmN"))?.name == "Brevo")
        #expect(TrackerRules.openTracker(at: url("https://email.mg.example.com/o/eJxEy0tuwyAQ"))?.service == "Mailgun")
        #expect(MailTracker.tracking(link: url("https://email.mg.example.com/c/eJxEy0FuwyAQ"))?.name == "Mailgun")
        #expect(TrackerRules.openTracker(at: url("https://c.vialoops.com/CI0/0100abc-000000/xyz=42"))?.service == "Loops")
        #expect(TrackerRules.openTracker(at: url("https://click.shop.example/CI0/0100abc-000000/xyz=42"))?.service == "Amazon SES")
    }

    @Test func anAddressOfAServiceThatIsNotATrackerIsLeftAlone() {
        // Mailchimp's own pages for the reader: they need the reader's identifier to work.
        #expect(MailTracker.tracking(link: url("https://acme.us6.list-manage.com/unsubscribe?u=1&id=2&e=3&c=4")) == nil)
        #expect(TrackerRules.openTracker(at: url("https://example.com/o/logo.png")) == nil)
    }

    @Test func aClickTrackerIsKnownByNameOrByItsHost() {
        #expect(MailTracker.tracking(link: url("https://acme.us1.list-manage.com/track/click?u=1&id=2&e=3"))?.name == "Mailchimp")
        #expect(MailTracker.tracking(link: url("https://click.news.example.com/f/a/abc"))?.name == "click.news.example.com")
        #expect(MailTracker.tracking(link: url("https://link.springer.com/article/10.1000/x")) == nil)
        #expect(MailTracker.tracking(link: url("https://track.example")) == nil)
    }

    @Test func aRedirectThatShowsItsDestinationIsUnwrapped() {
        #expect(TrackerRules.destination(embeddedIn: url("https://www.google.com/url?q=https://example.com/a%3Fb%3D1&sa=D")) == url("https://example.com/a?b=1"))
        #expect(TrackerRules.destination(embeddedIn: url("https://eur01.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com%2Fdocs&data=x")) == url("https://example.com/docs"))
        #expect(TrackerRules.destination(embeddedIn: url("https://abc.r.us-east-1.awstrack.me/L0/https:%2F%2Fexample.com%2Fpricing/1/0100abc/xyz=42")) == url("https://example.com/pricing"))
        #expect(TrackerRules.destination(embeddedIn: url("https://urldefense.com/v3/__https://example.com/report__;!!abc!xyz$")) == url("https://example.com/report"))
        // Amazon SES from a sender's own domain, as Loops sends it.
        #expect(TrackerRules.destination(embeddedIn: url("https://c.vialoops.com/CL0/https:%2F%2Fapp.example.com%2F%23promo/1/0100abc-000000/xyz=42")) == url("https://app.example.com/#promo"))
    }

    @Test func aLinkThatMerelyCarriesAnAddressIsNotUnwrapped() {
        // Signing in and then going on is what this link is for.
        #expect(TrackerRules.destination(embeddedIn: url("https://accounts.example.com/login?next=https://example.com/app")) == nil)
        #expect(TrackerRules.destination(embeddedIn: url("https://www.google.com/url?q=javascript:alert(1)")) == nil)
    }

    @Test func anImageAtAPlainAddressLooksSharedByEveryRecipient() {
        #expect(TrackerRules.looksShared(imageAt: url("https://cdn.example.com/emails/spring-sale-banner-2026.png")))
        #expect(TrackerRules.looksShared(imageAt: url("https://cdn.shop.example/files/hero_v2.jpg?v=1699999999&width=600")))
        #expect(TrackerRules.looksShared(imageAt: url("https://example.com/logo.png")))
    }

    /// Mailing services file a sender's pictures under generated names, the same
    /// for every recipient.
    @Test func aGeneratedNameInAnImagesPathDoesNotMakeItPersonal() {
        #expect(TrackerRules.looksShared(imageAt: url("https://mcusercontent.com/0123456789abcdef012345678/images/550e8400-e29b-41d4-a716-446655440000.png")))
        #expect(TrackerRules.looksShared(imageAt: url("https://cdn.example.com/email_assets/8f3a2c1d9e4b7a608f3a2c1d9e4b7a60.png")))
        #expect(TrackerRules.looksShared(imageAt: url("https://images.example.com/cld99yg9p003fjw08rdrgbu3e/cmwunm1xw0ht20j1ihl4idhlg.jpg")))
    }

    @Test func anImageWhoseAddressCouldMarkOneReaderDoesNot() {
        // A parameter that is not about how to serve the picture, or one that is
        // but carries a generated identifier.
        #expect(!TrackerRules.looksShared(imageAt: url("https://cdn.example.com/logo.png?uid=42")))
        #expect(!TrackerRules.looksShared(imageAt: url("https://ab1cd.img.mail.example.com/im/sh/AbCdEfGh.png?u=92pJLo34vnrQtTPkHqj2fAh0Tcz")))
        #expect(!TrackerRules.looksShared(imageAt: url("https://cdn.example.com/logo.png?v=8f3a2c1d9e4b7a60")))
        // A host mailing services serve from.
        #expect(!TrackerRules.looksShared(imageAt: url("https://email.news.example.com/logo.png")))
        #expect(!TrackerRules.looksShared(imageAt: url("https://click.example.com/logo.png")))
    }

    @Test func trackingParametersAreStrippedAndTheOthersKeptAsWritten() {
        #expect(TrackerRules.strippingTrackingParameters(url("https://example.com/p?id=7&utm_source=news&UTM_Medium=email&fbclid=abc&q=a%20b"))
            == url("https://example.com/p?id=7&q=a%20b"))
        #expect(TrackerRules.strippingTrackingParameters(url("https://example.com/p?utm_campaign=x#top")) == url("https://example.com/p#top"))
        #expect(TrackerRules.strippingTrackingParameters(url("https://example.com/p?id=7")) == url("https://example.com/p?id=7"))
    }
}

@Suite struct MailBodyProtectorTests {
    @Test func aKnownTrackingPixelIsRemovedAndNamed() {
        let body = MailBodyProtector.protect(#"<p>Hi</p><img src="https://acme.us1.list-manage.com/track/open.php?u=1&amp;id=2" width="1" height="1">"#)

        #expect(body.displayHTML == "<p>Hi</p>")
        #expect(body.quotableHTML == "<p>Hi</p>")
        #expect(body.report.pixels == [MailTracker(kind: .pixel, service: "Mailchimp", host: "acme.us1.list-manage.com")])
        #expect(body.images.isEmpty)
    }

    @Test func anImageTooSmallToSeeIsATrackerWhoeverSendsIt() {
        let byAttributes = MailBodyProtector.protect(#"<img src="https://stats.example.com/o/abc.gif" width="1" height="1">"#)
        let byStyle = MailBodyProtector.protect(#"<img src="//stats.example.com/o/abc.gif" style="WIDTH: 1px; height:0 !important">"#)

        #expect(byAttributes.report.pixels == [MailTracker(kind: .pixel, service: nil, host: "stats.example.com")])
        #expect(byStyle.report.pixels == byAttributes.report.pixels)
        #expect(byStyle.displayHTML.isEmpty)
    }

    @Test func aSpacerThatIsOnlyNarrowIsNotATracker() {
        let body = MailBodyProtector.protect(#"<img src="https://cdn.example.com/spacer.gif" width="1" height="20">"#)

        #expect(body.report.pixels.isEmpty)
        #expect(body.images.count == 1)
    }

    @Test func anImageWhoseAddressCouldMarkTheReaderWaitsBehindAPlaceholderOfItsSize() throws {
        let body = MailBodyProtector.protect(#"<a href="https://example.com"><img src="https://cdn.example.com/hero.png?uid=42" width="600" height="200" alt="Spring <sale>"></a>"#)

        #expect(body.images.map(\.url) == [URL(string: "https://cdn.example.com/hero.png?uid=42")!])
        #expect(body.images.map(\.looksShared) == [false])
        #expect(body.displayHTML == #"<a href="https://example.com"><span class="heyday-image" data-heyday-image="0" role="button" title="Load this image from cdn.example.com" style="width:600px;aspect-ratio:600/200;"><span class="heyday-image-label">Show image: Spring &lt;sale&gt;</span></span></a>"#)
        #expect(!body.displayHTML.contains("cdn.example.com/hero.png"))
        #expect(body.report.isEmpty)
    }

    @Test func anImageAtASharedLookingAddressIsMarkedToBeFetchedUnasked() {
        let body = MailBodyProtector.protect(#"<img src="https://cdn.example.com/hero.png" alt="Sale">"#)

        #expect(body.images.map(\.looksShared) == [true])
        #expect(body.displayHTML.contains(#"<span class="heyday-image-label">Loading…</span>"#))
        // The page still does not fetch it itself.
        #expect(!body.displayHTML.contains("cdn.example.com/hero.png"))
    }

    @Test func anImageIsFetchedFromItsAddressWithoutTheTrackingParameters() {
        let body = MailBodyProtector.protect(#"<img src="https://cdn.example.com/hero.png?utm_source=news&amp;mc_eid=abc123&amp;width=600">"#)

        #expect(body.images.map(\.url) == [URL(string: "https://cdn.example.com/hero.png?width=600")!])
        #expect(body.images.map(\.looksShared) == [true])
    }

    @Test func aFetchedImageGoesBackIntoTheSendersOwnTag() {
        let body = MailBodyProtector.protect(#"<img src="https://cdn.example.com/a.png" srcset="https://cdn.example.com/a@2x.png 2x" onerror="x()" width="40" alt="Logo">"#)

        let html = body.images[0].html(showing: RemoteImage(data: Data([1, 2, 3]), mimeType: "image/png"))

        #expect(html == #"<img src="data:image/png;base64,AQID" width="40" alt="Logo">"#)
    }

    @Test func picturesThatTravelWithTheEmailAreLeftAlone() {
        let html = #"<img src="data:image/png;base64,AQID"><img src="cid:logo@x"><img alt="none">"#

        let body = MailBodyProtector.protect(html)

        #expect(body.displayHTML == html)
        #expect(body.images.isEmpty)
    }

    @Test func anImageTheSenderHidesIsDroppedFromViewWithoutBeingCalledATracker() {
        let html = #"<img src="https://cdn.example.com/mobile.png" style="display: none" width="320">"#

        let body = MailBodyProtector.protect(html)

        #expect(body.displayHTML.isEmpty)
        #expect(body.images.isEmpty)
        #expect(body.report.isEmpty)
        #expect(body.quotableHTML == html)
    }

    @Test func aQuotedEmailKeepsItsPicturesButNotItsTrackers() {
        let body = MailBodyProtector.protect(#"<img src="https://cdn.example.com/hero.png"><img src="https://x.example.com/wf/open?upn=1">"#)

        #expect(body.quotableHTML == #"<img src="https://cdn.example.com/hero.png">"#)
    }

    @Test func linksLoseWhatTrackingCanBeTakenOff() {
        let body = MailBodyProtector.protect(
            #"<a href="https://www.google.com/url?q=https://example.com/a%3Futm_source%3Dnews%26id%3D7">one</a>"#
                + #"<a href="https://example.com/b?utm_medium=email" ping="https://stats.example.com/p">two</a>"#
                + #"<a href="https://example.com/c">three</a>"#
        )

        #expect(body.displayHTML == #"<a href="https://example.com/a?id=7">one</a><a href="https://example.com/b">two</a><a href="https://example.com/c">three</a>"#)
        #expect(body.report.cleanedLinks == 2)
        #expect(body.report.trackedLinks.isEmpty)
    }

    @Test func aLinkOnlyItsTrackerCanResolveIsKeptAndMarked() {
        let body = MailBodyProtector.protect(#"<a href="https://acme.us1.list-manage.com/track/click?u=1&amp;id=2" title="Read">Read</a>"#)

        #expect(body.displayHTML == #"<a href="https://acme.us1.list-manage.com/track/click?u=1&amp;id=2" title="Tracked by Mailchimp" data-heyday-tracker="Mailchimp">Read</a>"#)
        #expect(body.report.trackedLinks.map(\.name) == ["Mailchimp"])
        #expect(body.report.cleanedLinks == 0)
    }

    @Test func nothingMayMoveTheReaderOrTheirLinksElsewhere() {
        let body = MailBodyProtector.protect(#"<meta charset="utf-8"><META HTTP-EQUIV="Refresh" content="0;url=https://t.example.com"><base href="https://t.example.com/"><p>Hi</p>"#)

        #expect(body.displayHTML == #"<meta charset="utf-8"><p>Hi</p>"#)
    }

    @Test func mailWithNothingRemoteComesBackAsWritten() {
        let html = "<div style=\"white-space: pre-wrap\">Lunch on Friday?\r\n<mailto:jane@example.com></div>"

        let body = MailBodyProtector.protect(html)

        #expect(body.displayHTML == html)
        #expect(body.report.isEmpty)
    }
}
