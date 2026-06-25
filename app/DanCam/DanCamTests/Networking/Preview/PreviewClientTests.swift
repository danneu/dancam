import Foundation
import Testing
@testable import DanCam

struct PreviewClientTests {
    @Test(.tags(.networking))
    func emitsFramesWithExactBytesAndSequence() async throws {
        let f0 = Data("zero".utf8)
        let f1 = Data("one".utf8)
        var body = MJPEGWireBuilder.part(f0)
        body.append(MJPEGWireBuilder.part(f1))
        let wire = MJPEGWireBuilder.response(body: body)
        let client = try client(chunks: [wire])

        let frames = try await collect(client.connect(), count: 2)

        #expect(frames == [
            PreviewFrame(sequence: 0, jpeg: f0),
            PreviewFrame(sequence: 1, jpeg: f1),
        ])
    }

    @Test(.tags(.networking))
    func parsesHeadLeftoverBodyStraddle() async throws {
        let frame = Data("jpeg".utf8)
        let wire = MJPEGWireBuilder.response(body: MJPEGWireBuilder.part(frame))
        let split = wire.firstRange(of: Data("\r\n\r\n".utf8))!.upperBound + 3
        let client = try client(chunks: [Data(wire.prefix(split)), Data(wire.dropFirst(split))])

        let frames = try await collect(client.connect(), count: 1)

        #expect(frames == [PreviewFrame(sequence: 0, jpeg: frame)])
    }

    @Test(.tags(.networking))
    func deChunksFramesBeforeMultipartParsing() async throws {
        let f0 = Data("zero".utf8)
        let f1 = Data("one".utf8)
        var body = MJPEGWireBuilder.part(f0)
        body.append(MJPEGWireBuilder.part(f1))
        let chunkedBody = MJPEGWireBuilder.chunked(body, chunkSizes: [7, 3, 11])
        let wire = MJPEGWireBuilder.response(
            headers: [
                ("Content-Type", MJPEGWireBuilder.contentType),
                ("Transfer-Encoding", "chunked"),
            ],
            body: chunkedBody
        )
        let client = try client(chunks: [wire])

        let frames = try await collect(client.connect(), count: 2)

        #expect(frames.map(\.jpeg) == [f0, f1])
    }

    @Test(.tags(.networking))
    func realHyperChunkedFixtureDecodesMockFrameSequence() async throws {
        let fixture = try Data(contentsOf: fixtureURL("preview-wire-chunked.bin"))
        let expectedFrames = try (0..<4).map { index in
            try Data(contentsOf: mockPreviewFrameURL(index: index))
        }
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = PreviewClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            pacedByteStream(fixture)
        }

        let frames = try await collect(client.connect(), count: expectedFrames.count)

        #expect(frames.map(\.sequence) == Array(expectedFrames.indices))
        #expect(frames.map(\.jpeg) == expectedFrames)
    }

    @Test(.tags(.networking))
    func capturedRequestHasPreviewPathHostAndNoConnectionClose() async throws {
        let capture = RequestCapture()
        let frame = Data("jpeg".utf8)
        let wire = MJPEGWireBuilder.response(body: MJPEGWireBuilder.part(frame))
        let baseURL = try #require(URL(string: "http://10.42.0.1:8080"))
        let client = PreviewClient.live(baseURL: baseURL, pinning: .wifi) { _, request in
            await capture.append(request)
            return AsyncStreamHelpers.byteStream([wire])
        }

        _ = try await collect(client.connect(), count: 1)
        let request = try #require(await capture.values().first)
        let requestText = String(decoding: request, as: UTF8.self)

        #expect(requestText.contains("GET /v1/preview/live.mjpeg HTTP/1.1\r\n"))
        #expect(requestText.contains("Host: 10.42.0.1:8080\r\n"))
        #expect(requestText.contains("Connection: close") == false)
    }

    @Test(.tags(.networking))
    func mapsHTTPError() async throws {
        let client = try client(chunks: [MJPEGWireBuilder.response(statusCode: 503, body: Data())])

        await expectPreviewError(.http(503), from: client.connect())
    }

    @Test(.tags(.networking))
    func mapsNonMultipartContentType() async throws {
        let wire = MJPEGWireBuilder.response(
            headers: [("Content-Type", "text/plain")],
            body: Data()
        )
        let client = try client(chunks: [wire])

        await expectPreviewError(.notMultipart("text/plain"), from: client.connect())
    }

    @Test(.tags(.networking))
    func mapsMissingBoundary() async throws {
        let wire = MJPEGWireBuilder.response(
            headers: [("Content-Type", "multipart/x-mixed-replace")],
            body: Data()
        )
        let client = try client(chunks: [wire])

        await expectPreviewError(.missingBoundary, from: client.connect())
    }

    @Test(.tags(.networking))
    func byteStreamFailureMapsToConnectionFailed() async throws {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = PreviewClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            throw URLError(.cannotConnectToHost)
        }

        do {
            _ = try await collect(client.connect(), count: 1)
            Issue.record("Expected PreviewError.connectionFailed.")
        } catch PreviewError.connectionFailed {
        } catch {
            Issue.record("Expected PreviewError.connectionFailed, got \(error).")
        }
    }

    @Test(.tags(.networking))
    func cancelTearsDownByteStream() async throws {
        let firstFrameReceived = AsyncSignal()
        let byteStreamTerminated = AsyncSignal()
        let frame = Data("jpeg".utf8)
        let wire = MJPEGWireBuilder.response(body: MJPEGWireBuilder.part(frame))
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        let client = PreviewClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in
                    Task {
                        await byteStreamTerminated.signal()
                    }
                }
                continuation.yield(wire)
            }
        }

        let task = Task {
            for try await _ in client.connect() {
                await firstFrameReceived.signal()
            }
        }

        await firstFrameReceived.wait()
        task.cancel()
        _ = await task.result
        await byteStreamTerminated.wait()
    }

    private func client(chunks: [Data]) throws -> PreviewClient {
        let baseURL = try #require(URL(string: "http://127.0.0.1:8080"))
        return PreviewClient.live(baseURL: baseURL, pinning: .disabled) { _, _ in
            AsyncStreamHelpers.byteStream(chunks)
        }
    }

    private func collect(
        _ stream: AsyncThrowingStream<PreviewFrame, Error>,
        count: Int
    ) async throws -> [PreviewFrame] {
        var frames: [PreviewFrame] = []

        for try await frame in stream {
            frames.append(frame)
            if frames.count == count {
                break
            }
        }

        return frames
    }

    private func expectPreviewError(
        _ expectedError: PreviewError,
        from stream: AsyncThrowingStream<PreviewFrame, Error>
    ) async {
        do {
            _ = try await collect(stream, count: 1)
            Issue.record("Expected \(expectedError).")
        } catch let error as PreviewError {
            #expect(error == expectedError)
        } catch {
            Issue.record("Expected \(expectedError), got \(error).")
        }
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
            .appending(path: name)
    }

    private func mockPreviewFrameURL(index: Int) -> URL {
        let filename = String(format: "frame_%02d.jpg", index)
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "raspi")
            .appending(path: "service")
            .appending(path: "assets")
            .appending(path: "preview")
            .appending(path: filename)
    }

    private func pacedByteStream(
        _ data: Data,
        chunkSize: Int = 1_024
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var offset = data.startIndex
                while offset < data.endIndex {
                    let end = data.index(offset, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
                    continuation.yield(Data(data[offset..<end]))
                    offset = end
                    try await Task.sleep(for: .milliseconds(1))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
