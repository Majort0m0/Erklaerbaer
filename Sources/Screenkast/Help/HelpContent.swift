import SwiftUI

/// One part of a help page. Texts may use inline Markdown (**fett**, *kursiv*, `Code`).
enum HelpBlock {
    case text(String)
    case heading(String)
    case bullets([String])
    case steps([String])
    case tip(String)
    case note(String)
    case keys([(String, String)])

    var searchText: String {
        switch self {
        case .text(let s), .heading(let s), .tip(let s), .note(let s): return s
        case .bullets(let a), .steps(let a): return a.joined(separator: " ")
        case .keys(let k): return k.map { $0.0 + " " + $0.1 }.joined(separator: " ")
        }
    }
}

struct HelpTopic: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let summary: String
    let blocks: [HelpBlock]

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return ([title, summary] + blocks.map(\.searchText)).contains { $0.lowercased().contains(q) }
    }
}

/// The content of the "Erklärbär-Hilfe" (also written to ANLEITUNG.md with `--helpmarkdown`).
enum HelpContent {
    static let topics: [HelpTopic] = [
        start, recording, newProject, editor, cutting, zoomCursor, camera, textsMedia, markings, sound,
        captions, assistants, style, export, screenshots, projects, shortcuts, troubleshooting, about,
    ]

    static func topic(_ id: String) -> HelpTopic? { topics.first { $0.id == id } }

    // MARK: Erste Schritte

    static let start = HelpTopic(
        id: "start", title: "Erste Schritte", icon: "sparkles", color: .purple,
        summary: "Aufnehmen, verbessern, exportieren – so entsteht dein erstes Erklärvideo.",
        blocks: [
            .text("Erklärbär nimmt deinen Bildschirm auf und macht daraus ein fertiges Erklärvideo: Er zoomt automatisch dorthin, wo du klickst, zeichnet einen ruhigen Mauszeiger, legt einen schönen Hintergrund unter die Aufnahme und blendet auf Wunsch deine Kamera ein. Danach schneidest du im Editor, fügst Texte, Untertitel und Musik hinzu und exportierst das Video."),
            .heading("In drei Schritten zum Video"),
            .steps([
                "**Aufnehmen:** Links auf der Startseite die Quelle wählen (Bildschirm, Fenster oder Bereich), Mikrofon und Kamera einstellen und auf **Aufnahme starten** klicken – oder überall **⌘⇧2** drücken. Nochmal **⌘⇧2** (oder das ●-Symbol in der Menüleiste) beendet die Aufnahme.",
                "**Verbessern:** Nach der Aufnahme fragt Erklärbär „Was möchtest du erstellen?“ und poliert das Video auf Wunsch automatisch auf: Stimme verbessern, Untertitel, Füllwörter und Pausen entfernen, Zooms, Pegel. Alles lässt sich danach im Editor ändern oder zurücknehmen.",
                "**Exportieren:** Oben rechts auf **Exportieren** (⌘E) klicken, eine Vorlage wählen (z. B. YouTube oder Hochformat) – fertig ist das MP4.",
            ]),
            .heading("Beim ersten Start"),
            .bullets([
                "macOS fragt nach der Berechtigung **Bildschirm- und Systemaudioaufnahme**. Erlauben und Erklärbär danach einmal neu starten – die Startseite bietet dafür einen Knopf an.",
                "Kamera und Mikrofon werden beim ersten Benutzen erfragt.",
                "Für das Einblenden von Tastenkürzeln braucht Erklärbär die Berechtigung **Bedienungshilfen**.",
            ]),
            .tip("Alles, was du im Editor machst, lässt sich mit **⌘Z** zurücknehmen. Probier ruhig alles aus – die Originalaufnahme wird nie verändert."),
            .text("Links in dieser Hilfe findest du alle Themen; oben im Suchfeld kannst du nach Stichworten suchen, z. B. „Untertitel“, „Zoom“ oder „Atem“."),
        ])

    // MARK: Aufnehmen

    static let recording = HelpTopic(
        id: "recording", title: "Aufnehmen", icon: "record.circle", color: .red,
        summary: "Quelle, Ton, Kamera, Countdown, Notizen und alles rund um die Aufnahme.",
        blocks: [
            .heading("Was wird aufgenommen?"),
            .bullets([
                "**Quelle:** ein ganzer Bildschirm, ein einzelnes Fenster oder über **Bereich des Bildschirms wählen …** ein frei aufgezogenes Rechteck. Fenster aus dem Stage Manager und von anderen Schreibtischen stehen unter „Weitere Fenster“; ein gewähltes Fenster wird beim Start nach vorne geholt.",
                "**Mikrofon:** deine Stimme. „Aus“ nimmt ohne Mikrofon auf.",
                "**Systemaudio:** der Ton von Apps und Browser (ohne Erklärbär selbst).",
                "**Kamera:** dein Kamerabild, später als Kamerablase im Video. Die runde Vorschau auf der Startseite zeigt, wie du zu sehen bist.",
                "**Zweites Fenster:** ein weiteres Fenster wird gleichzeitig aufgenommen und erscheint im Editor als Bild im Bild – verschiebbar und nur zeitweise einblendbar.",
            ]),
            .note("Der Mauszeiger wird nicht mitgefilmt, sondern später neu gezeichnet – deshalb kann Erklärbär ihn glätten, vergrößern, hervorheben oder ausblenden."),
            .heading("Hilfen während der Aufnahme"),
            .bullets([
                "**Countdown 3-2-1** zählt vor dem Start herunter (wird nicht aufgenommen).",
                "**Tastenkürzel einblenden** zeichnet Kürzel mit ⌘, ⌃ oder ⌥ auf und zeigt sie im Video. Normal getippter Text wird nie gespeichert.",
                "**Sprechernotizen** erscheinen als schwebendes Fenster mit Teleprompter – auch dieses Fenster wird nicht aufgenommen.",
                "**Pause:** über die Steuerleiste oder das Menüleisten-Symbol. Alle Spuren bleiben synchron.",
                "Die schwebende **Kamera-Vorschau** lässt sich während der Aufnahme frei verschieben.",
            ]),
            .heading("Starten und Stoppen"),
            .keys([("⌘⇧2", "Aufnahme starten / stoppen – von überall"), ("●-Symbol in der Menüleiste", "Stoppen und bearbeiten")]),
            .text("Der Griff zum Stopp-Knopf am Ende wird automatisch weggeschnitten."),
            .heading("Steuerleiste und Menüleiste"),
            .bullets([
                "Die **Steuerleiste** (Schalter auf der Startseite oder Menü „Fenster“) schwebt über allen Fenstern: Quelle, Mikrofon, Kamera, Systemton, Screenshot und Aufnehmen; während der Aufnahme Zeit, Pause, Stopp und Verwerfen. Sie wird nie mit aufgenommen.",
                "**In der Menüleiste anzeigen** legt ein Symbol oben rechts an – damit startest du Aufnahmen und Screenshots auch bei geschlossenem Fenster.",
                "**Beim Anmelden starten** öffnet Erklärbär mit dem Mac, dann nur mit dem Menüleisten-Symbol.",
            ]),
            .tip("Absturzsicher: Erklärbär sichert die Aufnahme laufend. Stürzt der Mac oder die App ab, ist die Aufnahme beim nächsten Start als Projekt „… (wiederhergestellt)“ wieder da – höchstens ein bis zwei Sekunden fehlen."),
        ])

    // MARK: Neues Projekt

    static let newProject = HelpTopic(
        id: "newproject", title: "Eigenes Material", icon: "plus.rectangle.on.rectangle", color: .indigo,
        summary: "Videos schneiden, die nicht mit Erklärbär aufgenommen wurden.",
        blocks: [
            .text("Über **Neues Projekt** auf der Startseite (oder **Ablage › Neues Projekt …**) nutzt du den Editor auch für eigenes Material."),
            .heading("Aus eigenem Video"),
            .steps([
                "**Neues Projekt › Aus eigenem Video …** wählen – oder eine Videodatei einfach auf die Projektliste ziehen.",
                "Das Video wird zur Hauptspur. Sein Ton zählt als Mikrofon: Stimme verbessern, Untertitel, Pausen und Füllwörter entfernen funktionieren wie bei einer Aufnahme.",
                "Das Bild füllt das Format ohne Rahmen. Hochkant gefilmte Handyvideos werden richtig gedreht und bekommen das Format 9:16.",
            ]),
            .heading("Leeres Projekt"),
            .steps([
                "**Neues Projekt › Leeres Projekt** und das Format wählen (16:9, 9:16, 1:1 oder 4:3).",
                "Du startest mit einer schwarzen Fläche. Clips ziehst du auf die Video-Spur oder fügst sie über **Hinzufügen › Videoclip einfügen …** ein – sie reihen sich lückenlos aneinander. Auf einen Clip gezogen, landet der neue dahinter.",
                "Bilder, Videos als Bild im Bild, Texte und Musik legst du wie gewohnt darüber.",
            ]),
            .note("Die schwarze Fläche um die Clips herum wird automatisch abgeschnitten, solange nichts darauf liegt. Für Titel auf Schwarz ziehst du sie mit den Trimm-Griffen am Anfang oder Ende der Video-Spur wieder auf."),
        ])

    // MARK: Editor

    static let editor = HelpTopic(
        id: "editor", title: "Der Editor im Überblick", icon: "rectangle.3.group", color: .blue,
        summary: "Vorschau, Werkzeugleiste, Timeline und Inspektor – und wie man etwas auswählt.",
        blocks: [
            .heading("Aufbau"),
            .bullets([
                "**Vorschau** (oben): das fertige Video, genau so, wie es exportiert wird.",
                "**Werkzeugleiste** (darunter): links Widerrufen, Wiederholen, **Teilen** und Löschen; in der Mitte Abspielen und die Zeit des fertigen Videos; rechts **Einsprechen**, **Hinzufügen**, Einrasten und die Tastenkürzel-Übersicht.",
                "**Timeline** (unten): die Spuren Video, Kamera, Zoom, Cursor, Masken, Markierung, Text, Medien und die Tonspuren. Den Griff zwischen Vorschau und Timeline ziehen, um die Timeline größer oder kleiner zu machen.",
                "**Inspektor** (rechts): ohne Auswahl die Seiten **Stil, Kamera, Cursor, Zoom, Audio, Text, Medien, Skript**; mit Auswahl nur die Einstellungen des gewählten Elements.",
                "**Fensterleiste** (ganz oben): zurück zu den Aufnahmen, **Befehle** (⌘K), **Einfach**-Modus, **KI**, **Aufpolieren** und **Exportieren**.",
            ]),
            .heading("Auswählen"),
            .bullets([
                "Ein Klick auf ein Element in der Timeline wählt es aus – es bekommt einen **gelben Rahmen**, und rechts erscheinen seine Einstellungen.",
                "Ein Klick **ins Vorschaubild** wählt aus, was dort zu sehen ist: Kamerablase, Texte, Bilder, Videos, Markierungen, Masken, Untertitel oder Logo.",
                "Ein Klick auf einen **Spurnamen** links wählt die ganze Spur und zeigt ihre Einstellungen.",
                "Ein Klick daneben oder **Esc** hebt die Auswahl auf.",
            ]),
            .heading("Im Vorschaubild bearbeiten"),
            .text("Ausgewählte Masken, Rahmen, Spotlights, Bilder, Videos und Texte haben im Vorschaubild Griffe: innen ziehen verschiebt, an den Ecken ziehen ändert die Größe. Pfeile haben einen Anfang, eine Spitze und die Linie zum Verschieben. Die Griffe erscheinen nur, solange das Element zu sehen ist – deshalb springt der Abspielkopf beim Auswählen automatisch in seinen Bereich."),
            .heading("Timeline bedienen"),
            .bullets([
                "Klick oder Ziehen in der Zeitskala setzt den **Abspielkopf**.",
                "Zoomen: Regler unten links, **⌘+ / ⌘−**, **⇧Z** zeigt alles; mit **⌥ + Scrollrad** oder zwei Fingern auf dem Trackpad um den Mauszeiger herum.",
                "Gezoomt seitlich wischen oder die Übersichtsleiste unten ziehen.",
                "Ein Klick in eine **leere Spur** zeigt einen Geisterblock, wo ein neues Element landet (Zoom, Maske, Bauchbinde, Cursor-Bereich).",
                "**Einrasten** (N): Kanten rasten am Abspielkopf und an anderen Elementen ein (gelbe Hilfslinie).",
            ]),
            .tip("**⌘K** öffnet die Befehlspalette: einfach lostippen, was du tun möchtest (z. B. „Untertitel“ oder „Zoom“)."),
            .text("Der **Einfach**-Modus blendet leere Spuren für Masken, Markierungen und Cursor aus – sie erscheinen wieder, sobald du sie benutzt."),
        ])

    // MARK: Schneiden

    static let cutting = HelpTopic(
        id: "cutting", title: "Schneiden", icon: "scissors", color: .orange,
        summary: "Teilen, entfernen, kürzen, Übergänge, Tempo und Standbilder.",
        blocks: [
            .heading("Einen Teil herausschneiden"),
            .steps([
                "Den Abspielkopf an den Anfang der Stelle setzen und **S** drücken (oder **Teilen** in der Werkzeugleiste).",
                "Am Ende der Stelle nochmal **S** drücken.",
                "Den Teil dazwischen in der Video-Spur anklicken und **⌫** drücken.",
            ]),
            .text("Entfernte Bereiche werden beim Abspielen und im Export übersprungen. In allen Spuren sind sie schraffiert, Teilungen erscheinen als gestrichelte Linie. Einen entfernten Bereich anklicken und **⌫** drücken stellt ihn wieder her."),
            .note("Alles, was an der Aufnahme hängt – Ton, Texte, Masken, Markierungen, Overlays –, bleibt an seiner Stelle verankert und wandert beim Schneiden mit."),
            .heading("Anfang und Ende kürzen"),
            .text("Die gelben Griffe am Anfang und Ende der Video-Spur ziehen – oder **Hinzufügen › Anfang hierher kürzen / Ende hierher kürzen** am Abspielkopf."),
            .heading("Nur eine Tonspur schneiden"),
            .text("Den Namen der Tonspur anklicken (die Spur ist dann gelb umrandet) und **S** drücken: Die Spur wird am Abspielkopf in Bereiche geteilt, die eine eigene Lautstärke bekommen können – 0 % ist stumm. Das Spur-Menü (…) bietet außerdem „Ab Abspielkopf stummschalten“ und „Ab Abspielkopf leiser“."),
            .heading("Übergänge"),
            .bullets([
                "Einen Schnitt auswählen und die runden Griffe oben vom Schnitt wegziehen – oder den Regler im Inspektor benutzen. Die Teile davor und danach werden übereinandergeschoben und blenden weich über.",
                "Stile: **Überblenden**, **Über Schwarz** oder **Schieben**.",
                "**Ein- und Ausblenden** des ganzen Videos aus und nach Schwarz: Inspektor › Stil.",
            ]),
            .heading("Tempo und Standbild"),
            .bullets([
                "**Geschwindigkeit:** einen Teil anklicken und im Inspektor 0,25× bis 8× wählen. Der Ton behält seine Tonhöhe; in der Timeline zeigt ein Hasen- oder Schildkröten-Symbol das Tempo.",
                "**Standbild** (⌥F): hält das letzte Bild des ausgewählten Teils (sonst am Abspielkopf) an – Zeit zum Erklären. Die Länge änderst du an der rechten Kante des gestreiften Blocks.",
            ]),
            .tip("Automatisch geschnittene Stellen (Füllwörter, Pausen, Schnitte aus dem Transkript) sind **orange** und beschriftet. Wie du sie prüfst und zurücknimmst, steht unter **Ton**."),
        ])

    // MARK: Zoom und Cursor

    static let zoomCursor = HelpTopic(
        id: "zoom", title: "Zoom & Cursor", icon: "plus.magnifyingglass", color: .purple,
        summary: "Automatische Zooms, eigene Zoom-Bereiche und Effekte für den Mauszeiger.",
        blocks: [
            .heading("Zooms"),
            .bullets([
                "**Auto-Zoom:** Erklärbär legt nach der Aufnahme Zooms auf deine Klicks – mit einer ruhigen Kamerafahrt, die an den Rändern weich abbremst. **Auto-Zoom neu** (Inspektor › Zoom) erzeugt sie noch einmal.",
                "Eigene Zooms: in die leere Zoom-Spur klicken oder **Hinzufügen › Zoom**.",
                "Zoom-Blöcke lassen sich verschieben und an den Kanten verlängern; die Stärke stellst du im Inspektor ein (für alle neuen Zooms: **Standard-Stärke**).",
                "**Bewegungsunschärfe** (Inspektor › Zoom) lässt Kamerafahrt und Cursor natürlicher wirken.",
            ]),
            .heading("Cursor"),
            .bullets([
                "Inspektor › Cursor: anzeigen, Größe, Glättung, **Klick-Effekt** und **Bei Stillstand ausblenden**.",
                "**Hervorhebung im ganzen Video:** **Leuchtkreis**, **Spotlight** (der Rest wird dunkler) oder **Lupe** (vergrößert den Bereich um den Zeiger).",
                "**Cursor-Spur:** Effekte nur für einen Zeitraum. In die Cursor-Spur klicken legt einen Bereich an; Kanten ziehen ändert die Länge, Effekt und Größe stehen im Inspektor.",
            ]),
            .tip("Masken und Markierungen zoomen automatisch mit – sie bleiben im Bild immer an derselben Stelle."),
        ])

    // MARK: Kamera

    static let camera = HelpTopic(
        id: "camera", title: "Kamera", icon: "web.camera", color: .cyan,
        summary: "Kamerablase, Formen, freigestellte Person und Kamera-Layouts.",
        blocks: [
            .bullets([
                "**Form:** Kreis, abgerundet, Rechteck oder **Freigestellt** – die Person ohne Hintergrund, auf der Unterkante stehend (Apples Personen-Erkennung).",
                "**Größe, Spiegeln, Schatten** im Inspektor › Kamera.",
                "**Position:** die Kamerablase im Vorschaubild ziehen oder eine Ecke wählen.",
            ]),
            .heading("Kamera-Layouts je Abschnitt"),
            .text("In der Kamera-Spur legst du fest, wie die Kamera in einem Abschnitt erscheint: **Normal**, **Groß**, **Nur Kamera**, **Nebeneinander** (Aufnahme links bzw. oben, Kamera daneben) oder **Aus**. Ein Klick in die Kamera-Spur legt einen Abschnitt an, die Übergänge sind weich."),
            .note("Im Hochformat (9:16) steht die Aufnahme oben und die Kamera groß darunter – das passt Erklärbär beim Formatwechsel automatisch an."),
        ])

    // MARK: Texte, Bilder, Videos

    static let textsMedia = HelpTopic(
        id: "media", title: "Texte, Bilder & Videos", icon: "textformat", color: .teal,
        summary: "Bauchbinden, Titelkarten, Designs, Bilder, Logo und eigene Videos.",
        blocks: [
            .heading("Texte"),
            .bullets([
                "**Bauchbinde:** in die Text-Spur klicken oder **Hinzufügen › Bauchbinde**. Titel und Unterzeile im Inspektor eingeben, die Position im Vorschaubild ziehen oder über das 3×3-Raster wählen.",
                "**Titelkarte:** **Hinzufügen › Titelkarte** – über dem Video, als **Vorspann** vor oder als **Abspann** nach der Aufnahme. Vorspann und Abspann lassen sich in der Timeline über die Aufnahme ziehen: dann blenden sie über.",
                "**Designs:** zwölf Vorlagen (Akzentbalken, Glas, Etikett, Terminal …) und ein Design-Editor für Schrift, Farben, Box, Ecken und Schatten. „Auf alle Texte anwenden“ vereinheitlicht alles; eigene Designs lassen sich sichern.",
                "In eine Bauchbinde kann ein **Bild oder Logo**.",
            ]),
            .heading("Bilder und Videos"),
            .bullets([
                "**Drag & Drop** aus dem Finder: auf die Medien-Spur oder ins Vorschaubild = darüberlegen; auf die Video-Spur = in die Aufnahme einfügen (die Aufnahme wartet so lange); auf eine Tonspur = Hintergrundmusik.",
                "Bilder bekommen auf Wunsch einen **Rahmen** (Pur, Abgerundet, Rahmen, Foto, Kreis) und Schatten.",
                "**Video als Bild im Bild:** mit eigenem Ton, Länge an den Kanten ändern, mit **S** teilen.",
                "**Logo:** Inspektor › Medien – erscheint dauerhaft in einer Ecke.",
            ]),
            .tip("Ein Klick auf ein Bild oder einen Text im Vorschaubild öffnet sofort seine Einstellungen."),
            .heading("Kapitelmarken"),
            .text("**M** setzt am Abspielkopf eine Kapitelmarke (Fähnchen in der Zeitskala, ziehbar). Die Liste im Text-Tab prüft die YouTube-Regeln und kopiert die Kapitel für die Videobeschreibung; beim Export entsteht zusätzlich eine `….kapitel.txt`."),
        ])

    // MARK: Markierungen und Masken

    static let markings = HelpTopic(
        id: "markings", title: "Markierungen & Masken", icon: "arrow.up.right", color: .red,
        summary: "Pfeile, Rahmen, Spotlight, verpixelte Bereiche und sensible Daten.",
        blocks: [
            .heading("Markierungen"),
            .bullets([
                "**Hinzufügen › Markierung:** Pfeil, Rahmen oder **Spotlight** (dunkelt alles andere ab; Form eckig, abgerundet oder rund).",
                "Im Vorschaubild verschieben und an den Ecken ziehen; Farbe und Stärke im Inspektor.",
                "Auch auf eingefügten Videoclips möglich: eine Markierung, die im Clip beginnt, gehört zu ihm.",
            ]),
            .heading("Masken"),
            .text("Masken **verpixeln** oder **weichzeichnen** einen Bereich, z. B. Passwörter oder Namen. In die Masken-Spur klicken oder **Hinzufügen › Maske**, dann im Vorschaubild verschieben und skalieren. Masken zoomen mit."),
            .heading("Sensible Daten automatisch finden"),
            .text("**Hinzufügen › Sensible Daten verpixeln …** durchsucht die Aufnahme nach E-Mail-Adressen, Telefonnummern, IBANs, Kartennummern, API-Schlüsseln und Gesichtern und legt Masken für genau die Zeit an, in der sie zu sehen sind. Vor dem Übernehmen kannst du einzelne Funde abwählen."),
            .note("Für die Erkennung nutzt Erklärbär die Text- und Bilderkennung von macOS. Meldet sie, dass sie gerade nicht verfügbar ist, hilft meist ein Neustart des Macs."),
        ])

    // MARK: Ton

    static let sound = HelpTopic(
        id: "sound", title: "Ton", icon: "waveform", color: .green,
        summary: "Stimme verbessern, Atem, Pausen, Füllwörter, Musik, Voice-over und Lautstärke.",
        blocks: [
            .heading("Tonspuren und Mischpult"),
            .bullets([
                "Mikrofon, Systemton, Voice-over und Musik haben eigene Spuren mit Wellenform. Das Lautsprecher-Symbol im Spurkopf schaltet eine Spur stumm.",
                "Inspektor › Audio › **Mischpult:** Lautstärke je Spur. **Pegel angleichen** misst jede Spur und bringt Sprache nach vorne, Systemton und Musik darunter.",
                "**Gesamtlautstärke beim Export:** bringt das fertige Video auf −14, −16 oder −19 LUFS, ohne zu übersteuern.",
            ]),
            .heading("Stimme verbessern"),
            .bullets([
                "Entfernt Rauschen und gleicht die Lautstärke an – für Mikrofon und Voice-over.",
                "**Stärke (sofort hörbar):** stufenlos zwischen Original und verbesserter Stimme.",
                "**Eigene Stärke für einen Bereich:** Mikrofonspur anklicken, mit **S** einen Bereich abtrennen, ihn auswählen und im Inspektor die eigene Stärke einstellen.",
            ]),
            .heading("Atemgeräusche"),
            .text("**Atemgeräusche dämpfen** findet hörbare Atemzüge (nie auf erkannten Wörtern). Jeder Atemzug wird ein eigener Bereich **„Atem“** in der Mikrofonspur: anhören, Dämpfung pro Stelle ändern oder mit ⌫ entfernen. Empfindlichkeit und Stärke stellst du im Audio-Tab ein."),
            .heading("Pausen und Füllwörter"),
            .text("Im Skript-Tab entfernt **Pausen entfernen** stille Stellen (Mindestlänge und Empfindlichkeit einstellbar) und **Füllwörter** Wörter wie „äh“ und „ähm“ sowie doppelte Wörter. Die Schnitte blenden den Ton weich über, damit nichts abgehackt klingt."),
            .heading("Automatische Änderungen prüfen"),
            .steps([
                "Im Skript- oder Audio-Tab zeigt **Automatische Änderungen** die Anzahl der Füllwörter, Pausen, Transkript-Schnitte und Atem-Bereiche.",
                "**Prüfen** springt von Stelle zu Stelle und spielt sie ab.",
                "Eine einzelne Stelle mit **⌫** zurücknehmen – oder eine ganze Kategorie mit einem Klick.",
            ]),
            .heading("Musik und Voice-over"),
            .bullets([
                "**Hintergrundmusik:** Audio-Tab oder **Hinzufügen › Hintergrundmusik …** (oder eine Audiodatei auf eine Tonspur ziehen). Sie läuft über Schnitte hinweg, wiederholt sich, blendet ein und aus und wird unter Sprache automatisch leiser.",
                "**Einsprechen:** zählt 3-2-1 herunter, spielt das Video ab dem Abspielkopf ab und nimmt dein Mikrofon auf; die Leertaste stoppt. Der Originalton wird darunter abgesenkt.",
                "Voice-over-Clips lassen sich verschieben und kürzen; übereinandergeschoben blenden sie ineinander über.",
                "**Sprachaufnahme (Audiodatei) …** fügt eine eigene Audiodatei als Erzählung ein.",
            ]),
            .note("**Lautsprecher-Echo:** Mit eingebautem Mikrofon und Systemaudio landet der Lautsprecherton im Mikrofon. Erklärbär rechnet dieses Echo heraus (abschaltbar im Audio-Tab). Mit Kopfhörern entsteht es gar nicht erst."),
        ])

    // MARK: Untertitel

    static let captions = HelpTopic(
        id: "captions", title: "Untertitel & Transkript", icon: "captions.bubble", color: .indigo,
        summary: "Untertitel erzeugen, gestalten, übersetzen und das Video über den Text schneiden.",
        blocks: [
            .heading("Untertitel erzeugen"),
            .steps([
                "Inspektor › Text › Untertitel: Sprache wählen und **Erzeugen** klicken. Die Spracherkennung läuft direkt auf dem Mac (Deutsch, Englisch, Französisch, Spanisch, Italienisch).",
                "Als Quelle das Mikrofon, das Voice-over bzw. eine eigene Audiodatei oder alles Hörbare wählen.",
                "Texte lassen sich danach einzeln korrigieren.",
            ]),
            .heading("Stil"),
            .bullets([
                "Vorlagen: Klassisch, Karaoke, TikTok, Wort für Wort, Minimal, Hell.",
                "Anzeige als ganze Zeile, Zeile mit hervorgehobenem Wort, Wortgruppen oder Wort für Wort.",
                "Schrift, Farben, Hintergrund, Kontur, Großbuchstaben und Position – die Position auch direkt im Vorschaubild ziehen.",
            ]),
            .heading("Übersetzen und exportieren"),
            .text("**Untertitel übersetzen** nutzt Apple Übersetzen auf dem Mac; fehlende Sprachen lädt macOS nach Rückfrage. Mit **Als SRT exportieren …** entsteht eine Untertiteldatei für YouTube & Co.; im Video selbst erscheinen die Untertitel im gewählten Stil."),
            .heading("Schneiden über den Text"),
            .text("Im **Skript**-Tab steht das Transkript: Wörter anklicken, mit ⇧-Klick erweitern und mit **⌫** herausschneiden. Durchgestrichene Wörter lassen sich wiederherstellen."),
        ])

    // MARK: Assistenten

    static let assistants = HelpTopic(
        id: "assistants", title: "Assistenten & KI", icon: "wand.and.stars", color: .pink,
        summary: "Automatisch aufpolieren, KI-Vorschläge, Text sprechen und Anleitungen aus Klicks.",
        blocks: [
            .heading("Automatisch aufpolieren"),
            .text("Der Zauberstab **Aufpolieren** in der Fensterleiste (nach jeder Aufnahme auch als Start-Assistent „Was möchtest du erstellen?“) erledigt auf einen Schlag: Stimme verbessern und Atem dämpfen, Untertitel, Füllwörter und Pausen entfernen, Zooms auf Klicks und Pegel angleichen. Jeder Schritt lässt sich mit ⌘Z einzeln zurücknehmen."),
            .heading("KI-Vorschläge"),
            .text("**KI** (✨) schlägt aus dem Transkript Kapitel, drei Titel, eine Beschreibung, Schlagwörter und Ideen für Kurzclips vor. Du wählst, wer antwortet:"),
            .bullets([
                "**Apple Intelligence** – direkt auf dem Mac, ohne Internet (macOS 26).",
                "**Claude** – mit eigenem API-Schlüssel; er bleibt im Schlüsselbund des Macs.",
                "**Beliebige KI-App** – Erklärbär kopiert eine fertige Anfrage in die Zwischenablage. In der KI-App einfügen, die Antwort kopieren und zurück in Erklärbär einfügen.",
            ]),
            .text("Aus einem Kurzclip-Vorschlag entsteht mit einem Klick ein eigenes Hochformat-Projekt. **Für YouTube vorbereiten** kopiert Titel, Beschreibung, Kapitel und Schlagwörter und öffnet YouTube Studio."),
            .heading("Weitere Helfer"),
            .bullets([
                "**Text sprechen lassen …** (Hinzufügen): eine Mac-Stimme liest deinen Text als Voice-over ab dem Abspielkopf.",
                "**Anleitung aus Klicks …** (Hinzufügen): Jeder Klick wird ein Schritt mit Bild und Nummer, die Erklärung kommt aus den Untertiteln. Bearbeiten und als PDF, Markdown oder Text sichern.",
                "**Sensible Daten verpixeln …** – siehe **Markierungen & Masken**.",
            ]),
        ])

    // MARK: Stil und Formate

    static let style = HelpTopic(
        id: "style", title: "Stil & Formate", icon: "paintpalette", color: .orange,
        summary: "Hintergrund, Rahmen, Formate für YouTube und Reels, Farbkorrektur und Vorlagen.",
        blocks: [
            .bullets([
                "**Hintergrund:** Verläufe, einfarbig, eigenes Bild oder das Schreibtischbild.",
                "**Rahmen:** Abstand, Ecken und Schatten um die Aufnahme.",
                "**Formate:** 16:9, 9:16, 1:1, 4:3 oder Original. Jedes Format merkt sich sein eigenes Layout (Abstand, Höhe der Aufnahme, Kamera, Untertitel-Position). **Layout zurücksetzen** stellt den Vorschlag wieder her.",
                "**Farbkorrektur:** Belichtung, Kontrast, Sättigung, Wärme, Lebendigkeit und Vorlagen (Lebendig, Warm, Kühl, Schwarzweiß …) – getrennt für Bildschirm, Kamera und Videos.",
                "**Vorlagen:** Stil übernehmen oder als eigenen Stil sichern (Hintergrund, Rahmen, Cursor, Kamera, Blenden, Logo, Export) und als Standard für neue Aufnahmen festlegen.",
            ]),
        ])

    // MARK: Export

    static let export = HelpTopic(
        id: "export", title: "Exportieren", icon: "square.and.arrow.up", color: .blue,
        summary: "Das fertige Video als MP4 oder GIF sichern.",
        blocks: [
            .steps([
                "**Exportieren** oben rechts klicken oder **⌘E** drücken.",
                "Eine Vorlage wählen: YouTube (1080p, 60 fps), YouTube 4K, Hochformat (Shorts, Reels, TikTok), Quadratisch (Instagram, LinkedIn), Klein (720p, zum Verschicken), animiertes GIF – oder eigene Einstellungen (H.264/HEVC, 720p bis 4K, 30/60 fps).",
                "**Exportieren …** klicken und den Speicherort wählen. Ist das Video fertig, zeigt **Im Finder zeigen** die Datei.",
            ]),
            .bullets([
                "Kapitelmarken landen zusätzlich als `….kapitel.txt` neben dem Video.",
                "Mit **Gesamtlautstärke beim Export** (Audio-Tab) bekommt das Video die richtige Lautheit für YouTube & Co.",
                "Vorschau und Export nutzen denselben Renderer – was du siehst, ist was du bekommst.",
            ]),
        ])

    // MARK: Screenshots

    static let screenshots = HelpTopic(
        id: "screenshots", title: "Screenshots", icon: "camera.viewfinder", color: .mint,
        summary: "Bildschirmfotos aufnehmen und mit Pfeilen, Text und Markierungen versehen.",
        blocks: [
            .heading("Aufnehmen"),
            .bullets([
                "**⌘⇧1** – einen Bereich aufziehen, von überall.",
                "**Fenster** oder **ganzer Bildschirm** über das Screenshot-Menü: auf der Startseite, im Menü **Ablage › Screenshot**, im Menüleisten-Symbol oder am Pfeil des Screenshot-Knopfs der Steuerleiste.",
                "**Bild bearbeiten …** öffnet ein vorhandenes Bild im Screenshot-Editor.",
            ]),
            .heading("Bearbeiten"),
            .keys([("V", "Auswählen"), ("A", "Pfeil"), ("R", "Rahmen"), ("O", "Ellipse"), ("H", "Marker"), ("T", "Text"),
                   ("N", "Nummer"), ("B", "Weichzeichnen"), ("P", "Verpixeln"), ("C", "Zuschneiden"),
                   ("⇧ beim Ziehen", "Quadrat / 45°"), ("⌘C", "Kopieren"), ("⌘S", "Sichern")]),
            .text("Dazu ein Hintergrund mit Abstand, Ecken und Schatten. Das fertige Bild lässt sich auch direkt aus dem Fenster in andere Apps ziehen."),
        ])

    // MARK: Projekte

    static let projects = HelpTopic(
        id: "projects", title: "Projekte & Dateien", icon: "folder", color: .gray,
        summary: "Wo deine Aufnahmen liegen und was darin steckt.",
        blocks: [
            .text("Alle Projekte liegen in **~/Filme/Erklärbär**. **Im Finder** auf der Startseite öffnet den Ordner. Rechtsklick auf ein Projekt: Öffnen, Im Finder zeigen oder in den Papierkorb."),
            .heading("Inhalt eines Projekts"),
            .bullets([
                "`screen.mov` – die Bildschirmaufnahme mit Ton (bei eigenen Videos `screen.<endung>`)",
                "`camera.mov` – das Kamerabild (falls aufgenommen)",
                "`edit.json` – alle Bearbeitungen; die Aufnahme selbst wird nie verändert",
                "`media/` – eingefügte Bilder, Videos und Audiodateien, `voiceover/` – eingesprochene Voice-overs",
                "zwischengespeicherte Dateien wie `mic-clean.caf` oder `mic-voice-….caf` – sie werden bei Bedarf neu berechnet",
            ]),
            .tip("Ein Projekt sichern oder weitergeben: den ganzen `.screenkast`-Ordner kopieren."),
        ])

    // MARK: Tastenkürzel

    static let shortcuts = HelpTopic(
        id: "shortcuts", title: "Tastenkürzel", icon: "keyboard", color: .brown,
        summary: "Alle Kürzel auf einen Blick.",
        blocks: [
            .heading("Überall"),
            .keys([("⌘⇧2", "Aufnahme starten / stoppen"), ("⌘⇧1", "Screenshot eines Bereichs"), ("⌘?", "Erklärbär-Hilfe")]),
            .heading("Abspielen"),
            .keys([("Leertaste", "Abspielen / Pause"), ("← / →", "Ein Bild zurück / vor"), ("⇧← / ⇧→", "Eine Sekunde zurück / vor"),
                   ("Pos1 / Ende", "Zum Anfang / zum Ende")]),
            .heading("Bearbeiten"),
            .keys([("S  oder  ⌘B", "Am Abspielkopf teilen"), ("⌫", "Auswahl löschen / Teil entfernen / wiederherstellen"),
                   ("⌥F", "Standbild"), ("M", "Kapitelmarke"), ("⌘Z / ⇧⌘Z", "Widerrufen / Wiederholen"), ("Esc", "Auswahl aufheben"),
                   ("N", "Einrasten an / aus"), ("⌘K", "Befehlspalette")]),
            .heading("Timeline"),
            .keys([("⌘+ / ⌘−", "Hinein- / Herauszoomen"), ("⇧Z", "Alles zeigen"),
                   ("⌥ + Scrollen, Zwei-Finger-Zoom", "Zoomen um den Mauszeiger"), ("Seitlich wischen", "Verschieben")]),
            .heading("Export"),
            .keys([("⌘E", "Exportieren")]),
        ])

    // MARK: Probleme

    static let troubleshooting = HelpTopic(
        id: "troubleshooting", title: "Probleme lösen", icon: "lifepreserver", color: .yellow,
        summary: "Wenn etwas nicht klappt.",
        blocks: [
            .heading("Erklärbär lässt sich nicht öffnen"),
            .text("macOS meldet, dass die App nicht überprüft werden kann: **Systemeinstellungen › Datenschutz & Sicherheit** öffnen und unten bei „Erklärbär“ auf **Dennoch öffnen** klicken. Das ist nur einmal nötig."),
            .heading("Die Aufnahme bleibt schwarz oder startet nicht"),
            .bullets([
                "In **Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- und Systemaudioaufnahme** muss Erklärbär eingeschaltet sein.",
                "Nach dem Erteilen der Berechtigung Erklärbär **neu starten** – macOS übernimmt sie erst dann.",
                "**Quellen aktualisieren** (Pfeil unten auf der Startseite) liest Bildschirme, Fenster, Mikrofone und Kameras neu ein.",
            ]),
            .heading("Kein Ton oder keine Kamera"),
            .text("Unter **Datenschutz & Sicherheit › Mikrofon** bzw. **› Kamera** prüfen, ob Erklärbär erlaubt ist. Für Tastenkürzel braucht es **› Bedienungshilfen**."),
            .heading("Screenshot fehlgeschlagen"),
            .text("Der Bildschirmaufnahme-Dienst von macOS scheitert manchmal kurz. Erklärbär versucht es automatisch mehrmals; klappt es trotzdem nicht, einfach noch einmal auslösen. Tritt der Fehler immer wieder auf, hilft ein Neustart des Macs."),
            .heading("Text- oder Bilderkennung nicht verfügbar"),
            .text("Sensible Daten, Anleitung aus Klicks und die freigestellte Kamera nutzen die Erkennung von macOS. Ist sie gerade nicht verfügbar, hilft meist ein Neustart des Macs."),
            .heading("Es klingt abgehackt"),
            .text("Im Skript- oder Audio-Tab unter **Automatische Änderungen** die geschnittenen Stellen prüfen und einzelne mit ⌫ zurücknehmen; die **Stärke** der Stimmverbesserung lässt sich stufenlos verringern."),
            .heading("Echo oder Hall in der Stimme"),
            .text("Mit Lautsprechern und eingebautem Mikrofon landet der Systemton im Mikrofon. **Lautsprecher-Echo entfernen** (Audio-Tab) rechnet es heraus – noch besser sind Kopfhörer."),
            .heading("Alle Berechtigungen zurücksetzen"),
            .text("Im Terminal: `tccutil reset All local.screenkast.app` – danach fragt macOS beim nächsten Start alles neu ab."),
        ])

    // MARK: Über

    static let about = HelpTopic(
        id: "about", title: "Über Erklärbär", icon: "info.circle", color: .gray,
        summary: "Version, Lizenz und Kontakt.",
        blocks: [
            .text("Erklärbär ist eine native Mac-App (Swift/SwiftUI) – alles läuft auf deinem Mac, nur die optionale Claude-Schnittstelle nutzt das Internet."),
            .text("**Lizenz:** CC BY-NC 4.0 – Lernsachen.blog ([lernsachen.blog](https://lernsachen.blog)). Du darfst Erklärbär kopieren, weitergeben und verändern, solange du Lernsachen.blog als Urheber nennst, auf die Lizenz verweist und es nicht kommerziell nutzt. Die Videos, die du damit erstellst, gehören dir."),
            .text("Quellcode und neue Versionen: [github.com/Majort0m0/Erklaerbaer](https://github.com/Majort0m0/Erklaerbaer)"),
            .text("Voraussetzungen: Mac mit Apple-Chip, macOS 15 oder neuer; Untertitel, Apple Intelligence und einige Erkennungsfunktionen ab macOS 26."),
        ])
}

// MARK: - Markdown

extension HelpContent {
    /// The whole help as one Markdown document (ANLEITUNG.md in the repository).
    static var markdown: String {
        var out = "# Erklärbär-Hilfe\n\nDiese Anleitung steckt auch in der App: Menü **Hilfe › Erklärbär-Hilfe** (⌘?).\n\n"
        out += "## Inhalt\n\n" + topics.map { "- [\($0.title)](#\(anchor($0.title)))" }.joined(separator: "\n") + "\n"
        for topic in topics {
            out += "\n## \(topic.title)\n\n*\(topic.summary)*\n"
            for block in topic.blocks {
                switch block {
                case .text(let s): out += "\n\(s)\n"
                case .heading(let s): out += "\n### \(s)\n"
                case .bullets(let a): out += "\n" + a.map { "- \($0)" }.joined(separator: "\n") + "\n"
                case .steps(let a): out += "\n" + a.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n") + "\n"
                case .tip(let s): out += "\n> 💡 **Tipp:** \(s)\n"
                case .note(let s): out += "\n> ℹ️ \(s)\n"
                case .keys(let k):
                    out += "\n| Taste | Funktion |\n|---|---|\n" + k.map { "| \($0.0) | \($0.1) |" }.joined(separator: "\n") + "\n"
                }
            }
        }
        return out
    }

    /// GitHub's heading anchor.
    private static func anchor(_ title: String) -> String {
        title.lowercased().map { $0 == " " ? "-" : $0 }.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .map(String.init).joined()
    }
}
