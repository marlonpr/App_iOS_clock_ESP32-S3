//
//  ESP32ControllerTests.swift
//  ESP32ControllerTests
//
//  Created by Marlon Pérez on 22/06/26.
//

import Testing
import Foundation
import Network
@testable import ESP32Controller

struct ESP32ControllerTests {

    @MainActor
    @Test func staleFailedStateDoesNotOverwriteActiveConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleStateHandler(.failed(.posix(.ECONNRESET)))
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(states.last == .connecting)
        #expect(!states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        })

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func staleCancelledStateDoesNotClearNewConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        let staleStateHandler = try #require(connections[0].stateUpdateHandler)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleStateHandler(.cancelled)
        await Task.yield()

        #expect(states.last == .connecting)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func staleReceiveDoesNotEmitFramesOrContinueReceiveLoop() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var frames: [[UInt8]] = []
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let staleReceive = try #require(connections[0].lastReceiveCompletion)
        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)

        staleReceive(Data([0x01, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(connections[0].receiveCallCount == 1)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()
        let firstActiveReceive = try #require(connections[1].lastReceiveCompletion)
        firstActiveReceive(Data([0x02]), nil, false, nil)
        await Task.yield()

        #expect(frames.isEmpty)
        #expect(connections[1].receiveCallCount == 2)

        let secondActiveReceive = try #require(connections[1].lastReceiveCompletion)
        secondActiveReceive(Data([0x03, ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[0x02, 0x03, ESP32TCPClient.frameDelimiter]])
        #expect(connections[1].receiveCallCount == 3)
    }

    @MainActor
    @Test func staleSendCompletionIsIgnored() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var sendResults: [Error?] = []

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        client.send(Data([0x01])) { sendResults.append($0) }
        let staleSendCompletion = try #require(connections[0].lastSendCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleSendCompletion(.posix(.ECONNRESET))
        await Task.yield()

        #expect(sendResults.isEmpty)

        client.send(Data([0x02])) { sendResults.append($0) }
        let activeSendCompletion = try #require(connections[1].lastSendCompletion)
        activeSendCompletion(nil)
        await Task.yield()

        #expect(sendResults.count == 1)
        #expect(sendResults[0] == nil)
    }

    @MainActor
    @Test func activeReceiveErrorClearsConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        var frames: [[UInt8]] = []
        client.onStateChange = { states.append($0) }
        client.onFrameReceived = { frames.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(Data([0xAA]), nil, false, .posix(.ECONNRESET))
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(frames.isEmpty)
        #expect(states.contains { state in
            if case .failed = state {
                return true
            }
            return false
        })

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        let nextReceive = try #require(connections[1].lastReceiveCompletion)
        nextReceive(Data([ESP32TCPClient.frameDelimiter]), nil, false, nil)
        await Task.yield()

        #expect(frames == [[ESP32TCPClient.frameDelimiter]])
    }

    @MainActor
    @Test func activeReceiveCompletionClearsConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        #expect(connections[0].cancelCallCount == 1)
        #expect(states.last == .disconnected)

        var sendResult: Error?
        client.send(Data([0x01])) { sendResult = $0 }

        #expect(sendResult is TCPClientError)
        #expect(connections[0].sendCallCount == 0)
    }

    @MainActor
    @Test func staleReceiveTerminationDoesNotClearNewConnection() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }
        var states: [TCPConnectionState] = []
        client.onStateChange = { states.append($0) }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()
        let staleReceive = try #require(connections[0].lastReceiveCompletion)

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        staleReceive(nil, nil, true, nil)
        await Task.yield()

        #expect(states.last == .connecting)
        #expect(connections[0].cancelCallCount == 1)

        connections[1].stateUpdateHandler?(.ready)
        await Task.yield()

        #expect(states.last == .connected)
        #expect(connections[1].receiveCallCount == 1)
    }

    @MainActor
    @Test func sendAfterReceiveTerminationReportsNotConnected() async throws {
        var connections: [FakeTCPConnection] = []
        let client = ESP32TCPClient { _, _ in
            let connection = FakeTCPConnection()
            connections.append(connection)
            return connection
        }

        client.connect(host: "192.168.4.1", port: ESP32TCPClient.defaultPort)
        connections[0].stateUpdateHandler?(.ready)
        await Task.yield()

        let receive = try #require(connections[0].lastReceiveCompletion)
        receive(nil, nil, true, nil)
        await Task.yield()

        var sendResult: Error?
        client.send(Data([0x01])) { sendResult = $0 }

        #expect(sendResult is TCPClientError)
        #expect(connections[0].sendCallCount == 0)
    }
}

private final class FakeTCPConnection: TCPConnection {
    typealias ReceiveCompletion = @Sendable (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

    var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?
    var cancelCallCount = 0
    var receiveCallCount = 0
    var sendCallCount = 0
    var lastReceiveCompletion: ReceiveCompletion?
    var lastSendCompletion: ((NWError?) -> Void)?

    func start(queue: DispatchQueue) {}

    func cancel() {
        cancelCallCount += 1
    }

    func send(
        content: Data?,
        contentContext: NWConnection.ContentContext,
        isComplete: Bool,
        completion: NWConnection.SendCompletion
    ) {
        sendCallCount += 1

        guard case let .contentProcessed(sendCompletion) = completion else {
            return
        }

        lastSendCompletion = sendCompletion
    }

    func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        completion: @escaping ReceiveCompletion
    ) {
        receiveCallCount += 1
        lastReceiveCompletion = completion
    }
}
