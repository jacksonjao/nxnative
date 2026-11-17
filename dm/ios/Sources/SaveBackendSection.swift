// The settings' "Save sync" choice (SaveBackend.swift), the same on the Mac window, the iPhone launcher and the Apple TV screen: one row per backend, the chosen one checked.
// A backend this device cannot use is shown dimmed with the reason (no iCloud Drive on tvOS, a build without the iCloud container or its entitlement, no iCloud account).
import SwiftUI

struct SaveBackendSection: View {
    @State private var chosen = SaveBackend.current
    @State private var cloudKitProblem: String? = SaveBackend.cloudkit.problem
    @State private var checking = false

    var body: some View {
        Section {
            ForEach(SaveBackend.allCases, id: \.self) { b in
                Button { choose(b) } label: { row(b) }
                    .disabled(problem(b) != nil)
                    #if os(macOS)
                    .buttonStyle(.plain)
                    #endif
            }
        } header: {
            Text(t("Save sync"))
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: check)
    }

    private func problem(_ b: SaveBackend) -> String? { b == .cloudkit ? cloudKitProblem : b.problem }

    private func row(_ b: SaveBackend) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t(title(b)))
                if let p = problem(b) { Text(t(p)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                else if b == .cloudkit && checking { Text(t("Checking iCloud…")).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "checkmark").font(.body.weight(.semibold)).opacity(b == chosen ? 1 : 0)
        }
        .contentShape(Rectangle())
        .opacity(problem(b) == nil ? 1 : 0.5)
    }

    private func title(_ b: SaveBackend) -> String {
        switch b {
        case .local:
            #if os(tvOS)
            return "This Apple TV only"
            #else
            return "This device only (no sync)"
            #endif
        case .drive: return "iCloud Drive folder"
        case .cloudkit: return "iCloud (Mac, iPhone and Apple TV)"
        }
    }

    private var footer: String {
        switch chosen {
        case .local: return "The save stays on this device. Saves replaced by a sync are kept in save-backups."
        case .drive: return "Choose the same iCloud Drive folder in the Mac and iPhone apps (Cloud saves). The Apple TV cannot use it."
        case .cloudkit: return "The save goes through your iCloud account to the Mac, iPhone and Apple TV apps signed with the same container. When both changed, the Mac and iPhone ask which to keep; the Apple TV keeps the newer. A replaced save is kept in save-backups."
        }
    }

    private func choose(_ b: SaveBackend) {
        guard problem(b) == nil else { return }
        chosen = b; SaveBackend.current = b
        if b == .cloudkit { check() }
    }

    private func check() {
        guard SaveBackend.cloudkit.problem == nil else { cloudKitProblem = SaveBackend.cloudkit.problem; return }
        checking = true
        CloudKitSaves.status { why in
            checking = false; cloudKitProblem = why
            if why != nil && chosen == .cloudkit {   // iCloud cannot be used now: the choice stays, and the start falls back to this device (dm_save_backend_env logs why)
                fputs("[dm] save sync: iCloud (CloudKit) chosen but not usable: \(why ?? "")\n", stderr)
            }
        }
    }
}

#if os(tvOS)
// The Apple TV screen speaks the Apple TV's language (TVLauncher.swift); this section's text is kept here, so that the screen's table stays as it is. A text missing here stays in English
private let tvLanguage: String = {
    for tag in Locale.preferredLanguages { let c = Locale(identifier: tag).language.languageCode?.identifier ?? ""; if ["es", "fr", "de", "it", "pt", "ja"].contains(c) { return c }; if c == "en" { break } }
    return "en"
}()
private let tvText: [String: [String: String]] = [
    "Save sync": ["es": "Sincronizar partidas", "fr": "Synchronisation des sauvegardes", "de": "Spielstände synchronisieren", "it": "Sincronizzazione salvataggi", "pt": "Sincronizar jogos salvos", "ja": "セーブデータの同期"],
    "This Apple TV only": ["es": "Solo este Apple TV", "fr": "Cet Apple TV uniquement", "de": "Nur dieses Apple TV", "it": "Solo questo Apple TV", "pt": "Somente esta Apple TV", "ja": "このApple TVのみ"],
    "iCloud Drive folder": ["es": "Carpeta de iCloud Drive", "fr": "Dossier iCloud Drive", "de": "iCloud Drive-Ordner", "it": "Cartella di iCloud Drive", "pt": "Pasta do iCloud Drive", "ja": "iCloud Driveフォルダ"],
    "iCloud (Mac, iPhone and Apple TV)": ["es": "iCloud (Mac, iPhone y Apple TV)", "fr": "iCloud (Mac, iPhone et Apple TV)", "de": "iCloud (Mac, iPhone und Apple TV)", "it": "iCloud (Mac, iPhone e Apple TV)", "pt": "iCloud (Mac, iPhone e Apple TV)", "ja": "iCloud（Mac、iPhone、Apple TV）"],
    "Checking iCloud…": ["es": "Comprobando iCloud…", "fr": "Vérification d'iCloud…", "de": "iCloud wird geprüft …", "it": "Verifica di iCloud…", "pt": "Verificando o iCloud…", "ja": "iCloudを確認中…"],
    "The Apple TV has no iCloud Drive: tvOS has no Files app and no folder picker.": ["es": "El Apple TV no tiene iCloud Drive: tvOS no tiene app Archivos ni selector de carpetas."],
    "No iCloud account on this device: sign in to iCloud in Settings.": ["es": "No hay cuenta de iCloud en este dispositivo: inicia sesión en iCloud en Ajustes."],
    "iCloud is restricted on this device (Screen Time or a configuration profile).": ["es": "iCloud está restringido en este dispositivo (Tiempo de uso o un perfil de configuración)."],
    "iCloud is temporarily unavailable: check the account in Settings.": ["es": "iCloud no está disponible por ahora: revisa la cuenta en Ajustes."],
    "The save stays on this device. Saves replaced by a sync are kept in save-backups.": ["es": "La partida se queda en este dispositivo. Las partidas que reemplaza una sincronización se guardan en save-backups."],
    "The save goes through your iCloud account to the Mac, iPhone and Apple TV apps signed with the same container. When both changed, the Mac and iPhone ask which to keep; the Apple TV keeps the newer. A replaced save is kept in save-backups.": ["es": "La partida va por tu cuenta de iCloud a las apps de Mac, iPhone y Apple TV firmadas con el mismo contenedor. Si cambiaron las dos, el Mac y el iPhone preguntan cuál conservar; el Apple TV se queda con la más reciente. La partida reemplazada se guarda en save-backups."],
]
private func t(_ s: String) -> String {
    if let v = tvText[s]?[tvLanguage] { return v }
    if s.hasPrefix("This build has no iCloud container"), tvLanguage == "es" { return "Esta build no tiene contenedor de iCloud. Compílala con DM_CLOUDKIT_CONTAINER=iCloud.<tu ID> y fírmala con una cuenta de desarrollador de Apple de pago (docs/cloudkit-saves.md)." }
    if s.hasPrefix("This app is not signed for the iCloud container"), tvLanguage == "es" { return "Esta app no está firmada para el contenedor de iCloud: fírmala con una cuenta de desarrollador de pago cuyo perfil tenga iCloud (CloudKit) y ese contenedor." }
    return s
}
#else
private func t(_ s: String) -> String { s }   // English, as the Mac and iPhone launchers
#endif
