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

    /// The setting as it sounds while the finger still drags the boost.
    private var shownSetting: SoundSetting {
        var shown = setting
        if let draftPercent { shown.gain = SoundSurface.gain(percent: draftPercent) }
        return shown
    }

    var body: some View {
        Section {
            SoundCurveView(setting: shownSetting)
                .opacity(locked ? 0.4 : 1)
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
            // How strongly the preset shapes the sound; Original has nothing
            // to shape, only the boost below.
            Picker(selection: Binding(get: { setting.strength },
                                      set: { setting.strength = $0 })) {
                ForEach(SoundSetting.strengths, id: \.self) { level in
                    Text(verbatim: "\(level)").tag(level)
                }
            } label: {
                Text("Strength")
            }
            .pickerStyle(.segmented)
            .disabled(SoundPresets.preset(setting.presetID).isFlat)
            .accessibilityIdentifier("sound-strength")
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
            Text("Raises the volume by up to 6 dB, about two steps of the volume buttons. A limiter keeps loud passages from distorting.")
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
        // The flat position: the sound as recorded, the boost still free.
        default: "Original"
        }
    }
}

/// What the setting does to the audio track: the curve of its bands from
/// bass to treble (`SoundCurve`), above the line lifted, below lowered; the
/// boost lifts the whole curve. VoiceOver hears the same in words.
struct SoundCurveView: View {
    let setting: SoundSetting
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let samples = 64

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let points = SoundCurve.curve(setting, count: Self.samples)
                func y(_ db: Double) -> CGFloat {
                    let span = SoundCurve.ceilingDB - SoundCurve.floorDB
                    let clamped = min(max(db, SoundCurve.floorDB), SoundCurve.ceilingDB)
                    return size.height * CGFloat((SoundCurve.ceilingDB - clamped) / span)
                }
                func x(_ index: Int) -> CGFloat { size.width * CGFloat(index) / CGFloat(Self.samples - 1) }
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: y(0)))
                zero.addLine(to: CGPoint(x: size.width, y: y(0)))
                context.stroke(zero, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                var line = Path()
                for (index, db) in points.enumerated() {
                    let point = CGPoint(x: x(index), y: y(db))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: y(0)))
                area.addLine(to: CGPoint(x: 0, y: y(0)))
                area.closeSubpath()
                context.fill(area, with: .color(AppTheme.accent.opacity(0.15)))
                context.stroke(line, with: .color(AppTheme.accent), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            .frame(height: 72)
            // The three words would break at the accessibility sizes; the
            // curve's words for VoiceOver carry the same.
            if !dynamicTypeSize.isAccessibilitySize {
                HStack {
                    Text("Bass")
                    Spacer()
                    Text("Voice")
                    Spacer()
                    Text("Treble")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effect on the sound"))
        .accessibilityValue(Text(verbatim: Self.words(SoundCurve.changes(setting))))
        .accessibilityIdentifier("sound-curve")
    }

    /// The changes in words, joined as a list; the unchanged sound says so.
    static func words(_ changes: [SoundCurve.Change]) -> String {
        guard !changes.isEmpty else { return String(localized: "Sound unchanged") }
        return changes.map { change in
            switch change {
            case .raised(.bass): String(localized: "Bass raised")
            case .lowered(.bass): String(localized: "Bass lowered")
            case .raised(.voice): String(localized: "Voice raised")
            case .lowered(.voice): String(localized: "Voice lowered")
            case .raised(.treble): String(localized: "Treble raised")
            case .lowered(.treble): String(localized: "Treble lowered")
            case .louder(let percent): String(localized: "Volume raised to \(percent) %")
            }
        }.formatted(.list(type: .and))
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
        case .off: Text("Original")
        case .preset(let id, let strength, let percent):
            Text(SoundPresetName.name(id))
                + (strength.map { Text(verbatim: " · ") + Text("Strength \($0)") } ?? Text(verbatim: ""))
                + (percent.map { Text(verbatim: " · \($0) %") } ?? Text(verbatim: ""))
        }
    }
}

/// The player's button for the sound effects, beside the speed: coloured
/// while the connected device plays with a setting, as the speed is when
/// it is not 1×.
struct EffectsButton: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var showsSheet = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button { showsSheet = true } label: {
            // At the accessibility sizes the word beside the speed breaks
            // into single letters in the player's narrow cell: the symbol
            // stands alone there and the word stays for VoiceOver.
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "slider.vertical.3")
                        .accessibilityLabel(Text("Effects"))
                } else {
                    Label("Effects", systemImage: "slider.vertical.3")
                }
            }
            .foregroundStyle(SoundSurface.isActive(viewModel.soundSetting, block: viewModel.soundBlock) ? AnyShapeStyle(AppTheme.accent)
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
                    SoundSettingsWrite.save({ fresh in keys.reduce(fresh) { $0.removing(key: $1) } },
                                            into: $book, coordinator: coordinator)
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
                set: { setting in
                    SoundSettingsWrite.save({ SoundBookEdit.defaulting(setting, in: $0) }, into: $book, coordinator: coordinator)
                }))
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
                    set: { setting in
                        SoundSettingsWrite.save({ SoundBookEdit.choosing(setting, forDevice: key, in: $0) },
                                                into: $book, coordinator: coordinator)
                    }))
                Section {
                    Button("Remove device", role: .destructive) {
                        SoundSettingsWrite.save({ $0.removing(key: key) }, into: $book, coordinator: coordinator)
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
    /// The edit applies to the book as it stands now, not to the page's
    /// copy: a device noted while the page is open stays in the book.
    static func save(_ edit: (SoundBook) -> SoundBook, into binding: Binding<SoundBook>, coordinator: PlayerCoordinator) {
        let book = edit(AppStorageKeys.soundBookValue)
        AppStorageKeys.soundBookValue = book
        binding.wrappedValue = book
        coordinator.viewModel?.followSoundRoute(notingRoute: false)
    }
}
