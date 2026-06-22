//
//  ContentView.swift
//  ESP32Controller
//
//  Created by Marlon Pérez on 22/06/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ESP32ControllerViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("IPv4 address", text: $viewModel.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)

                    TextField("TCP port", text: $viewModel.port)
                        .keyboardType(.numberPad)

                    HStack {
                        Text("State")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(viewModel.state.title)
                                .fontWeight(.semibold)

                            if let detail = viewModel.state.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                    }

                    HStack {
                        Button("Connect") {
                            viewModel.connect()
                        }
                        .disabled(!viewModel.canConnect)

                        Button("Disconnect", role: .destructive) {
                            viewModel.disconnect()
                        }
                        .disabled(!viewModel.canDisconnect)
                    }
                }

                Section("Send Hex Bytes") {
                    TextField("Example: A5 01 00", text: $viewModel.outgoingHex, axis: .vertical)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .lineLimit(2...4)

                    Toggle("Append delimiter 5C", isOn: $viewModel.appendFrameDelimiter)

                    Button("Send") {
                        viewModel.sendHexBytes()
                    }
                    .disabled(!viewModel.canSend)
                }

                Section {
                    if viewModel.logEntries.isEmpty {
                        Text("No communication yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.logEntries) { entry in
                            CommunicationLogRow(entry: entry)
                        }
                    }
                } header: {
                    HStack {
                        Text("Communication Log")
                        Spacer()
                        Button("Clear") {
                            viewModel.clearLog()
                        }
                        .font(.caption)
                    }
                }
            }
            .navigationTitle("ESP32 TCP")
        }
    }
}

private struct CommunicationLogRow: View {
    let entry: CommunicationLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.direction.rawValue)
                    .font(.caption.monospaced())
                    .fontWeight(.bold)

                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if entry.bytes.isEmpty {
                Text(entry.asciiText)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("ASCII") {
                    Text(entry.asciiText)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                }

                LabeledContent("HEX") {
                    Text(entry.hexText)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
