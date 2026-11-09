# Erklärbär

*(früher Screenkast – intern heißen Quellordner, Programmdatei, Bundle-ID und Projektformat weiterhin so)*

Native macOS-App (Swift/SwiftUI, macOS 15+, Untertitel ab macOS 26) für Bildschirmaufnahmen mit automatischen Zooms, geglättetem Cursor, Kamerablase und schönem Hintergrund.

**Anleitung:** [ANLEITUNG.md](ANLEITUNG.md) – dieselbe ausführliche Hilfe steckt auch in der App (Menü **Hilfe › Erklärbär-Hilfe**, ⌘?).

## Installieren

1. Unter [Releases](../../releases) die Datei `Erklaerbaer-<Version>-macOS.zip` laden und entpacken.
2. `Erklärbär.app` in den Ordner **Programme** ziehen.
3. Beim ersten Öffnen meldet macOS, dass die App nicht überprüft werden kann (sie ist nicht bei Apple notariell beglaubigt). Dann **Systemeinstellungen › Datenschutz & Sicherheit** öffnen und unten bei „Erklärbär“ auf **Dennoch öffnen** klicken. Alternativ im Terminal: `xattr -dr com.apple.quarantine /Applications/Erklärbär.app`
4. Bei der ersten Aufnahme die Berechtigung **Bildschirm- und Systemaudioaufnahme** erteilen und Erklärbär einmal neu starten.

Voraussetzungen: Mac mit Apple-Chip (M1 oder neuer), macOS 15 oder neuer. Untertitel, Apple Intelligence und einige Erkennungsfunktionen brauchen macOS 26.

## Bauen & Starten

```bash
./scripts/build-app.sh                # → ~/Applications/Erklärbär.app (Release, signiert mit „Screenkast Dev“, sonst ad hoc)
open ~/Applications/Erklärbär.app
```

Es genügen die Command Line Tools, Xcode wird nicht gebraucht. Das Skript baut in `~/Library/Caches/Screenkast/build` (änderbar mit `SCREENKAST_BUILD_DIR`), signiert in einem temporären Ordner und installiert dann nach `~/Applications`. Grund: Der Projektordner liegt in iCloud-„Dokumente“. Dort hängt macOS neuen Bundles Finder-Metadaten an, die `codesign` ablehnt, und SwiftPM linkt manchmal nicht neu („disk I/O error“). Mit `SCREENKAST_APP_DIR=/anderer/ordner` lässt sich ein anderes Ziel wählen.

Bei der Bildschirmaufnahme fragt macOS nach der Berechtigung **Bildschirm- und Systemaudioaufnahme**, danach muss die App einmal neu gestartet werden. Kamera und Mikrofon fragen beim ersten Benutzen, Tastenkürzel brauchen **Bedienungshilfen**. Das Build-Skript signiert mit dem selbst erstellten Zertifikat „Screenkast Dev“ aus dem Anmelde-Schlüsselbund (falls vorhanden): dann bleiben die Freigaben über Neubauten erhalten. Ohne Zertifikat wird ad hoc signiert, und macOS fragt nach jedem Neubau erneut (`tccutil reset All local.screenkast.app` setzt alle Freigaben zurück).

### Werkzeuge für die Kommandozeile

```bash
swift build
.build/debug/Screenkast --selftest /tmp/sk-test                 # alle Selbsttests (synthetische Daten)
.build/debug/Screenkast --analyze <projekt.screenkast>          # Kamera-Ruckeln messen, Renderzeit
.build/debug/Screenkast --echo <projekt> <ausgabe.caf>          # Echo-Entfernung testen (Projekt bleibt unverändert)
.build/debug/Screenkast --export <projekt> <ausgabe.mp4>        # kompletter Export ohne Oberfläche
.build/debug/Screenkast --voice <projekt>                       # Stimme verbessern: Lautheit vorher/nachher (schreibt die bearbeiteten Dateien)
.build/debug/Screenkast --breaths <projekt> [<aus.caf>]         # Atemgeräusche im Mikrofon finden (mit Gegenprobe per Spracherkennung)
.build/debug/Screenkast --newproject <ordner> [video …]        # ein Video → Projekt daraus; keins/mehrere → leeres Projekt mit Clips
.build/debug/Screenkast --helpmarkdown ANLEITUNG.md             # Erklärbär-Hilfe als Markdown schreiben
.build/debug/Screenkast --hangtest /tmp/sk-hang                 # prüft den Hänger-Wächter
.build/debug/Screenkast --uisnapshot <projekt> <bild.png>       # Editor unsichtbar rendern (Layout prüfen)
SCREENKAST_SNAPSHOT="5 3.5 7" .build/debug/Screenkast --uisnapshot …  # dasselbe gezoomt: 5 s sichtbar ab 3,5 s, Abspielkopf bei 7 s
SCREENKAST_SELECT=tab:audio SCREENKAST_SNAPSHOT_SIZE=1000x660 …       # Inspektor-Seite (none, segment, tab:…) und Fenstergröße
```

Falls die App während einer Aufnahme hängt (Haupt-Thread länger als 4 s blockiert), schreibt ein Wächter einen Stack-Mitschnitt nach `~/Library/Logs/Screenkast/Haenger-*.txt`. Vor dem Sofort-Beenden etwa 10 Sekunden warten, damit der Bericht fertig wird.

Achtung: `swift build` meldet hier gelegentlich „Build complete“, ohne neu zu linken (Fehler „unable to attach DB“). Dann hilft `rm -rf .build`.

## Gestaltung

Ruhige Karten auf einer leicht abgesetzten Arbeitsfläche (Vorschau-Bühne, Timeline, Inspektor), Farben aus dem App-Symbol: Indigo/Violett als Akzent, das Gelb des Fokusrings für die Auswahl. Jede Spur hat eine eigene Farbe, die im Spurkopf (Symbolkachel) und in ihren Blöcken wiederkehrt. Alle Farben, Radien und Abstände stehen zentral in `App/Theme.swift`; hell und dunkel werden automatisch unterstützt.

## Funktionen

**Aufnahme**
- Bildschirm oder Fenster über ScreenCaptureKit (HEVC, 60 fps). Der Mauszeiger wird *nicht* mitgefilmt, er wird später gerendert.
- Mikrofon, **Systemaudio** (ohne Erklärbär selbst) und **Kamera** mit Live-Vorschau, alles synchron auf der Host-Uhr.
- **iPad und iPhone per Kabel**: Bildschirm und Ton des Geräts direkt aufnehmen (Quelle „iPad und iPhone am Kabel“), dazu auf Wunsch Mikrofon und Kamera des Macs.
- **Live für Meetings**: Programm-Fenster zum Teilen in Zoom, Teams oder Meet, Steuerfenster außerhalb des geteilten Bilds, Szenen (Webcam, Bildschirm, Fenster, iPad, mit verschiebbarer Webcam-Bubble), Rahmen wie Laptop oder Fernseher, Klick-Effekte, Mausspur, eingeblendete Tastenkürzel und Aufnahme nebenbei.
- **Meme-Board**: zehn Plätze für kurze Clips, Suche in frei lizenzierten GIFs oder eigene Dateien, auf Knopfdruck live oder im Editor.
- **Virtueller Hintergrund** für die Webcam, im Editor und live: Bild oder Grafik hinter der Person, ohne Greenscreen.
- **Nummerierte Schritte** und **Klicks hervorheben**: aus aufgezeichneten Klicks werden automatisch Rahmen, Pfeile, Finger oder Schritte.
- **Maske folgt dem Inhalt**, **Teleprompter** beim Einsprechen, **Vorlagen-Pakete** mit Vorspann, Abspann und Bauchbinden-Design.
- **Schnitt**: bis zu vier Medienspuren, Keyframes für Position, Größe, Deckkraft und Lautstärke, Rollen und Slip, Bibliothek im Projekt, Auswahl per Rahmen und alles rechts vom Abspielkopf.
- Cursor-Tracking mit 120 Hz mit den echten System-Cursorbildern, dazu Klicks und optional **Tastenkürzel**. Aufgezeichnet werden nur Kombinationen mit ⌘, ⌃ oder ⌥, normal getippter Text nie.
- **Pausieren und Fortsetzen**: Alle Spuren bleiben synchron.
- Start und Stopp von überall mit `⌘⇧2` oder über das ●-Symbol in der Menüleiste. Der Griff zum Stopp-Button wird automatisch weggeschnitten.
- Schwebende Kamera-Vorschau während der Aufnahme, frei verschiebbar. Sie wird selbst nicht mit aufgenommen.
- **Absturzsicher**: Video und Kamera werden in 1-Sekunden-Fragmenten geschrieben, Cursor und Aufnahmedaten alle 2 s gesichert. Nach einem Absturz oder Sofort-Beenden stellt Erklärbär die Aufnahme beim nächsten Start als Projekt „… (wiederhergestellt)“ wieder her (höchstens etwa 1–2 s gehen verloren).

**Aufnahme** (zusätzlich): **Bereich des Bildschirms** frei aufziehen, **Countdown 3-2-1**, **Sprechernotizen** als schwebendes Fenster mit Teleprompter – Countdown und Notizen werden nicht mit aufgenommen.
- **Fenster aus dem Stage Manager** und von anderen Schreibtischen sind wählbar („Weitere Fenster“); ein gewähltes Fenster wird beim Start nach vorne geholt (mit Bedienungshilfen-Freigabe genau dieses Fenster, sonst seine App).
- **Zweites Fenster** gleichzeitig aufnehmen: erscheint im Editor als Bild im Bild, läuft synchron mit der Aufnahme (Schnitte, Tempo), verschiebbar, mit S teilbar und so nur zeitweise sichtbar.
- **Menüleiste und Anmeldestart** (Startseite oder Einstellungen ⌘,): Symbol oben rechts für Aufnahme, Screenshot und Steuerleiste auch bei geschlossenem Fenster; Start beim Anmelden (dann ohne Fenster, nur in der Menüleiste).
- **Steuerleiste** auf dem Bildschirm (Startseite oder Menü „Fenster“): Quelle, Mikrofon, Kamera, Systemton, Screenshot, Aufnehmen; während der Aufnahme Zeit, Pause, Stopp, Verwerfen. Wird nie mit aufgenommen; der Weg zur Leiste beim Stoppen wird weggeschnitten.
- Fehlt die Bildschirm-Berechtigung, prüft die Startseite alle 1,5 s, ob sie erteilt wurde, und bietet dann „Erklärbär neu starten“ an.

**Neues Projekt ohne Aufnahme** (Startseite „Neues Projekt“, Menü „Ablage“, oder ein Video auf die Projektliste ziehen):
- **Aus eigenem Video**: Die Datei wird zur Hauptspur (auf APFS als Klon, ohne doppelten Speicher), ihr Ton zählt als Mikrofon – Stimme verbessern, Untertitel, Pausen und Füllwörter funktionieren wie bei einer Aufnahme. Das Bild füllt das Format ohne Rahmen; Hochkant-Handyvideos werden richtig gedreht und bekommen 9:16.
- **Leeres Projekt** (16:9, 9:16, 1:1, 4:3): eine schwarze Fläche von 10 s für Clips, Bilder und Texte. Eingefügte Clips reihen sich lückenlos aneinander (auf einen Clip gezogen: dahinter; umstellen per Maus); die schwarze Fläche drumherum wird automatisch abgeschnitten, solange nichts darauf liegt – die Trimm-Griffe ziehen sie für Titel auf Schwarz wieder auf.

**Erklärbär-Hilfe** (Menü „Hilfe“, ⌘?, Hilfe-Knöpfe auf der Startseite, im Editor und im Menüleisten-Symbol): ausführliche Anleitung in 19 Kapiteln mit Suche, von „Erste Schritte“ bis „Probleme lösen“.

**Screenshots** (`⌘⇧1` für einen Bereich, Menü „Ablage › Screenshot“, Startseite, Steuerleiste): Bereich, Fenster oder ganzer Bildschirm, danach ein eigener Editor mit Pfeil, Rahmen, Ellipse, Marker, Text, Nummern, Weichzeichnen, Verpixeln und Zuschneiden (Tasten V A R O H T N B P C, ⇧ für Quadrat/45°), Hintergrund mit Abstand, Ecken und Schatten, Widerrufen; Kopieren (⌘C), Sichern (⌘S), zum Herausziehen in andere Apps. Auch vorhandene Bilder lassen sich öffnen.

**Assistenten und KI** (alles Bordmittel des Macs, außer der optionalen Claude-Schnittstelle):
- **Automatisch aufpolieren** (Zauberstab in der Werkzeugleiste, nach jeder Aufnahme als Start-Assistent „Was möchtest du erstellen?“: YouTube-Tutorial, Kurzvideo, Produkt-Demo, Anleitung): Stimme verbessern und Atem dämpfen, Untertitel, Füllwörter und Pausen herausschneiden, Zooms, Pegel angleichen – jeder Schritt einzeln widerrufbar.
- **KI-Vorschläge** (✨): Kapitel, drei Titel, Beschreibung, Schlagwörter und Ideen für Kurzclips aus dem Transkript. Wahlweise **Apple Intelligence** auf dem Mac, **Claude** (eigener API-Schlüssel im Schlüsselbund, Modell `claude-opus-5-5` u. a.) oder **jede KI-App**: Prompt kopieren, Antwort zurück einfügen. Kurzclip → eigenes Hochformat-Projekt (APFS-Kopie, kein doppelter Speicher). „Für YouTube vorbereiten“ kopiert Titel, Beschreibung, Kapitel und Schlagwörter und öffnet YouTube Studio (direktes Hochladen bräuchte einen bei Google registrierten API-Zugang).
- **Untertitel übersetzen** (Apple Übersetzen auf dem Mac, fehlende Sprachen lädt macOS nach Rückfrage).
- **Text sprechen lassen**: Mac-Stimme als Voice-over ab dem Abspielkopf.
- **Anleitung aus der Aufnahme**: jeder Klick ein Schritt mit Bild und Nummer; was angeklickt wurde, erkennt die Texterkennung („Klicke auf „Speichern““), die Erklärung kommt aus den Untertiteln; bearbeitbar, Export als PDF, Markdown mit Bildern oder Text.
- **Sensible Daten verpixeln**: findet E-Mail-Adressen, Telefonnummern, IBANs (mit Prüfsumme), Kartennummern (Luhn), API-Schlüssel und Gesichter in der Aufnahme und legt Masken für die Zeit an, in der sie zu sehen sind.
- **Bedienung**: Befehlspalette **⌘K**, kleine Kontextleiste am ausgewählten Element im Vorschaubild, **Einfach-Modus** (leere Masken- und Markierungsspur ausgeblendet).

**Kamera und Cursor**: Kamera **freigestellt** (Person ohne Hintergrund, steht auf der Unterkante; Apples Personen-Erkennung), Kamera-Layout **Nebeneinander** (Bildschirm links bzw. oben, Kamera daneben). Cursor-Hervorhebung **Leuchtkreis, Spotlight oder Lupe**; **Soundeffekte** („Wusch“) bei Zooms und Übergängen.

**Editor** – aufgebaut wie gängige Schnittprogramme (Screen Studio, Cap, CapCut, Final Cut):
- **Oben** die Vorschau, **darunter die Steuerleiste** mit Zeitanzeige, Abspielen und „Hinzufügen“ (Titelkarten, Musik, Logo, Clips …). **Direkt über der Timeline die Symbolleiste** mit allen Schnitt- und Einfüge-Werkzeugen, jedes mit Tastenkürzel im Tooltip: Teilen, Löschen, Kopieren, Kürzen (Q/W), Standbild, Überblendung (⌘T), Tempo (⌥↑/⌥↓), Zoom (Z), Text (T), Maske (X), Pfeil (A), Rahmen (R), Spotlight (P), Bild (I), Video (O), Einsprechen (V), Einrasten (N), Zusammenkleben (G).
- **Rechts der Inspektor**: ohne Auswahl Seiten hinter Symbol-Reitern (Stil, Kamera, Cursor, Zoom, Audio, Text, Medien, Skript); ist etwas ausgewählt, zeigt er nur dessen Einstellungen mit Kopfzeile (Löschen, Esc schließt). Export-Einstellungen stehen im Export-Dialog (⌘E).
- **Klick ins Vorschaubild** wählt aus, was dort zu sehen ist (Kamerablase, Texte, Bilder, Videos, Markierungen, Masken, Untertitel, Logo) und öffnet seine Einstellungen; ein Klick daneben hebt die Auswahl auf. **Spurnamen** anklicken wählt die ganze Spur (Einstellungen rechts, Spur gelb umrandet). Ein Klick in eine leere Spur beendet erst eine Auswahl, bevor er etwas hinzufügt.
- **Auswahl** in der Timeline: gelber Rahmen mit Leuchten und Griffen an den Kanten. Ein ausgewähltes Element holt den Abspielkopf in seinen Bereich, damit seine Griffe im Vorschaubild passen.
- **Griffe im Vorschaubild** (Masken, Rahmen, Spotlight, Bilder, Videos): innen ziehen verschiebt, alle vier Ecken ändern die Größe; der Pfeil hat Anfang, Spitze und die Linie zum Verschieben. Sie erscheinen nur, solange das Element zu sehen ist.
- **Schneiden**: Abspielkopf setzen, **S** (oder ⌘B) teilt die Aufnahme, Teil anklicken, **⌫** entfernt ihn. Ist ein Voice-over-Clip ausgewählt, wird er geteilt. **⌘Z / ⇧⌘Z** widerrufen jeden Schritt (auch im Menü „Bearbeiten“).
- **Geschwindigkeit**: Teil anklicken, im Inspektor 0,25× bis 8× (Ton behält die Tonhöhe); die Timeline zeigt den Teil kürzer/länger mit Hasen- bzw. Schildkröten-Symbol.
- **Standbild** (⌥F): hält das letzte Bild des ausgewählten Teils (sonst am Abspielkopf) an – Zeit zum Erklären. Gestreifter Block in der Timeline, Länge an der rechten Kante ziehen. Cursor, Zoom und Ton stehen still; Voice-over und Bauchbinden können darüberlaufen.
- **Übergänge** an Schnitten: Überblenden, Über Schwarz oder Schieben (Schnitt auswählen). **Ein- und Ausblenden** des ganzen Videos aus/nach Schwarz mit Ton (Inspektor › Stil). Einen Teil **auf seinen Nachbarn schieben** erzeugt die Überblendung direkt in dieser Länge.
- **Zusammenkleben** (G, abschaltbar): Bilder, Videos, Voice-over und Musik haften an den Enden ihrer Nachbarn. Weiter geschoben überlappen sie und **blenden automatisch über** – bei Video auch den Ton, solange die Clips ungefähr an derselben Stelle im Bild liegen.
- **Skript** (Inspektor): **Pausen entfernen** (stille Stellen im Mikrofon, Mindestlänge, Rest und Empfindlichkeit einstellbar), **Transkript** – Wörter anklicken, ⇧-Klick erweitert, ⌫ schneidet sie heraus, durchgestrichene lassen sich wiederherstellen –, **Füllwörter** („äh“, „ähm“, doppelte Wörter) mit einem Klick entfernen.
- **Stimme verbessern** (Audio): Hochpass, sanfte spektrale Rauschunterdrückung, Lautheit nach ITU BS.1770 auf −14/−16/−19 LUFS, sanfter Limiter – für Mikrofon und Voice-over, als bearbeitete Kopie (Original bleibt). Die **Stärke** ist sofort hörbar regelbar (Mischung aus bearbeiteter und unbearbeiteter, gleich lauter Spur); ein Bereich der Mikrofonspur (Spur wählen, S) kann seine **eigene Stärke** bekommen.
- **Atemgeräusche dämpfen** (optional): rauschig, ohne Tonhöhe, leiser als die Sprache, nie auf erkannten Wörtern; Empfindlichkeit einstellbar. Jeder Atemzug wird ein eigener **Bereich „Atem“** in der Mikrofonspur – anhören, Dämpfung pro Stelle ändern oder mit ⌫ entfernen.
- **Automatische Änderungen prüfen** (Skript- und Audio-Tab): Füllwörter, Pausen, Transkript-Schnitte und Atem-Bereiche gezählt, „Prüfen“ springt von Stelle zu Stelle, jede Kategorie mit einem Klick zurücknehmen. Automatische Schnitte sind orange mit Kennzeichnung („äh“, „Pause“, „Text“) und blenden den Ton über 60 ms weich über, damit nichts abgehackt klingt. Ältere Projekte werden beim Öffnen nachträglich gekennzeichnet.
- **Clip-Timeline**: Die Timeline zeigt das fertige Video. Entfernte Teile verschwinden, die Lücke schließt sich (eine kleine Marke mit Schere holt sie zurück). Teile lassen sich **per Maus umstellen**, ihre Kanten kürzen sie mit Nachrücken. Vorschau und Export spielen dasselbe, ohne Sprünge.
- **Gekoppelt oder frei**: Kettensymbol im Spurkopf (Text, Medien, Voice-over) und Schalter je Clip. Gekoppelte Clips werden mitgeschnitten und wandern mit, freie bleiben an ihrer Stelle. Musik ist immer frei.
- **Übergänge an jeder Stelle**, an der sich zwei Teile treffen (Raute unten am Übergang), auch nach dem Umstellen und zwischen eingefügten Clips. **Mehrfachauswahl** mit ⇧-Klick: gemeinsam verschieben, kopieren, entfernen.
- **Musik als Clips** (S auf der Musikspur, weitere Titel per Drag & Drop), **Ton vom Video lösen**, Ein-/Ausblenden je Clip, **⌘C/⌘V** für Elemente, **J/K/L**, Spuren sperren (Rechtsklick auf den Spurkopf).
- **Cursor-Spur**: Cursor-Effekte (Leuchtkreis, Spotlight, Lupe, Ausblenden) nur für einen Zeitraum; Klick in die Spur legt einen Bereich an, Kanten ziehen, Effekt und Größe im Inspektor.
- **Hintergrundmusik** (Audio oder „Hinzufügen“): läuft in Ausgabezeit über Schnitte hinweg, Schleife, Ein-/Ausblenden, wird unter Sprache (Mikrofon, Voice-over) automatisch leiser; eigene Spur mit Wellenform.
- **Kamera-Layouts** pro Abschnitt (Kamera-Spur): Normal, Groß, Nur Kamera, Aus – mit weichen Übergängen.
- **Markierungen**: Pfeil, Rahmen, Spotlight (dunkelt alles andere ab; Form eckig, abgerundet oder rund/oval), zoomen mit der Aufnahme; im Vorschaubild verschieben und ziehen. Auch **auf eingefügten Videoclips**: eine Markierung, die im Clip beginnt, gehört zu ihm. Pfeil und Rahmen wirken **von Hand gezeichnet** und werden beim Einblenden **gezeichnet**, der Pfeil pulsiert danach leicht auf sein Ziel zu (beides abschaltbar). **Finger-Gesten** für iPad-Videos (F): Tippen, Doppeltippen, Halten, Ziehen, Wischen, Ziehen mit zwei Fingern, Pinch und Drehen, als Punkt oder als Finger.
- **Eigene Medien** (Medien-Tab und Medien-Spur): Bilder mit Rahmen (Pur, Abgerundet, Rahmen, Foto, Kreis) und Schatten, **Videos als Bild im Bild** über der Aufnahme (eigener Ton, Länge an den Kanten, S teilt) oder **in die Hauptspur eingefügt** (die Aufnahme wartet), **Logo** in einer Ecke. **Drag & Drop** aus dem Finder: auf die Video-Spur = einfügen, auf die Medien-Spur oder ins Vorschaubild = Overlay, auf eine Audiospur = Hintergrundmusik. Hochkant-Videos werden richtig gedreht.
- **Formate mit eigenem Layout**: 16:9, 9:16, 1:1 … merken sich je Format Abstand, Höhe der Aufnahme, Kamera und Untertitel-Position. Hochformat (Reels, Shorts, TikTok) beginnt mit der Aufnahme oben, der Kamera groß darunter und den Untertiteln dazwischen.
- **Untertitel-Stil**: Vorlagen (Klassisch, Karaoke, TikTok, Wort für Wort, Minimal, Hell), Anzeige als ganze Zeilen, Zeile mit hervorgehobenem Wort, Wortgruppen oder Wort für Wort (springen hinein), Schrift, Stärke, Farben, Hintergrund, Kontur, Großbuchstaben, Position (Regler oder im Vorschaubild ziehen). Untertitel lassen sich aus dem Mikrofon, aus Voice-over/**eigenen Audiodateien** oder aus allem Hörbaren erzeugen; eine Audiodatei kommt über „Hinzufügen“ oder per Drag & Drop auf die Voice-over-Spur.
- **Farbkorrektur** (Stil): Belichtung, Kontrast, Sättigung, Wärme, Lebendigkeit, Vorlagen (Lebendig, Warm, Kühl, Schwarzweiß …), getrennt für Bildschirm, Kamera und Videos.
- **Text-Designs**: zwölf Vorlagen (Akzentbalken, Glas, Etikett, Klassisch, Terminal …) und ein Design-Editor (Schrift, Stärke, Farben, Box, Akzentbalken, Ecken, Abstand, Schatten, Großbuchstaben); „Auf alle Texte anwenden“, eigene Designs sichern (für alle Projekte), neue Texte übernehmen das zuletzt gewählte Design. Bild oder Logo in der Bauchbinde bzw. über dem Titel.
- **Text-Animationen** je für Eingang und Ausgang: Erscheinen, Ohne, Einfliegen von links, rechts, unten oder oben, Ausrollen und Aufspringen.
- **Kapitelmarken** (M): Fähnchen in der Zeitskala, ziehbar; Liste im Text-Tab mit YouTube-Prüfung, Kopieren für die Beschreibung, beim Export als `….kapitel.txt` neben dem Video.
- **Vorlagen**: Stil übernehmen/sichern (Hintergrund, Rahmen, Cursor, Kamera, Blenden, Logo, Export), eingebaute Stile, Standard für neue Aufnahmen. **Export-Vorlagen**: YouTube 1080p/4K, Hochformat, Quadrat, Klein (HEVC), animiertes GIF.
- **Einrasten** (N): Kanten von Clips, Zooms, Masken, Texten, Schnitten und Trimm-Griffen sowie der Abspielkopf rasten an Abspielkopf, Teilungen und anderen Kanten ein (gelbe Hilfslinie).
- **Leere Spur anklicken** (Zoom, Masken, Text): ein Geisterblock zeigt, wo das neue Element landet.
- **Auto-Zoom** auf Klicks mit stetiger Kamerafahrt, die sich weich an den Rändern abbremst. Zoom-Bereiche lassen sich in der Timeline verschieben, in der Länge ändern und in der Stärke einstellen.
- **Bewegungsunschärfe** für Cursor und Kamera als echte Verschlusszeit-Simulation.
- Cursor geglättet, skalierbar, mit Klick-Ring; optional bei Stillstand ausblenden.
- **Szenen** statt eines Hintergrunds (Stil-Tab): Laptop auf dem Schreibtisch, Tablet auf dem Tisch, Fernseher, Theater, Kino, Bilderrahmen. Selbst gezeichnet, passend zu jedem Format; Position und Größe des Bildschirms und der Ausschnitt des Videos sind einstellbar (je Szene und Format).
- Hintergrund: Verläufe, Einfarbig, eigenes Bild oder Schreibtischbild. Dazu Abstand, Ecken und Schatten, Formate 16:9, 9:16, 1:1, 4:3, Original sowie 720p bis 4K.
- **Kamerablase**: Kreis, abgerundet oder Rechteck; Größe einstellbar, frei verschiebbar (im Vorschaubild ziehen) oder in einer Ecke; Spiegeln und Schatten.
- **Trimmen** und **entfernte Bereiche**: Rote Blöcke in der Timeline, die beim Abspielen übersprungen werden; anklicken und ⌫ stellt sie wieder her. **Überblendung** an einem Schnitt: Schnitt auswählen und die runden Griffe oben vom Schnitt wegziehen (oder Regler im Inspektor, Rechtsklick-Menü). Die Teile davor und danach werden übereinandergeschoben, Bild und Ton blenden weich über; Kurven auf beiden Seiten zeigen den Verlauf.
- **Masken**: Bereiche verpixeln oder weichzeichnen, im Vorschaubild verschieben und skalieren. Sie zoomen mit.
- **Audiospuren** in der Timeline: Mikrofon, Systemton und Voice-over mit Wellenform, einzeln stumm oder in der Lautstärke regelbar. Spurname anklicken wählt die **Spur** (Lautstärke, Stimme verbessern pro Spur, schneiden); **S** schneidet sie am Abspielkopf in **Bereiche mit eigener Lautstärke** (0 % = stumm). Jeder Voice-over-Clip hat eine eigene Lautstärke. **Mischpult** im Audio-Tab mit „Pegel angleichen“ (misst die Lautheit jeder Spur: Sprache vorne, Systemton und Musik darunter) und **Gesamtlautstärke beim Export** (−14/−16/−19 LUFS, ohne zu übersteuern; das Video wird dabei nicht neu kodiert). **Lautsprecher-Echo entfernen** (siehe unten); optionale **Klickgeräusche** (eigener, synthetischer Sound).
- **Voice-over**: „Einsprechen“ zählt 3-2-1 herunter, spielt das Video ab dem Abspielkopf ab und nimmt das Mikrofon auf. Übersprungene Schnitte teilen die Aufnahme in passende Clips. Clips lassen sich verschieben und kürzen; der Originalton wird darunter automatisch abgesenkt (einstellbar). Werden zwei Clips übereinandergeschoben, blenden sie über die Überlappung ineinander über (Equal-Power-Crossfade); die Clips stehen dann in zwei Reihen, jeder mit seiner Blendkurve.
- **Texte**: Bauchbinden/Textfelder (Titel + Unterzeile, vier Stile; Position über ein 3×3-Raster oder im Vorschaubild ziehen, rastet in der Mitte ein; die Textausrichtung ändert nur die Zeilen, die Box bleibt stehen) und Vollbild-**Titelkarten** – über dem Video, als **Vorspann** vor oder als **Abspann** nach der Aufnahme (verlängern das Video, Übergänge werden eingeblendet). Vorspann/Abspann in der Timeline über die Aufnahme ziehen → Überblendung mit der Aufnahme.
- **Timeline**: Klick oder Ziehen in der Zeitskala setzt den Abspielkopf, der rote Abspielkopf lässt sich auch an der Linie ziehen; Leertaste spielt, ←/→ ein Bild, ⇧←/→ eine Sekunde, Pos1/Ende. **Zoom**: Regler und Lupen unten links, ⌘+ / ⌘−, ⇧Z (alles zeigen), ⌥/⌘ + Scrollrad oder Zwei-Finger-Zoom auf dem Trackpad (um den Mauszeiger). Gezoomt: seitlich wischen, ⇧ + Scrollrad oder die Übersichtsleiste unten ziehen; beim Abspielen blättert die Timeline mit. Wellenformen sind auf die lauteste Stelle der Spur skaliert.
- **Timeline-Höhe** über den Griff oberhalb der Transportleiste ziehbar; Audiospuren wachsen mit, bei wenig Platz wird gescrollt.
- **Untertitel**: Spracherkennung direkt auf dem Mac (Deutsch, Englisch, Französisch, Spanisch, Italienisch), ausgewogene Zeilen, Texte bearbeitbar, **SRT-Export**.
- **Tastenkürzel-Einblendung** als Badge über den Untertiteln.
- **Export** als MP4 (H.264/HEVC, 720p–4K, 30/60 fps) über den Export-Dialog (⌘E). Vorschau und Export nutzen denselben Renderer.

### Lautsprecher-Echo

Mit eingebautem Mikrofon und Systemaudio landet der Lautsprecherton etwa 40 ms verzögert im Mikrofon. Zusammen mit dem direkt mitgeschnittenen Systemton klingt das wie ein Chorus. Erklärbär rechnet das Echo mit dem Systemton als Referenz heraus: ein lineares Echo-Filter (Least Squares, 85 ms), danach eine spektrale Unterdrückung des Rest-Echos. Bei einer echten Aufnahme ergab das 22 dB weniger Echo, die eigene Sprache blieb unverändert. Das Original bleibt erhalten (`mic-clean.caf` daneben), die Funktion ist abschaltbar. Mit Kopfhörern entsteht das Echo gar nicht erst.

### Projektordner

`~/Filme/Erklärbär/*.screenkast` (der Speicherort ist wählbar, auch Laufwerke und Freigaben; Projekte lassen sich per Rechtsklick verschieben) enthält (ein vorhandener Ordner `~/Filme/Screenkast` wird beim ersten Start umbenannt):
- `screen.mov`: Video mit getaggten Audiospuren „system“ und „mic“
- `camera.mov`: Kameravideo (optional)
- `recording.json`, `cursor.json`, `edit.json`, `cursors/*.png`
- `voiceover/*.m4a`: eingesprochene Voice-overs
- `media/*`: eingefügte Bilder, Videos und Audiodateien
- bei Projekten aus einem eigenen Video heißt die Hauptspur `screen.<endung>` (z. B. `screen.mp4`)
- zwischengespeichert: `mic-clean.caf` (echofreies Mikrofon), `echo.json`, `click.caf`
- nur während der Aufnahme: `recording-progress.json` (für die Wiederherstellung nach einem Absturz)

Ältere Projekte laden weiter, fehlende Einstellungen bekommen Standardwerte.

## Aufbau

| Datei | Aufgabe |
|---|---|
| `Recording/ScreenRecorder.swift` | SCStream ohne Cursor → AVAssetWriter (HEVC + AAC, getaggte Spuren) |
| `Recording/CameraRecorder.swift` | Webcam mit Vorschau, schreibt `camera.mov` auf der Host-Uhr |
| `Recording/CursorTracker.swift`, `KeyShortcuts.swift` | Cursor, Klicks, Tastenkürzel |
| `Recording/PauseGate.swift` | Gemeinsame Pausen für alle Spuren (Retiming) |
| `Recording/HotKey.swift`, `FloatingCameraPanel.swift` | Globales Kürzel, schwebende Kamera (eigenes Verschieben) |
| `App/HangWatchdog.swift` | Hänger-Wächter während der Aufnahme |
| `Recording/RecordingRecovery.swift` | Absturzsichere Aufnahme und Wiederherstellung |
| `Audio/VoiceOverRecorder.swift`, `Waveform.swift` | Voice-over-Aufnahme, Wellenformen |
| `Project/Overlays.swift`, `Render/TextRendering.swift` | Audiospuren, Voice-over-Clips, Texteinblendungen (Modell und Darstellung) |
| `Project/Motion.swift` | Feder-Glättung, Auto-Zoom |
| `Render/FrameRenderer.swift` | Core-Image-Komposition je Frame (Hintergrund, Masken, Zoom-Kamera, Bewegungsunschärfe, Cursor, Kamerablase, Tastenkürzel, Untertitel) |
| `Render/MediaBuilder.swift` | AVComposition aus behaltenen Teilen, eigener Compositor (Zeitumrechnung Komposition → Quelle), Audio-Mix |
| `Audio/EchoCanceller.swift`, `ClickSound.swift` | Echo-Entfernung (Accelerate), Klick-Sound |
| `Captions/Captions.swift` | Spracherkennung, Zeilenaufteilung, SRT, Text-Rendering |
| `Editor/*` | Vorschau, Timeline (Zoom, Schnitte, Überblendungen, Zooms, Masken), Inspektor, Export; `EditorKeyHandler` für Tastatur |

## Noch nicht enthalten

- Masken, die dem Inhalt automatisch folgen; bisher folgen Masken dem Zoom, aber nicht scrollendem Inhalt.
- Atem-Bereiche und eigene Stärke der Stimmverbesserung für Voice-over-Spuren (bisher nur Mikrofon).
- Bei der Fensteraufnahme wird ein Verschieben des Fensters während der Aufnahme nicht nachverfolgt.

## Lizenz

Erklärbär – Lizenz: [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/deed.de) Lernsachen.blog ([https://lernsachen.blog](https://lernsachen.blog))

Du darfst Erklärbär kopieren, weitergeben und verändern – auch in deiner Schule und im Kollegium –, solange du Lernsachen.blog als Urheber nennst, auf die Lizenz verweist und es nicht kommerziell nutzt. Die Videos, die du damit erstellst, gehören dir. Vollständiger Lizenztext: [LICENSE](LICENSE).

Enthaltene Bausteine: keine fremden Bibliotheken – nur Frameworks von macOS (SwiftUI, AVFoundation, ScreenCaptureKit, Vision, Speech, Translation, FoundationModels). Die optionale Claude-Schnittstelle spricht die Anthropic-API direkt per HTTPS an; der eigene API-Schlüssel bleibt im Schlüsselbund des Macs.
