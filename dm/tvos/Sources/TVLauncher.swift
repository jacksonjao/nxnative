// Apple TV settings screen: the Mac app's settings window (dm/mac/Launcher.swift) on the TV, with the same model, the same rows and the same store (LauncherSettings.swift:
// launcher.<VAR> in the app's preferences, only the choices that differ from the game's default, saved when Play is pressed). Laid out as a tvOS app page: the game's icon,
// name and version with Play on the left, the settings a TV player needs on the right (onTV below) with Reset settings (the Mac's Reset to tested defaults, keeping this Apple TV's language), over the icon blurred. The list scrolls with the Siri Remote or a controller; a choice or a range opens the list of its values, a toggle flips in place.
// Every setting still goes into the environment at Play, shown or not: the hidden ones at the game's tested defaults (or a choice saved earlier).
// After Play, dm_tv_start (front_tv.m) takes the screen away and starts the game.
import SwiftUI
import UIKit
import GameController
import Metal
import MetalFX

private func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }

private enum TVGPU {
    static let device = MTLCreateSystemDefaultDevice()
    static let metalFX: Bool = { guard let d = device, d.supportsFamily(.metal4) else { return false }; return MTLFXSpatialScalerDescriptor.supportsMetal4FX(d) }()   // A15 and later
}

// The screen's language: the Apple TV's, among the main ones (en, es, fr, de, it, pt, ja); English otherwise. The game's own list (launcher.json) is in English
private let uiLanguage: String = {
    for tag in Locale.preferredLanguages {
        let code = Locale(identifier: tag).language.languageCode?.identifier ?? ""
        if ["en", "es", "fr", "de", "it", "pt", "ja"].contains(code) { return code }
    }
    return "en"
}()

// Translations of the screen's text and of the shown settings' labels, options and descriptions, keyed by the English text; a text missing here stays in English
private let translations: [String: [String: String]] = [
    "Play": ["es": "Jugar", "fr": "Jouer", "de": "Spielen", "it": "Gioca", "pt": "Jogar", "ja": "プレイ"],
    "Version": ["es": "Versión", "fr": "Version", "de": "Version", "it": "Versione", "pt": "Versão", "ja": "バージョン"],
    "Reset settings": ["es": "Restablecer ajustes", "fr": "Réinitialiser les réglages", "de": "Einstellungen zurücksetzen", "it": "Ripristina impostazioni", "pt": "Redefinir ajustes", "ja": "設定をリセット"],
    "On": ["es": "Activado", "fr": "Activé", "de": "Ein", "it": "Attivo", "pt": "Ativado", "ja": "オン"],
    "Off": ["es": "Desactivado", "fr": "Désactivé", "de": "Aus", "it": "Disattivo", "pt": "Desativado", "ja": "オフ"],
    "Set at launch": ["es": "Fijado al iniciar", "fr": "Défini au lancement", "de": "Beim Start festgelegt", "it": "Impostato all'avvio", "pt": "Definido ao abrir", "ja": "起動時に設定済み"],
    "Set by an env file": ["es": "Fijado por un archivo env", "fr": "Défini par un fichier env", "de": "Durch eine env-Datei festgelegt", "it": "Impostato da un file env", "pt": "Definido por um arquivo env", "ja": "envファイルで設定済み"],
    // sections
    "Game": ["es": "Juego", "fr": "Jeu", "de": "Spiel", "it": "Gioco", "pt": "Jogo", "ja": "ゲーム"],
    "Controls": ["es": "Controles", "fr": "Commandes", "de": "Steuerung", "it": "Controlli", "pt": "Controles", "ja": "コントロール"],
    "Performance": ["es": "Rendimiento", "fr": "Performances", "de": "Leistung", "it": "Prestazioni", "pt": "Desempenho", "ja": "パフォーマンス"],
    // labels and options of the settings in onTV
    "Console mode": ["es": "Modo de consola", "fr": "Mode de la console", "de": "Konsolenmodus", "it": "Modalità console", "pt": "Modo do console", "ja": "本体モード"],
    "Docked": ["es": "Modo TV", "fr": "Mode TV", "de": "TV-Modus", "it": "Modalità TV", "pt": "Modo TV", "ja": "TVモード"],
    "Handheld": ["es": "Modo portátil", "fr": "Mode portable", "de": "Handheld-Modus", "it": "Modalità portatile", "pt": "Modo portátil", "ja": "携帯モード"],
    "Frame rate": ["es": "Velocidad de fotogramas", "fr": "Fréquence d'images", "de": "Bildrate", "it": "Frequenza fotogrammi", "pt": "Taxa de quadros", "ja": "フレームレート"],
    "Render scale": ["es": "Escala de renderizado", "fr": "Échelle de rendu", "de": "Renderskalierung", "it": "Scala di rendering", "pt": "Escala de renderização", "ja": "レンダリング解像度"],
    "Upscaling": ["es": "Escalado", "fr": "Mise à l'échelle", "de": "Hochskalierung", "it": "Upscaling", "pt": "Escalonamento", "ja": "アップスケーリング"],
    "Standard": ["es": "Estándar", "fr": "Standard", "de": "Standard", "it": "Standard", "pt": "Padrão", "ja": "標準"],
    "Game language": ["es": "Idioma del juego", "fr": "Langue du jeu", "de": "Spielsprache", "it": "Lingua del gioco", "pt": "Idioma do jogo", "ja": "ゲームの言語"],
    "Game rumble": ["es": "Vibración", "fr": "Vibrations", "de": "Vibration", "it": "Vibrazione", "pt": "Vibração", "ja": "振動"],
    "Rumble strength": ["es": "Intensidad de la vibración", "fr": "Intensité des vibrations", "de": "Vibrationsstärke", "it": "Intensità della vibrazione", "pt": "Intensidade da vibração", "ja": "振動の強さ"],
    "Press a button to join": ["es": "Pulsar un botón para unirse", "fr": "Appuyer sur un bouton pour rejoindre", "de": "Zum Beitreten Taste drücken", "it": "Premi un pulsante per partecipare", "pt": "Pressionar um botão para entrar", "ja": "ボタンを押して参加"],
    // descriptions (below) and settings.tsv's notes of the shown settings
    "60 is smoother; 30 is what the Switch ran and uses less power.": ["es": "60 es más fluido; 30 es lo que usaba la Switch y consume menos energía.", "fr": "60 est plus fluide ; 30 correspond à la Switch et consomme moins.", "de": "60 ist flüssiger; 30 entspricht der Switch und braucht weniger Energie.", "it": "60 è più fluido; 30 è quello della Switch e consuma meno.", "pt": "60 é mais fluido; 30 é o da Switch e consome menos energia.", "ja": "60はより滑らか。30はSwitchと同じで、消費電力が少なくなります。"],
    "The size of the 3D picture. Lower is lighter on the GPU but blurrier; text stays sharp.": ["es": "El tamaño de la imagen 3D. Más bajo alivia la GPU pero se ve más borroso; el texto sigue nítido.", "fr": "La taille de l'image 3D. Plus bas allège le GPU mais floute l'image ; le texte reste net.", "de": "Die Größe des 3D-Bildes. Niedriger entlastet die GPU, ist aber unschärfer; Text bleibt scharf.", "it": "La dimensione dell'immagine 3D. Più bassa alleggerisce la GPU ma è più sfocata; il testo resta nitido.", "pt": "O tamanho da imagem 3D. Menor alivia a GPU, mas fica mais borrado; o texto continua nítido.", "ja": "3D画像のサイズ。低くするとGPUの負荷は減りますがぼやけます。文字は鮮明なままです。"],
    "Docked renders at the Switch's TV resolution; handheld at its lower one, lighter on the GPU.": ["es": "El modo TV usa la resolución de televisor de la Switch; el portátil, una menor que alivia la GPU.", "fr": "Le mode TV utilise la résolution TV de la Switch ; le mode portable, une plus basse, plus légère pour le GPU.", "de": "Der TV-Modus nutzt die TV-Auflösung der Switch, der Handheld-Modus eine niedrigere, die die GPU entlastet.", "it": "La modalità TV usa la risoluzione TV della Switch; quella portatile una più bassa, più leggera per la GPU.", "pt": "O modo TV usa a resolução de TV da Switch; o portátil, uma menor, mais leve para a GPU.", "ja": "TVモードはSwitchのTV解像度で、携帯モードはより低い解像度で描画し、GPUの負荷が軽くなります。"],
    "The language of the game's text and voices.": ["es": "El idioma de los textos y voces del juego.", "fr": "La langue des textes et des voix du jeu.", "de": "Die Sprache der Texte und Stimmen im Spiel.", "it": "La lingua dei testi e delle voci del gioco.", "pt": "O idioma dos textos e vozes do jogo.", "ja": "ゲームの文字と音声の言語。"],
    "The game's vibration on a connected controller.": ["es": "La vibración del juego en un control conectado.", "fr": "Les vibrations du jeu sur une manette connectée.", "de": "Die Vibration des Spiels auf einem verbundenen Controller.", "it": "La vibrazione del gioco su un controller collegato.", "pt": "A vibração do jogo em um controle conectado.", "ja": "接続したコントローラーでのゲームの振動。"],
    "How strong the game's vibration is.": ["es": "Qué tan fuerte vibra el juego.", "fr": "La force des vibrations du jeu.", "de": "Wie stark das Spiel vibriert.", "it": "Quanto è forte la vibrazione del gioco.", "pt": "A força da vibração do jogo.", "ja": "ゲームの振動の強さ。"],
    "A controller becomes a player only when you press one of its buttons, so players choose their order.": ["es": "Un control se une como jugador solo al pulsar uno de sus botones, así cada uno elige su turno.", "fr": "Une manette devient un joueur seulement quand on appuie sur l'un de ses boutons : chacun choisit son ordre.", "de": "Ein Controller wird erst zum Spieler, wenn eine seiner Tasten gedrückt wird; so wählen die Spieler ihre Reihenfolge.", "it": "Un controller diventa un giocatore solo quando premi uno dei suoi pulsanti, così i giocatori scelgono l'ordine.", "pt": "Um controle vira jogador só quando você pressiona um dos botões; assim cada um escolhe sua ordem.", "ja": "ボタンを押したコントローラーだけがプレイヤーになり、プレイヤーが順番を選べます。"],
    "Uses more GPU time and can increase heat.": ["es": "Usa más tiempo de GPU y puede aumentar la temperatura.", "fr": "Sollicite davantage le GPU et peut augmenter la chauffe.", "de": "Braucht mehr GPU-Zeit und kann die Wärme erhöhen.", "it": "Usa più tempo della GPU e può aumentare il calore.", "pt": "Usa mais tempo de GPU e pode aumentar o calor.", "ja": "GPUの使用時間が増え、発熱が増えることがあります。"],
]

private func tr(_ english: String) -> String { translations[english]?[uiLanguage] ?? english }

// A game language's name in the screen's language ("español (Latinoamérica)"); the list's English name on an English screen
private func languageName(_ code: String, _ english: String) -> String {
    guard uiLanguage != "en", let n = Locale(identifier: uiLanguage).localizedString(forIdentifier: code) else { return english }
    return n.prefix(1).uppercased() + n.dropFirst()
}

// The game language that matches the Apple TV's languages, in their order, among the ones the game has; nil when none does
private func systemGameLanguage(_ codes: [String]) -> String? {
    for tag in Locale.preferredLanguages {
        let l = Locale(identifier: tag)
        let lang = l.language.languageCode?.identifier ?? "", region = l.region?.identifier ?? "", script = l.language.script?.identifier ?? ""
        let americas = region == "419" || l.region?.continent?.identifier == "019"
        let want: [String]
        switch lang {
        case "en": want = region.isEmpty || americas ? ["en-US", "en-GB"] : ["en-GB", "en-US"]
        case "es": want = americas ? ["es-419", "es"] : ["es", "es-419"]
        case "fr": want = region == "CA" ? ["fr-CA", "fr"] : ["fr", "fr-CA"]
        case "pt": want = region == "PT" ? ["pt", "pt-BR"] : ["pt-BR", "pt"]
        case "zh": want = script == "Hant" || ["TW", "HK", "MO"].contains(region) ? ["zh-Hant", "zh-Hans"] : ["zh-Hans", "zh-Hant"]
        default: want = [lang]
        }
        if let hit = want.first(where: codes.contains) { return hit }
    }
    return nil
}

// What a row does, in a few words, for a shown setting whose list entry has no note (settings.tsv keeps notes for settings with a cost), after docs/settings.md
private let descriptions: [String: String] = [
    "DM_FPS_TARGET": "60 is smoother; 30 is what the Switch ran and uses less power.",
    "DM_RENDER_SCALE": "The size of the 3D picture. Lower is lighter on the GPU but blurrier; text stays sharp.",
    "DM_OPMODE": "Docked renders at the Switch's TV resolution; handheld at its lower one, lighter on the GPU.",
    "DM_LANG": "The language of the game's text and voices.",
    "DM_RUMBLE": "The game's vibration on a connected controller.",
    "DM_RUMBLE_GAIN": "How strong the game's vibration is.",
    "DM_PAD_PRESS_TO_JOIN": "A controller becomes a player only when you press one of its buttons, so players choose their order.",
]

// The settings a player on a couch needs; each appears only when the game has it. The others (diagnostics, the Performance HUD, pipeline and encode switches, rumble cutoff,
// the iPhone's touch and picture rows, the Mac's window and Bluetooth rows) keep the defaults the game was tested with: apply() still puts them into the environment
private let onTV: Set<String> = [
    "DM_OPMODE",            // docked or handheld: resolution against GPU load, the A12's main lever
    "DM_FPS_TARGET",        // 30 or 60 fps, for the games whose frame rate the app controls
    "DM_RENDER_SCALE",      // the 3D picture's size, for the games the app can scale
    "DM_PRESENT_UPSCALE",   // MetalFX to the TV's resolution, on a GPU that has it (A15 and later)
    "DM_LANG",
    "DM_RUMBLE", "DM_RUMBLE_GAIN",
    "DM_PAD_PRESS_TO_JOIN", // several controllers on one TV: players choose their order
]

private extension LauncherModel {
    func offered(_ s: Setting) -> Bool {
        onScreen(s) && visible(s)
    }
    func onScreen(_ s: Setting) -> Bool {   // a row this Apple TV shows, whatever the other rows' values (a sub-setting hidden behind its setting keeps its choice)
        guard onTV.contains(s.env) else { return false }
        return s.env != "DM_PRESENT_UPSCALE" || TVGPU.metalFX
    }
    func tvSections() -> [String] { sections.filter { !tvRows(in: $0).isEmpty } }
    func tvRows(in section: String) -> [Setting] { rows(in: section).filter(offered) }
    func value(_ s: Setting) -> String { values[s.env] ?? s.def }
    func shown(_ s: Setting) -> String {
        let v = value(s)
        switch s.kind {
        case "toggle": return tr(v == s.onValue ? "On" : "Off")
        case "range": return rangeLabel(s, Double(v) ?? 0)
        default: return options(s).first { $0.value == v }?.label ?? v
        }
    }
    func options(_ s: Setting) -> [(value: String, label: String)] {
        if s.kind == "range", let lo = s.min, let hi = s.max, let step = s.step, step > 0, hi >= lo {
            return stride(from: lo, through: hi + step * 0.001, by: step).prefix(201).map { (String(format: "%.2f", $0), rangeLabel(s, $0)) }
        }
        return (s.options ?? []).filter { $0.count == 2 }.map { ($0[0], s.env == "DM_LANG" ? languageName($0[0], $0[1]) : tr($0[1])) }
    }
    func note(_ s: Setting) -> String {
        let n = tr(s.note.isEmpty ? descriptions[s.env] ?? "" : s.note)
        guard fixed.contains(s.env) else { return n }
        return (n.isEmpty ? "" : n + " · ") + tr(fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file")
    }
}

// One setting row, the same shape for every kind so the values line up: title and description on the left, the value and a chevron (kept as room for a toggle) on the right
private struct RowLabel: View {
    let title: String, note: String, value: String, opens: Bool
    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body.weight(.medium))
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 24)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).opacity(opens ? 1 : 0)
        }
        .padding(.vertical, 8)
    }
}

private struct Backdrop: View {
    let icon: UIImage?
    var body: some View {
        ZStack {
            Color.black
            if let icon { Image(uiImage: icon).resizable().scaledToFill().blur(radius: 120).opacity(0.4) }
            Color.black.opacity(0.45)
        }
        .ignoresSafeArea()
    }
}

// A choice's or a range's values, the current one checked; picking one goes back
private struct OptionList: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    let icon: UIImage?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: String?

    private var current: String { s.kind == "range" ? String(format: "%.2f", Double(m.value(s)) ?? 0) : m.value(s) }

    var body: some View {
        List {
            Section {
                ForEach(m.options(s), id: \.value) { o in
                    Button { m.values[s.env] = o.value; dismiss() } label: {
                        HStack {
                            Text(o.label)
                            Spacer()
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).opacity(o.value == current ? 1 : 0)
                        }
                    }
                    .focused($focused, equals: o.value)
                }
            } footer: {
                if !m.note(s).isEmpty { Text(m.note(s)).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.grouped)
        .frame(width: 1000)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Backdrop(icon: icon))
        .navigationTitle(tr(s.label))
        .defaultFocus($focused, current)   // the list opens on the checked value
        .onAppear { DispatchQueue.main.async { focused = current } }
    }
}

private struct TVLauncherView: View {
    @ObservedObject var m: LauncherModel
    let icon: UIImage?
    let tvDefaults: [String: String]   // this Apple TV's defaults where they differ from the list's (the game language from the Apple TV's)
    let play: () -> Void
    @State private var path: [String] = []
    @FocusState private var playFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            HStack(alignment: .center, spacing: 100) {
                game.frame(width: 560).focusSection()       // left from any row reaches Play, whatever its height
                settings.frame(width: 1040).focusSection()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Backdrop(icon: icon))
            .navigationDestination(for: String.self) { env in
                if let s = m.settings.first(where: { $0.env == env }) { OptionList(s: s, m: m, icon: icon) }
            }
        }
        .defaultFocus($playFocused, true)
        .onAppear { DispatchQueue.main.async { playFocused = true } }   // as a child of the game's root view controller, the root's first focus update picks the first row; Play is the screen's default
    }

    private var game: some View {
        VStack(alignment: .leading, spacing: 36) {
            Group {
                if let icon { Image(uiImage: icon).resizable().scaledToFill() }
                else { Rectangle().fill(.quaternary) }
            }
            .frame(width: 440, height: 440)
            .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(info("CFBundleDisplayName") ?? info("CFBundleName") ?? "Game").font(.title2.weight(.bold)).lineLimit(2)
                Text("\(tr("Version")) \(info("CFBundleShortVersionString") ?? "1.0")").font(.callout).foregroundStyle(.secondary)
            }
            Button(action: play) {
                Label(tr("Play"), systemImage: "play.fill").font(.headline).frame(width: 400)
            }
            .buttonStyle(.borderedProminent)
            .focused($playFocused)
        }
    }

    private var settings: some View {
        List {
            ForEach(m.tvSections(), id: \.self) { section in
                Section {
                    ForEach(m.tvRows(in: section)) { s in row(s) }
                } header: {
                    Text(tr(section)).font(.headline).foregroundStyle(.secondary)
                }
            }
            Section {
                Button(action: reset) {
                    Text(tr("Reset settings")).font(.body.weight(.medium)).foregroundStyle(Color(red: 0.85, green: 0.12, blue: 0.12))   // a red that reads on the dark row and on the white focused one (the destructive role's turns pale there)
                        .opacity(changed ? 1 : 0.35)   // the fixed colour does not dim by itself: nothing to reset shows as dimmed
                }
                .disabled(!changed)
            }
        }
        .listStyle(.grouped)
        .scrollClipDisabled()
    }

    // The game's tested defaults, with this Apple TV's own (its language) instead of the packed ones
    private func tvDefault(_ s: Setting) -> String { tvDefaults[s.env] ?? s.def }
    private var changed: Bool {
        m.settings.contains { s in
            guard !m.fixed.contains(s.env) else { return false }
            let v = m.value(s), d = tvDefault(s)
            return s.kind == "range" ? abs((Double(v) ?? .nan) - (Double(d) ?? .nan)) >= 1e-6 : v != d
        }
    }
    private func reset() {
        m.reset()
        for (k, v) in tvDefaults where !m.fixed.contains(k) { m.values[k] = v }
    }

    private func row(_ s: Setting) -> some View {
        let toggle = s.kind == "toggle"
        return Button {
            if toggle { m.values[s.env] = m.value(s) == s.onValue ? s.offValue : s.onValue } else { path.append(s.env) }
        } label: {
            RowLabel(title: tr(s.label), note: m.note(s), value: m.shown(s), opens: !toggle)
        }
        .disabled(m.fixed.contains(s.env))
    }
}

// The settings the earlier Apple TV screen kept (tv.setting.<VAR>, tv.language, tv.mode) become the Mac and iPhone store's (launcher.<VAR>), once
private func migrateTVChoices(_ d: UserDefaults = .standard) {
    for (k, v) in d.dictionaryRepresentation() where k.hasPrefix("tv.setting.") {
        let key = "launcher." + k.dropFirst("tv.setting.".count)
        if d.object(forKey: key) == nil, let s = v as? String { d.set(s, forKey: key) }
        d.removeObject(forKey: k)
    }
    for (old, env) in [("tv.language", "DM_LANG"), ("tv.mode", "DM_OPMODE")] {
        guard let v = d.string(forKey: old) else { continue }
        if d.object(forKey: "launcher." + env) == nil { d.set(v, forKey: "launcher." + env) }
        d.removeObject(forKey: old)
    }
    d.removeObject(forKey: "tv.window.advanced")   // the earlier screen's Advanced settings fold
}

// front_ios.m: shows the settings over the root view controller and calls done once the settings are in the environment and the player is chosen; false (done is not called)
// when there is no launcher. tvOS has no env file the player can edit, so DM_LAUNCHER=0 comes only from the build (DM_ENV_FILE)
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    migrateTVChoices()
    let model = LauncherModel(file.settings)
    // A setting this screen does not show takes the game's tested default, not a choice saved earlier (an older screen showed more: a Performance HUD turned on there stayed on,
    // with no row to turn it off); Play then forgets the saved choice (apply keeps no default). An env file's or the launch's value still wins
    for s in file.settings where !model.onScreen(s) && !model.fixed.contains(s.env) && model.values[s.env] != s.def {
        fputs("launcher: \(s.env)=\(model.values[s.env] ?? "") saved earlier, not on this screen: back to \(s.def)\n", stderr)
        model.values[s.env] = s.def
    }
    // The game language defaults to the Apple TV's, when the game has it: shown with no choice saved, brought back by Reset settings, and not saved when Play finds it
    // (so it follows the Apple TV's language later); a language the player picked is saved as any choice
    var tvDefaults: [String: String] = [:]
    if let lang = file.settings.first(where: { $0.env == "DM_LANG" }), let match = systemGameLanguage((lang.options ?? []).compactMap(\.first)) {
        tvDefaults["DM_LANG"] = match
        if !model.fixed.contains("DM_LANG"), UserDefaults.standard.object(forKey: "launcher.DM_LANG") == nil {
            model.values["DM_LANG"] = match
            fputs("launcher: game language \(match) from the Apple TV's languages\n", stderr)
        }
    }
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let root = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    (root as? GCEventViewController)?.controllerUserInteractionEnabled = true   // controllers move the focus on this screen; the game takes them back at start (dm_tv_start, front_tv.m)
    let icon = Bundle.main.resourceURL.flatMap { UIImage(contentsOfFile: $0.appendingPathComponent("dm/icon.jpg").path) }   // build_ipa.sh: the game's icon
    var host: UIViewController?
    let h = UIHostingController(rootView: TVLauncherView(m: model, icon: icon, tvDefaults: tvDefaults) {
        guard let h = host else { return }
        host = nil
        model.apply()
        for (k, v) in tvDefaults where !model.fixed.contains(k) && model.values[k] == v { UserDefaults.standard.removeObject(forKey: "launcher." + k) }   // a TV default is not a choice
        dm_tv_start(Unmanaged.passUnretained(h).toOpaque(), viewController, done)
    })
    h.overrideUserInterfaceStyle = .dark
    host = h
    // A child of the root view controller, not a presented one: tvOS's Back button dismisses a presented controller, which left the root's empty (black) game view
    // with nothing to start the game. As part of the root, Back on this screen goes to the Apple TV's Home screen, as in any app; in a list of values it still goes back
    root.addChild(h)
    h.view.frame = root.view.bounds
    h.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    root.view.addSubview(h.view)
    h.didMove(toParent: root)
    root.setNeedsFocusUpdate()
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
