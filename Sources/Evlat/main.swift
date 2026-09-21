import AppKit
import EvlatApp

// İnce kabuk: kurulumun tamamı AppController'da, çünkü yürütülebilir hedefin
// top-level kodu sınamada koşturulamaz ve panelin yapılandırması sınanmak
// zorunda (PanelConfigTests).
// Teşhis kipi pencereden önce: `--liste` bir şey çizmez, yazdırır ve çıkar.
if CommandLine.arguments.contains("--liste") {
    AppController.printSignalsAndExit()
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
