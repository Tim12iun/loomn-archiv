import LoomnEinklappen
import SwiftUI

// Beispiel: Hauptfenster (Bibliothek) mit Kompagnon-Knopf; der Kompagnon klappt per Doppelklick
// auf seine Kopfleiste zum Viereck ein und per Doppelklick aufs Viereck wieder auf.

@MainActor
final class Model: ObservableObject {
    let fold = LoomnFold(style: LoomnFoldStyle(sizeKey: "beispiel.kompagnon.groesse")) {
        // Zeichen auf dem Viereck (64 × 64)
        Image(systemName: "square.stack.fill").font(.system(size: 26, weight: .bold)).foregroundStyle(.black)
    }
}

struct Bibliothek: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Bibliothek").font(.largeTitle.bold())
                Spacer()
                LoomnCompanionButton(model.fold, id: "kompagnon")
            }
            Text("Hier steht die große Oberfläche.").foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 450)
    }
}

struct Kompagnon: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Kompagnon").font(.headline)
                Spacer()
            }
            .padding(.leading, 78) // Platz für die Fensterknöpfe
            .frame(height: 38)
            .loomnFoldHeader(model.fold)
            Divider()
            List(1...20, id: \.self) { Text("Eintrag \($0)") }
        }
    }
    @ObservedObject var model: Model
}

@main
struct BeispielApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("Bibliothek", id: "main") { Bibliothek(model: model) }

        Window("Kompagnon", id: "kompagnon") {
            LoomnFoldWindow(model.fold) { Kompagnon(model: model) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 290, height: 445)
        .defaultPosition(.bottomTrailing)
    }
}
