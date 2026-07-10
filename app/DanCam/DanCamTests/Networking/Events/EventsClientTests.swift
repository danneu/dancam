import Foundation
import Testing
@testable import DanCam

struct EventsClientTests {
    @Test(.tags(.networking))
    func emitsDecodedEvents() async throws {
        var body = SSEWireBuilder.event(
            id: 1,
            data: Data("{\"type\":\"snapshot\",\"recorder\":{\"phase\":\"idle\",\"session\":7,\"current_segment\":null,\"detail\":null},\"camera_state\":\"running\",\"boot_id\":\"boot-123\",\"uptime_s\":1,\"storage\":null,\"temp_c\":{\"soc\":{\"current\":null,\"max\":null},\"sensor\":{\"current\":null,\"max\":null}},\"mem\":null}".utf8)
        )
        body.append(SSEWireBuilder.event(
            id: 2,
            data: Data("{\"type\":\"heartbeat\",\"t_ms\":12000}".utf8)
        ))
        let client = try client(chunks: [SSEWireBuilder.response(body: body)])

        let events = try await collect(client.connect(), count: 2)

        #expect(events == [
            .snapshot(CameraSamples.world(storage: nil, time: nil)),
            .heartbeat(tMs: 12_000),
        ])
    }

    @Test(.tags(.networking))
    func deChunksEventsBeforeSSEParsing() async throws {
        let body = SSEWireBuilder.event(
            data: Data("{\"type\":\"storage_changed\",\"used\":1,\"total\":2}".utf8)
        )
        let chunkedBody = MJPEGWireBuilder.chunked(body, chunkSizes: [3, 2])
        let wire = SSEWireBuilder.response(
            headers: [
                ("Content-Type", "text/event-stream"),
                ("Transfer-Encoding", "chunked"),
            ],
            body: chunkedBody
        )
        let client = try client(chunks: [wire])

        let events = try await collect(client.connect(), count: 1)

        #expect(events == [.storageChanged(used: 1, total: 2)])
    }

    @Test(.tags(.networking))
    func capturedRequestHasEventsPathAcceptHeaderAndNoConnectionClose() async throws {
        let capture = RequestCapture()
        let body = SSEWireBuilder.event(data: Data("{\"type\":\"heartbeat\",\"t_ms\":1}".utf8))
        let baseURL = try #require(URL(string: "http://10.42.0.1:8080"))
        let client = EventsClient.live(baseURL: baseURL, pinning: .wifi) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([SSEWireBuilder.response(body: body)])
        }

        _ = try await collect(client.connect(), count: 1)
        let request = try #require(await capture.values().first)
        let requestText = String(decoding: request, as: UTF8.self)

        #expect(requestText.contains("GET /v1/events HTTP/1.1\r\n"))
        #expect(requestText.contains("Host: 10.42.0.1:8080\r\n"))
        #expect(requestText.contains("Accept: text/event-stream\r\n"))
        #expect(requestText.contains("Connection: close") == false)
    }

    @Test(.tags(.networking))
    func mapsHTTPError() async throws {
        let client = try client(chunks: [SSEWireBuilder.response(statusCode: 503, body: Data())])

        await expectEventsError(.http(503), from: client.connect())
    }

    @Test(.tags(.networking))
    func mapsNonEventStreamContentType() async throws {
        let wire = SSEWireBuilder.response(
            headers: [("Content-Type", "application/json")],
            body: Data()
        )
        let client = try client(chunks: [wire])

        await expectEventsError(.notEventStream("application/json"), from: client.connect())
    }

    @Test(.tags(.networking))
    func mapsByteStreamFailure() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = EventsClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await collect(client.connect(), count: 1)
            Issue.record("Expected EventsError.connectionFailed.")
        } catch EventsError.connectionFailed {
        } catch {
            Issue.record("Expected EventsError.connectionFailed, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func cancelTearsDownByteStream() async throws {
        let firstEventReceived = AsyncSignal()
        let byteStreamTerminated = AsyncSignal()
        let body = SSEWireBuilder.event(data: Data("{\"type\":\"heartbeat\",\"t_ms\":1}".utf8))
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = EventsClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in
                    Task {
                        await byteStreamTerminated.signal()
                    }
                }
                continuation.yield(SSEWireBuilder.response(body: body))
            }
        }

        let task = Task {
            for try await _ in client.connect() {
                await firstEventReceived.signal()
            }
        }

        await firstEventReceived.wait()
        task.cancel()
        _ = await task.result
        await byteStreamTerminated.wait()
    }

    private func client(chunks: [Data]) throws -> EventsClient {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        return EventsClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            AsyncStreamHelpers.byteStream(chunks)
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<CameraEvent, Error>,
        count: Int
    ) async throws -> [CameraEvent] {
        var events: [CameraEvent] = []

        for try await event in stream {
            events.append(event)
            if events.count == count {
                break
            }
        }

        return events
    }

    private func expectEventsError(
        _ expectedError: EventsError,
        from stream: AsyncThrowingStream<CameraEvent, Error>
    ) async {
        do {
            _ = try await collect(stream, count: 1)
            Issue.record("Expected \(expectedError).")
        } catch let error as EventsError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected \(expectedError), got \(error).")
        }
    }
}
