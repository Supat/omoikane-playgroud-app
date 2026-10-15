import SwiftUI

/// Glyph picker for categories. A searchable grid of SF Symbols that suit
/// a household ledger; typing a full symbol name that isn't in the list
/// (e.g. "fork.knife.circle") offers it too, so nothing is locked out.
/// Stock controls only: LazyVGrid of Buttons, .searchable, Return picks
/// the first match.
struct SymbolPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String
    @State private var query = ""

    /// Curated for a household ledger. Validated against the OS at runtime
    /// (see `available`) so a name missing on this system never shows blank.
    static let symbols: [String] = [
        // money & accounts
        "tag", "tag.fill", "banknote", "banknote.fill", "creditcard", "creditcard.fill", "wallet.pass", "wallet.bifold",
        "building.columns", "building.columns.fill", "yensign.circle", "yensign.circle.fill", "dollarsign.circle", "eurosign.circle",
        "sterlingsign.circle", "bitcoinsign.circle", "chart.line.uptrend.xyaxis", "chart.line.downtrend.xyaxis", "chart.pie",
        "chart.bar", "percent", "arrow.left.arrow.right", "arrow.down.circle", "arrow.up.circle", "gift", "gift.fill",
        "equal.circle", "plusminus.circle", "coins", "hand.thumbsup", "handbag", "safari", "receipt", "list.bullet.clipboard",
        // food & drink
        "fork.knife", "fork.knife.circle", "cup.and.saucer", "cup.and.saucer.fill", "mug", "takeoutbag.and.cup.and.straw",
        "carrot", "birthday.cake", "wineglass", "waterbottle", "cart", "cart.fill", "basket", "basket.fill", "frying.pan",
        "oven", "microwave", "refrigerator", "stove", "popcorn", "fish", "leaf", "drop", "flame", "bag", "bag.fill",
        // home & utilities
        "house", "house.fill", "building", "building.2", "bed.double", "bed.double.fill", "sofa", "sofa.fill", "chair",
        "chair.lounge", "table.furniture", "lamp.desk", "lamp.floor", "lamp.ceiling", "lightbulb", "lightbulb.fill",
        "washer", "dryer", "dishwasher", "shower", "bathtub", "toilet", "sink", "key", "key.fill", "lock", "lock.open",
        "door.left.hand.closed", "window.vertical.closed", "wrench.and.screwdriver", "wrench", "hammer", "screwdriver",
        "paintbrush", "paintbrush.pointed", "paintroller", "ruler", "level", "bolt", "bolt.fill", "powerplug",
        "poweroutlet.type.b", "wifi", "wifi.router", "antenna.radiowaves.left.and.right", "phone", "phone.fill",
        "iphone", "ipad", "tv", "appletv", "homepod", "fan", "fan.floor", "air.conditioner.horizontal", "thermometer.medium",
        "snowflake", "sun.max", "trash", "trash.fill", "recycle", "spigot", "cabinet", "fireplace", "candle",
        // transport
        "tram", "tram.fill", "train.side.front.car", "bus", "bus.fill", "car", "car.fill", "car.2", "fuelpump", "fuelpump.fill",
        "ev.charger", "bicycle", "scooter", "motorcycle", "airplane", "airplane.departure", "airplane.arrival", "ferry",
        "sailboat", "parkingsign", "parkingsign.circle", "figure.walk", "figure.walk.circle", "road.lanes",
        "steeringwheel", "tirepressure", "engine.combustion", "wrench.adjustable", "signpost.right", "mappin",
        // shopping & things
        "shippingbox", "shippingbox.fill", "tshirt", "tshirt.fill", "shoe", "shoeprints.fill", "eyeglasses", "sunglasses",
        "watch.analog", "applewatch", "laptopcomputer", "desktopcomputer", "keyboard", "computermouse", "headphones",
        "airpods", "hifispeaker", "gamecontroller", "gamecontroller.fill", "arcade.stick", "book", "book.fill", "books.vertical",
        "magazine", "newspaper", "pencil", "pencil.and.outline", "paintpalette", "paintpalette.fill", "camera", "camera.fill",
        "photo", "guitars", "pianokeys", "music.mic", "puzzlepiece", "puzzlepiece.extension", "scissors", "comb",
        "backpack", "suitcase", "suitcase.fill", "umbrella", "umbrella.fill", "gift.circle", "balloon", "balloon.2",
        "party.popper", "teddybear", "stroller", "figure.and.child.holdinghands", "figure.2.and.child.holdinghands",
        // personal & health
        "heart", "heart.fill", "heart.text.square", "cross.case", "cross.case.fill", "cross.vial", "pills", "pills.fill",
        "pill", "bandage", "stethoscope", "syringe", "medical.thermometer", "ear", "eye", "eyebrow", "mouth", "nose",
        "brain", "lungs", "tooth", "facemask", "figure.run", "figure.walk.motion", "figure.yoga", "figure.pool.swim",
        "figure.hiking", "figure.outdoor.cycle", "figure.strengthtraining.traditional", "dumbbell", "dumbbell.fill",
        "sportscourt", "soccerball", "basketball", "baseball", "tennis.racket", "figure.golf", "figure.skiing.downhill",
        "sparkles", "drop.fill", "hands.and.sparkles", "hand.raised", "person", "person.fill", "person.2", "person.3",
        "person.crop.circle", "figure.stand", "bed.double.circle", "zzz", "moon", "moon.stars",
        // work, education & services
        "briefcase", "briefcase.fill", "graduationcap", "graduationcap.fill", "studentdesk", "building.2.fill",
        "doc.text", "doc.text.fill", "doc.on.doc", "folder", "folder.fill", "envelope", "envelope.fill", "paperplane",
        "printer", "scanner", "tray", "tray.full", "calendar", "calendar.badge.clock", "clock", "clock.fill", "timer",
        "alarm", "bell", "bell.fill", "megaphone", "speaker.wave.2", "globe", "globe.asia.australia", "network",
        "server.rack", "externaldrive", "icloud", "cloud", "lock.shield", "shield", "shield.checkered",
        "checkmark.seal", "checkmark.seal.fill", "rosette", "signature", "person.badge.key", "person.text.rectangle",
        "scroll", "text.book.closed", "character.book.closed", "translate", "textformat",
        // leisure, travel & culture
        "ticket", "ticket.fill", "film", "film.stack", "theatermasks", "theatermasks.fill", "music.note", "music.note.list",
        "play.rectangle", "tv.and.mediabox", "photo.on.rectangle", "map", "map.fill", "binoculars", "tent", "tent.2",
        "mountain.2", "beach.umbrella", "water.waves", "sun.horizon", "cloud.sun", "cloud.rain", "snowflake.circle",
        "building.columns.circle", "fossil.shell", "globe.europe.africa", "globe.americas", "bed.double.circle.fill",
        "fireworks", "flag", "flag.fill", "flag.checkered", "star", "star.fill", "trophy", "medal", "crown",
        // pets & nature
        "pawprint", "pawprint.fill", "dog", "cat", "bird", "fish.fill", "hare", "tortoise", "ladybug", "ant",
        "leaf.fill", "tree", "camera.macro", "carrot.fill", "apple.logo",
        // misc
        "questionmark.circle", "ellipsis.circle", "circle.grid.2x2", "square.grid.2x2", "archivebox", "archivebox.fill",
        "square.split.2x1", "arrow.triangle.2.circlepath", "arrow.counterclockwise", "lifepreserver", "exclamationmark.triangle",
        "info.circle", "xmark.circle", "checkmark.circle", "plus.circle", "minus.circle", "asterisk", "number",
    ]

    /// The curated list minus anything this OS build does not ship.
    static let available: [String] = {
        var seen = Set<String>()
        return symbols.filter { UIImage(systemName: $0) != nil && seen.insert($0).inserted }
    }()

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Self.available }
        var out = Self.available.filter { $0.contains(q) }
        // Exact names outside the curated set still work.
        if !out.contains(q), UIImage(systemName: q) != nil { out.insert(q, at: 0) }
        return out
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                    ForEach(filtered, id: \.self) { name in
                        Button {
                            selection = name
                            dismiss()
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: name)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .glassEffect(name == selection ? .regular.tint(.accentColor.opacity(0.5)).interactive()
                                                                   : .regular.interactive(),
                                                 in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(name)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                        .accessibilityAddTraits(name == selection ? .isSelected : [])
                    }
                }
                .padding()
                if filtered.isEmpty {
                    Text("No symbol matches \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .searchable(text: $query, prompt: "Search symbols")
            .onSubmit(of: .search) {
                if let first = filtered.first { selection = first; dismiss() }
            }
            .navigationTitle("Glyph")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
    }
}
