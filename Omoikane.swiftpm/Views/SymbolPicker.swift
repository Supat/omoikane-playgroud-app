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
        "equal.circle", "plusminus.circle", "hand.thumbsup", "handbag", "safari", "receipt", "list.bullet.clipboard",
        // food & drink
        "fork.knife", "fork.knife.circle", "cup.and.saucer", "cup.and.saucer.fill", "mug", "takeoutbag.and.cup.and.straw",
        "carrot", "birthday.cake", "wineglass", "waterbottle", "cart", "cart.fill", "basket", "basket.fill", "frying.pan",
        "oven", "microwave", "refrigerator", "stove", "popcorn", "fish", "leaf", "drop", "flame", "bag", "bag.fill",
        // home & utilities
        "house", "house.fill", "building", "building.2", "bed.double", "bed.double.fill", "sofa", "sofa.fill", "chair",
        "chair.lounge", "table.furniture", "lamp.desk", "lamp.floor", "lamp.ceiling", "lightbulb", "lightbulb.fill",
        "washer", "dryer", "dishwasher", "shower", "bathtub", "toilet", "sink", "key", "key.fill", "lock", "lock.open",
        "door.left.hand.closed", "window.vertical.closed", "wrench.and.screwdriver", "wrench", "hammer", "screwdriver",
        "paintbrush", "paintbrush.pointed", "ruler", "level", "bolt", "bolt.fill", "powerplug",
        "poweroutlet.type.b", "wifi", "wifi.router", "antenna.radiowaves.left.and.right", "phone", "phone.fill",
        "iphone", "ipad", "tv", "appletv", "homepod", "fan", "fan.floor", "air.conditioner.horizontal", "thermometer.medium",
        "snowflake", "sun.max", "trash", "trash.fill", "spigot", "cabinet", "fireplace",
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
        "brain", "lungs", "facemask", "figure.run", "figure.walk.motion", "figure.yoga", "figure.pool.swim",
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

    /// Human-readable titles. Anything not listed falls back to the name
    /// with dots as spaces, "fill" dropped and words capitalised.
    private static let titles: [String: String] = [
        "tag": "Tag", "banknote": "Cash", "creditcard": "Credit Card", "wallet.pass": "Wallet", "wallet.bifold": "Billfold",
        "building.columns": "Bank", "yensign.circle": "Yen", "dollarsign.circle": "Dollar", "eurosign.circle": "Euro",
        "sterlingsign.circle": "Pound", "bitcoinsign.circle": "Bitcoin", "chart.line.uptrend.xyaxis": "Investment",
        "chart.line.downtrend.xyaxis": "Loss", "chart.pie": "Pie Chart", "chart.bar": "Bar Chart", "percent": "Interest",
        "arrow.left.arrow.right": "Transfer", "arrow.down.circle": "Income", "arrow.up.circle": "Expense", "gift": "Gift",
        "equal.circle": "Adjustment", "plusminus.circle": "Plus Minus", "hand.thumbsup": "Thumbs Up", "handbag": "Handbag",
        "safari": "Compass", "receipt": "Receipt", "list.bullet.clipboard": "Checklist",
        "fork.knife": "Dining", "fork.knife.circle": "Restaurant", "cup.and.saucer": "Coffee", "mug": "Tea",
        "takeoutbag.and.cup.and.straw": "Takeout", "carrot": "Groceries", "birthday.cake": "Cake", "wineglass": "Drinks",
        "waterbottle": "Water", "cart": "Shopping Cart", "basket": "Basket", "frying.pan": "Cooking", "oven": "Oven",
        "microwave": "Microwave", "refrigerator": "Fridge", "stove": "Stove", "popcorn": "Snacks", "fish": "Fish",
        "leaf": "Leaf", "drop": "Water Drop", "flame": "Gas", "bag": "Bag",
        "house": "Home", "building": "Building", "building.2": "Office", "bed.double": "Bedroom", "sofa": "Living Room",
        "chair": "Chair", "chair.lounge": "Lounge Chair", "table.furniture": "Table", "lamp.desk": "Desk Lamp",
        "lamp.floor": "Floor Lamp", "lamp.ceiling": "Ceiling Lamp", "lightbulb": "Electricity", "washer": "Laundry",
        "dryer": "Dryer", "dishwasher": "Dishwasher", "shower": "Shower", "bathtub": "Bath", "toilet": "Toilet",
        "sink": "Sink", "key": "Key", "lock": "Lock", "lock.open": "Unlocked", "door.left.hand.closed": "Door",
        "window.vertical.closed": "Window", "wrench.and.screwdriver": "Repairs", "wrench": "Wrench", "hammer": "Hammer",
        "screwdriver": "Screwdriver", "paintbrush": "Paint", "paintbrush.pointed": "Art Brush", "ruler": "Ruler",
        "level": "Level", "bolt": "Power", "powerplug": "Plug", "poweroutlet.type.b": "Outlet", "wifi": "Internet",
        "wifi.router": "Router", "antenna.radiowaves.left.and.right": "Broadcast", "phone": "Phone", "iphone": "Mobile",
        "ipad": "Tablet", "tv": "Television", "appletv": "TV Box", "homepod": "Smart Speaker", "fan": "Fan",
        "fan.floor": "Floor Fan", "air.conditioner.horizontal": "Air Conditioner", "thermometer.medium": "Heating",
        "snowflake": "Cooling", "sun.max": "Sunny", "trash": "Garbage", "spigot": "Tap", "cabinet": "Cabinet",
        "fireplace": "Fireplace",
        "tram": "Tram", "train.side.front.car": "Train", "bus": "Bus", "car": "Car", "car.2": "Cars", "fuelpump": "Fuel",
        "ev.charger": "EV Charging", "bicycle": "Bicycle", "scooter": "Scooter", "motorcycle": "Motorcycle",
        "airplane": "Flight", "airplane.departure": "Departure", "airplane.arrival": "Arrival", "ferry": "Ferry",
        "sailboat": "Sailing", "parkingsign": "Parking", "parkingsign.circle": "Parking Lot", "figure.walk": "Walking",
        "figure.walk.circle": "On Foot", "road.lanes": "Highway", "steeringwheel": "Driving", "tirepressure": "Tyres",
        "engine.combustion": "Engine", "wrench.adjustable": "Maintenance", "signpost.right": "Signpost", "mappin": "Place",
        "shippingbox": "Delivery", "tshirt": "Clothing", "shoe": "Shoes", "shoeprints.fill": "Footsteps",
        "eyeglasses": "Glasses", "sunglasses": "Sunglasses", "watch.analog": "Watch", "applewatch": "Smartwatch",
        "laptopcomputer": "Laptop", "desktopcomputer": "Desktop", "keyboard": "Keyboard", "computermouse": "Mouse",
        "headphones": "Headphones", "airpods": "Earbuds", "hifispeaker": "Speaker", "gamecontroller": "Games",
        "arcade.stick": "Arcade", "book": "Books", "books.vertical": "Library", "magazine": "Magazine",
        "newspaper": "Newspaper", "pencil": "Stationery", "pencil.and.outline": "Drawing", "paintpalette": "Art",
        "camera": "Camera", "photo": "Photos", "guitars": "Music Gear", "pianokeys": "Piano", "music.mic": "Karaoke",
        "puzzlepiece": "Hobby", "puzzlepiece.extension": "Add-on", "scissors": "Haircut", "comb": "Grooming",
        "backpack": "Backpack", "suitcase": "Luggage", "umbrella": "Umbrella", "gift.circle": "Present",
        "balloon": "Party", "balloon.2": "Celebration", "party.popper": "Festivity", "teddybear": "Toys",
        "stroller": "Baby", "figure.and.child.holdinghands": "Child", "figure.2.and.child.holdinghands": "Family",
        "heart": "Health", "heart.text.square": "Medical Record", "cross.case": "Medical", "cross.vial": "Lab Test",
        "pills": "Medicine", "pill": "Pill", "bandage": "First Aid", "stethoscope": "Doctor", "syringe": "Vaccine",
        "medical.thermometer": "Thermometer", "ear": "Hearing", "eye": "Eye Care", "eyebrow": "Brows", "mouth": "Dental",
        "nose": "Nose", "brain": "Mental Health", "lungs": "Lungs", "facemask": "Mask", "figure.run": "Running",
        "figure.walk.motion": "Walk", "figure.yoga": "Yoga", "figure.pool.swim": "Swimming", "figure.hiking": "Hiking",
        "figure.outdoor.cycle": "Cycling", "figure.strengthtraining.traditional": "Gym", "dumbbell": "Fitness",
        "sportscourt": "Sports", "soccerball": "Football", "basketball": "Basketball", "baseball": "Baseball",
        "tennis.racket": "Tennis", "figure.golf": "Golf", "figure.skiing.downhill": "Skiing", "sparkles": "Beauty",
        "hands.and.sparkles": "Cleaning", "hand.raised": "Hand", "person": "Personal", "person.2": "Couple",
        "person.3": "Group", "person.crop.circle": "Profile", "figure.stand": "Self", "bed.double.circle": "Sleep",
        "zzz": "Rest", "moon": "Night", "moon.stars": "Late Night",
        "briefcase": "Work", "graduationcap": "Education", "studentdesk": "School", "doc.text": "Document",
        "doc.on.doc": "Copies", "folder": "Folder", "envelope": "Mail", "paperplane": "Send", "printer": "Printing",
        "scanner": "Scanning", "tray": "Inbox", "tray.full": "Archive", "calendar": "Calendar",
        "calendar.badge.clock": "Scheduled", "clock": "Time", "timer": "Timer", "alarm": "Alarm", "bell": "Reminder",
        "megaphone": "Advertising", "speaker.wave.2": "Audio", "globe": "International", "globe.asia.australia": "Asia",
        "network": "Network", "server.rack": "Hosting", "externaldrive": "Storage", "icloud": "Cloud Storage",
        "cloud": "Cloud", "lock.shield": "Security", "shield": "Insurance", "shield.checkered": "Protection",
        "checkmark.seal": "Verified", "rosette": "Award", "signature": "Contract", "person.badge.key": "Membership",
        "person.text.rectangle": "ID Card", "scroll": "Certificate", "text.book.closed": "Textbook",
        "character.book.closed": "Dictionary", "translate": "Language", "textformat": "Typography",
        "ticket": "Tickets", "film": "Movies", "film.stack": "Film Library", "theatermasks": "Theatre",
        "music.note": "Music", "music.note.list": "Playlist", "play.rectangle": "Streaming", "tv.and.mediabox": "Cable",
        "photo.on.rectangle": "Gallery", "map": "Travel", "binoculars": "Sightseeing", "tent": "Camping", "tent.2": "Campsite",
        "mountain.2": "Mountains", "beach.umbrella": "Beach", "water.waves": "Sea", "sun.horizon": "Sunset",
        "cloud.sun": "Weather", "cloud.rain": "Rain", "snowflake.circle": "Winter", "building.columns.circle": "Museum",
        "fossil.shell": "Souvenir", "globe.europe.africa": "Europe", "globe.americas": "Americas",
        "bed.double.circle.fill": "Hotel", "fireworks": "Fireworks", "flag": "Flag", "flag.checkered": "Finish",
        "star": "Favourite", "trophy": "Trophy", "medal": "Medal", "crown": "Premium",
        "pawprint": "Pets", "dog": "Dog", "cat": "Cat", "bird": "Bird", "hare": "Rabbit", "tortoise": "Tortoise",
        "ladybug": "Garden", "ant": "Pest Control", "tree": "Trees", "camera.macro": "Plants", "apple.logo": "Apple",
        "questionmark.circle": "Unknown", "ellipsis.circle": "Other", "circle.grid.2x2": "Grid", "square.grid.2x2": "Apps",
        "archivebox": "Archive Box", "square.split.2x1": "Split", "arrow.triangle.2.circlepath": "Subscription",
        "arrow.counterclockwise": "Refund", "lifepreserver": "Essential", "exclamationmark.triangle": "Warning",
        "info.circle": "Info", "xmark.circle": "Cancelled", "checkmark.circle": "Done", "plus.circle": "Add",
        "minus.circle": "Remove", "asterisk": "Misc", "number": "Number",
    ]

    /// Title for any symbol name: the curated title, or a readable form of
    /// the name itself ("cup.and.saucer.fill" → "Cup And Saucer").
    static func title(for name: String) -> String {
        if let t = titles[name] { return t }
        let base = name.hasSuffix(".fill") ? String(name.dropLast(5)) : name
        if let t = titles[base] { return name.hasSuffix(".fill") ? "\(t) (filled)" : t }
        return base.split(separator: ".").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// The curated list minus anything this OS build does not ship.
    static let available: [String] = {
        var seen = Set<String>()
        return symbols.filter { UIImage(systemName: $0) != nil && seen.insert($0).inserted }
    }()

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Self.available }
        var out = Self.available.filter { $0.contains(q) || Self.title(for: $0).lowercased().contains(q) }
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
                                    // Plain fill, not glass: hundreds of glass cells in a
                                    // scrolling grid stutter.
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(name == selection ? Color.accentColor.opacity(0.25) : Color(.tertiarySystemFill))
                                    )
                                Text(Self.title(for: name))
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Self.title(for: name))
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
            .searchable(text: $query, prompt: "Search glyphs")
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
