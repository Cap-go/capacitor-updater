import Foundation
import XCTest
@testable import CapacitorUpdaterPlugin

private final class ListChannelsRequestCapgoUpdater: CapgoUpdater {
    private let requestResult: CapgoUpdater.RequestResult

    init(requestResult: CapgoUpdater.RequestResult) {
        self.requestResult = requestResult
        super.init()
    }

    override func performRequest(_: URLRequest, label _: String) -> CapgoUpdater.RequestResult {
        requestResult
    }
}

final class ListChannelsTests: XCTestCase {
    private let channelScheme = "https"
    private let channelHost = "example.com"
    private let channelPathComponent = "channel"

    func testListChannelsDecodesNumericChannelIdsAsNumbers() throws {
        let channelURL = try makeChannelURL()
        let response = try XCTUnwrap(HTTPURLResponse(url: channelURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let responseData = Data("""
        [
          {"id":123,"name":"Production","public":true,"allow_self_set":true},
          {"id":456,"name":"Beta","public":false,"allow_self_set":true}
        ]
        """.utf8)
        let requestResult = CapgoUpdater.RequestResult(data: responseData, response: response, error: nil, timedOut: false)
        let updater = ListChannelsRequestCapgoUpdater(requestResult: requestResult)
        updater.setLogger(Logger(withTag: "TestLogger"))
        updater.channelUrl = channelURL.absoluteString

        let result = updater.listChannels()

        XCTAssertEqual(result.error, "")
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.channels[0]["id"] as? Int, 123)
        XCTAssertEqual(result.channels[0]["name"] as? String, "Production")
        XCTAssertEqual(result.channels[0]["public"] as? Bool, true)
        XCTAssertEqual(result.channels[0]["allow_self_set"] as? Bool, true)
        XCTAssertEqual(result.channels[1]["id"] as? Int, 456)
    }

    func testListChannelsRejectsStringChannelIds() throws {
        let channelURL = try makeChannelURL()
        let response = try XCTUnwrap(HTTPURLResponse(url: channelURL, statusCode: 200, httpVersion: nil, headerFields: nil))
        let responseData = Data("""
        [
          {"id":"123","name":"Production","public":true,"allow_self_set":true}
        ]
        """.utf8)
        let requestResult = CapgoUpdater.RequestResult(data: responseData, response: response, error: nil, timedOut: false)
        let updater = ListChannelsRequestCapgoUpdater(requestResult: requestResult)
        updater.setLogger(Logger(withTag: "TestLogger"))
        updater.channelUrl = channelURL.absoluteString

        let result = updater.listChannels()

        XCTAssertEqual(result.error, "decode_error")
        XCTAssertEqual(result.channels.count, 0)
    }

    private func makeChannelURL() throws -> URL {
        var components = URLComponents()
        components.scheme = channelScheme
        components.host = channelHost
        components.path = "/" + channelPathComponent
        return try XCTUnwrap(components.url)
    }
}
