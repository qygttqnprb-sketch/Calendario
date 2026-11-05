import XCTest
@testable import Coppia
final class CoupleClockTests: XCTestCase {
    func testRomeSundayUTCIsMondayLocally() {
        let now=CalendarEvent.parse("2026-11-01T23:30:00Z")
        let start=CoupleClock.weekStart(now,zone:"Europe/Rome")
        XCTAssertEqual(CoupleClock.dayKey(start,zone:"Europe/Rome"),"2026-11-02")
        XCTAssertEqual(start,CalendarEvent.parse("2026-11-01T23:00:00Z"))
    }
    func testDSTWeekHas167Hours() {
        let c=CoupleClock.calendar("Europe/Rome")
        let w=c.dateInterval(of:.weekOfYear,for:CalendarEvent.parse("2026-03-29T10:00:00Z"))!
        XCTAssertEqual(w.duration,167*3600)
    }
    func testISOYearBoundary() {
        let date=CalendarEvent.parse("2027-01-01T12:00:00Z")
        XCTAssertEqual(CoupleClock.dayKey(CoupleClock.weekStart(date,zone:"Europe/Rome"),zone:"Europe/Rome"),"2026-12-28")
    }
    func testHTTPSOnlyAndNoCredentials() {
        XCTAssertNotNil(CoupleClock.safeURL("https://www.thefork.it/ristorante/test"))
        for u in ["http://example.com","javascript:alert(1)","https://user:pass@example.com","https://example.com:123/","https://example.com\\evil"] { XCTAssertNil(CoupleClock.safeURL(u)) }
    }
    func testFractionalDatesDecode() {
        XCTAssertEqual(CalendarEvent.parse("2026-11-04T12:00:00.000+00:00"),CalendarEvent.parse("2026-11-04T12:00:00Z"))
    }
}
