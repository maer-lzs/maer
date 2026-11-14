// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The choice of a sound setting: the presets and the gain. One component
/// for the player's sheet, the default and a device's page.
struct SoundChoiceSections: View {
    @Binding var setting: SoundSetting
    /// Why the filter cannot work on what plays now; the choice stays
    /// visible and cannot be changed.
    var block: SoundSurface.Block?
    /// The gain in percent while a finger drags it, not yet written.
    @State private var draftPercent: Double?

    /// Whether the choice is locked for what plays now (`SoundSurface.Block.locks`).
    private var locked: Bool { block?.locks ?? false }

    private var shownPercent: Int {
        SoundSurface.gainPercent(draftPercent.map(SoundSurface.gain(percent:)) ?? setting.gain)
    }

    var body: some View {
        Section {
            ForEach(SoundPresets.all) { preset in
                Button {
                    setting = SoundSurface.choosing(preset: preset.id, in: setting)
                } label: {
                    HStack {
                        Text(SoundPresetName.name(preset.id))
                            .foregroundStyle(.primary)
                        Spacer()
                        if SoundPresets.preset(setting.presetID).id == preset.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppTheme.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(SoundPresets.preset(setting.presetID).id == preset.id ? .isSelected : [])
                .accessibilityIdentifier("sound-preset-\(preset.id)")
            }
        } header: {
            Text("Sound")
        } footer: {
            if let block { SoundBlockText(block: block) }
        }
        .disabled(locked)

        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Volume boost")
                    Spacer()
                    Text(verbatim: "\(shownPercent) %")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // The drag moves a draft; the setting is written once, when
                // the finger lets go.
                PlatformScrubber(value: Binding(get: { draftPercent ?? Double(SoundSurface.gainPercent(setting.gain)) },
                                                set: { draftPercent = $0 }),
                                 range: 100...(SoundSetting.gainLimit * 100),
                                 onEditingChanged: { editing in
                                     guard !editing, let draft = draftPercent else { return }
                                     setting.gain = SoundSurface.gain(percent: draft)
                                     draftPercent = nil
                                 })
                    .accessibilityElement()
                    .accessibilityLabel(Text("Volume boost"))
                    .accessibilityValue(Text(verbatim: "\(shownPercent) %"))
                    .accessibilityAdjustableAction { direction in
                        let step: Double = direction == .increment ? 5 : -5
                        setting.gain = SoundSurface.gain(percent: Double(SoundSurface.gainPercent(setting.gain)) + step)
                    }
                    .accessibilityIdentifier("sound-gain")
                    // The bar draws itself and does not read `isEnabled`:
                    // a blocked choice takes no input and looks it.
                    .takesInput(!locked)
            }
            .opacity(locked ? 0.4 : 1)
        } footer: {
            Text("Raises quiet recordings up to twice the volume. A limiter keeps loud passages from distorting.")
        }
        .disabled(locked)
    }
}

/// The names of the presets, as the surfaces show them.
enum SoundPresetName {
    static func name(_ id: String) -> LocalizedStringKey {
        switch id {
        case "speech": "Clearer Speech"
        case "oldRecordings": "Old Recordings"
        case "louder": "Louder"
        default: "Off"
        }
    }
}

/// The sentence for what the filter cannot reach.
struct SoundBlockText: View {
    let block: SoundSurface.Block

    var body: some View {
        switch block {
        case .station:
            Text("Sound effects do not work on stations. They apply again as soon as an audiobook, an episode or a song plays.")
        case .convertedStream:
            Text("Sound effects do not work on this title: the server sends it converted as a continuous stream. Downloaded, they work.")
        case .tracksUnread:
            Text("Mär could not read the audio of this title, so sound effects do not work on it. They apply from the next title.")
        }
    }
}

/// A device's name as the surfaces show it (`SoundSurface.deviceName`).
enum SoundDeviceName {
    static func text(_ route: SoundRoute) -> Text {
        switch SoundSurface.deviceName(route) {
        case .car(let name): Text("CarPlay: \(name)")
        case .plain(let name): Text(verbatim: name)
        }
    }
}

/// The summary of a device's setting in a list row.
struct SoundSummaryText: View {
    let setting: SoundSetting?

    var body: some View {
        switch SoundSurface.summary(setting) {
        case .followsDefault: Text("Like other devices")
        case .off: Text("Off")
        case .preset(let id, nil): Text(SoundPresetName.name(id))
        case .preset(let id, let percent?):
            Text(SoundPresetName.name(id)) + Text(verbatim: " · \(percent) %")
        }
    }
}

/// The player's button for the sound effects, beside the speed: coloured
/// while the connected device plays with a setting, as the speed is when
/// it is not 1×.
struct EffectsButton: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var showsSheet = false

    var body: some View {
        Button { showsSheet = true } label: {
            Label("Effects", systemImage: "slider.vertical.3")
                .foregroundStyle(SoundSurface.isActive(viewModel.soundSetting) ? AnyShapeStyle(AppTheme.accent)
                                                                              : AnyShapeStyle(.white))
        }
        .accessibilityIdentifier("player-effects")
        .sheet(isPresented: $showsSheet) {
            EffectsSheet(viewModel: viewModel)
                .followsAppearanceChoice()
        }
    }
}

/// The sheet of the sound effects for the device connected now.
struct EffectsSheet: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let route = viewModel.soundRoute {
                        LabeledContent { SoundDeviceName.text(route) } label: { Text("Set for") }
                    } else {
                        LabeledContent { Text("Other devices") } label: { Text("Set for") }
                    }
                } footer: {
                    Text("The change applies to this device. Every device is under Settings, Playback, Sound.")
                }
                SoundChoiceSections(setting: Binding(get: { viewModel.soundSetting },
                                                     set: { viewModel.setSoundSetting($0) }),
                                    block: viewModel.soundBlock)
            }
            .navigationTitle("Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .softTopScrollEdge()
        .presentationDetents([.medium, .large])
    }
}

/// Settings, Playback, Sound: the default for other devices and every
/// device the app has played on.
struct SoundSettingsView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @State private var book = AppStorageKeys.soundBookValue

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    SoundDefaultView(coordinator: coordinator, book: $book)
                } label: {
                    LabeledContent { SoundSummaryText(setting: book.fallback) } label: { Text("Other devices") }
                }
            } header: {
                Text("Default setting")
            } footer: {
                Text("Applies to every device without a setting of its own.")
            }
            Section {
                ForEach(book.devices, id: \.route.key) { device in
                    NavigationLink {
                        SoundDeviceView(coordinator: coordinator, book: $book, key: device.route.key)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                SoundDeviceName.text(device.route)
                                SoundSummaryText(setting: device.setting)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.route.key == coordinator.viewModel?.soundRoute?.key {
                                PillLabel(systemImage: "speaker.wave.2", title: Text("Connected"),
                                          foreground: AppTheme.accent, fill: AppTheme.accent.opacity(0.15))
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let keys = offsets.map { book.devices[$0].route.key }
                    var next = book
                    for key in keys { next = next.removing(key: key) }
                    SoundSettingsWrite.save(next, into: $book, coordinator: coordinator)
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("Every device Mär has played on. Swipe left to remove one; it then follows the default.")
            }
        }
        .navigationTitle("Sound")
        .onAppear { book = AppStorageKeys.soundBookValue }
    }
}

/// The default for other devices.
struct SoundDefaultView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Binding var book: SoundBook

    var body: some View {
        Form {
            SoundChoiceSections(setting: Binding(
                get: { book.fallback },
                set: { SoundSettingsWrite.save(SoundBookEdit.defaulting($0, in: book), into: $book, coordinator: coordinator) }))
        }
        .navigationTitle("Other devices")
    }
}

/// The page of one device: the same choice as the player's sheet, and the
/// way to remove it.
struct SoundDeviceView: View {
    @ObservedObject var coordinator: PlayerCoordinator
    @Binding var book: SoundBook
    let key: String
    @Environment(\.dismiss) private var dismiss

    private var device: SoundDevice? { book.devices.first { $0.route.key == key } }

    var body: some View {
        Form {
            if let device {
                SoundChoiceSections(setting: Binding(
                    get: { device.setting ?? book.fallback },
                    set: { SoundSettingsWrite.save(SoundBookEdit.choosing($0, forDevice: key, in: book),
                                                   into: $book, coordinator: coordinator) }))
                Section {
                    Button("Remove device", role: .destructive) {
                        SoundSettingsWrite.save(book.removing(key: key), into: $book, coordinator: coordinator)
                        dismiss()
                    }
                } footer: {
                    Text("Afterwards the device follows the default again.")
                }
            }
        }
        .navigationTitle(device.map { SoundDeviceName.text($0.route) } ?? Text(verbatim: ""))
    }
}

/// The one write of the settings pages: the book is kept, the page shows
/// it, and the player takes the setting of its route at once.
enum SoundSettingsWrite {
    static func save(_ book: SoundBook, into binding: Binding<SoundBook>, coordinator: PlayerCoordinator) {
        AppStorageKeys.soundBookValue = book
        binding.wrappedValue = book
        coordinator.viewModel?.followSoundRoute(notingRoute: false)
    }
}
