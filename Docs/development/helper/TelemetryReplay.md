# Telemetry Replay Helper

## Zweck
`replay-telemetry-log.ps1` spielt eine CSV-Telemetrie-Datei Zeile für Zeile nach `RADIO/sensors.json` aus, damit der ETHOS-Simulator laufende Live-Sensorupdates erhält.

## Dateien
| Datei | Zweck |
|---|---|
| `Docs/development/helper/replay-telemetry-log.ps1` | Replay-Script |
| `Docs/development/helper/DemoTelemetry.csv` | Demo-Log (EdgeTX-Format, jederzeit ersetzbar) |
| `RADIO/sensors.json` | Ausgabe — liest die ETHOS-Extension live |

## Standardverhalten

Ohne Parameter startet das Script sofort mit sinnvollen Defaults:

- **Log**: `DemoTelemetry.csv` im gleichen Ordner wie das Script
- **Ziel**: `RADIO/sensors.json` im Repository-Root (wird automatisch gefunden, egal aus welchem Verzeichnis PowerShell gestartet wurde)
- **Geschwindigkeit**: Echtzeit (`-Speed 1`)
- **Timing**: wird automatisch aus den CSV-Zeitstempeln berechnet

## Terminalausgabe

Beim Start zeigt das Script den Header und danach eine laufende Fortschrittszeile:

```
Replay source : ...\DemoTelemetry.csv
Streaming to  : ...\RADIO\sensors.json
Rows          : 1234
Speed         : 1x
Format        : EdgeTX
ESC sensor    : False
Log rate      : ~2 Hz (median dt 500 ms)

Row 42/1234 (3%)  lat=51.36459 lon=11.93512 alt=43.0m hdg=316.5° sats=12
```

Die Fortschrittszeile aktualisiert sich in-place und zeigt Prozentwert, Position, Höhe, Heading und Satellitenzahl.

## Beispiele

Aus dem Workspace-Root oder dem Scriptordner:

```powershell
# Echtzeit-Replay mit Demo-Log (empfohlen für Simulator-Tests)
.\Docs\development\helper\replay-telemetry-log.ps1 -Speed 1 -Loop

# Eigener Log, doppelte Geschwindigkeit
.\Docs\development\helper\replay-telemetry-log.ps1 -LogPath ".\Docs\development\helper\MeinFlug.csv" -Speed 2 -Loop

# EdgeTX-Log aus .vscode, 5-fache Geschwindigkeit
.\Docs\development\helper\replay-telemetry-log.ps1 -LogPath ".\vscode\MeinFlug.csv" -Speed 5

# Mit ESC-Sensor (sinnvoll für Multirotor-Logs)
.\Docs\development\helper\replay-telemetry-log.ps1 -Speed 1 -Loop -IncludeEsc
```

## Parameter

| Parameter | Default | Beschreibung |
|---|---|---|
| `-LogPath` | `DemoTelemetry.csv` | Eingabe-CSV |
| `-SensorsPath` | `RADIO/sensors.json` | Ziel-JSON; relative Pfade werden gegen den Repo-Root aufgelöst |
| `-Speed` | `1.0` | Replay-Geschwindigkeit (`1` = Echtzeit, `2` = doppelt, usw.) |
| `-Loop` | — | Nach dem letzten Frame wieder von vorne starten |
| `-Format` | `auto` | `auto` / `edgetx` / `generic` — erkennt das Format automatisch aus den CSV-Headern |
| `-IncludeEsc` | — | Optionalen ESC-Sensor mit RPM/Spannung/Strom hinzufügen |

## Eigenen Log verwenden

1. CSV in `Docs/development/helper/` ablegen (oder beliebigen Pfad mit `-LogPath` angeben)
2. Format entweder automatisch erkennen lassen oder mit `-Format edgetx`/`-Format generic` erzwingen

**EdgeTX-Format** (wird automatisch erkannt):
- Pflichtfelder: `Date`, `Time`, `GPS`, `1RSS(dB)`, `RxBt(V)`, `Ptch(rad)`, `Roll(rad)`
- Timing: aus `Date`+`Time` berechnet

**Generic-Format**:
- Pflichtfeld: `timestamp_ms` (Unix-Millisekunden)
- GPS: `lat`, `lon`, `alt_m`, `speed_mps`, `course_deg`, `sats`

## Technische Details

- **Timing**: Das Script liest die echten Zeitstempel aus der CSV und wartet zwischen zwei Zeilen genau `delta / Speed` Millisekunden. Es gibt keinen festen Takt — das Timing folgt dem Log.
- **Schreiben**: Atomarer Schreibvorgang über temporäre Datei + `File.Replace`, damit die Extension nie ein halb-geschriebenes JSON liest.
- **Encoding**: UTF-8 ohne BOM, damit `JSON.parse()` in der ETHOS-Extension fehlerfrei parst.
- **Projektpfad**: Das Script findet den Repository-Root unabhängig vom aktuellen Arbeitsverzeichnis anhand der Ordner `RADIO/` und `Docs/`.

## Voraussetzungen

- ETHOS Simulator läuft (Extension `bsongis.ethos`)
- VS Code Developer: Reload Window nach Extension-Patches
- PowerShell 5.1 (Windows) oder pwsh