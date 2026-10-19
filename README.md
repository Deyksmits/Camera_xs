# 🚗 AutoCam Suite - Slimme Beveiliging & Dashcam voor iPhone XS (TrollStore)

Deze repository bevat **twee volwaardige, gespecialiseerde iOS apps** ontworpen om een iPhone XS optimaal te benutten met TrollStore:

1. 🏎️ **SmartDash**: Standalone 30 FPS Dual-Cam Dashcam met Flitsmeister & Waze cockpit dashboard, 0-100 km/u sprintmeter, voorruit HUD spiegelmodus en flitserradar.
2. 🛡️ **AutoCam**: 100% pure parkeerbewakingscamera met extreme accubesparing (3 FPS op batterij, OLED pitch-black), geavanceerd nachtzicht en Telegram notificaties.

---

## 🏎️ SmartDash - Dual-Cam Dashcam & Cockpit HUD (`SmartDash.ipa`)

Speciaal ontwikkeld voor tijdens het autorijden. Geen afleidend camerabeeld op het scherm, maar een hypermodern automotive dashboard in de stijl van Flitsmeister, Waze en Google Maps:

- 🧭 **Centrale Digitale Snelheidsmeter**: In landscape modus staat de snelheid prominent en haarscherp exact in het midden van het scherm, zonder overbodige "gps-speed" labels. Ondersteund door een vloeiende dynamische gauge bar.
- 🚨 **Flitsmeister-Stijl Flitser Notificaties (Links)**:
  - Offline database met alle bekende vaste flitspalen en trajectcontroles in Nederland (A1, A2, A4, A10, A12, A13, A16, A20, A58, provinciale wegen, stadsflitsers).
  - Authentiek Nederlands verkeersbord voor max. snelheid, camera-type badge, locatieaanduiding en dynamische aftelbalk in meters.
  - Slimme snelheidscontrole met visuele waarschuwing wanneer je te snel rijdt voor de flitser.
- ⚡ **Intelligente Acceleratie Mijlpaal-Meting (Links)**:
  - Meet automatisch snelle optrekacties vanuit stilstand naar het afgeronde tiental (bijvoorbeeld 0 naar 78 km/u -> berekent de exacte tijd van 0 naar 70 km/u).
  - Wordt direct getoond als een strakke notificatiekaart aan de linkerzijde en opgeslagen in het compacte scorebord.
  - Toptijd 0-100 km/u wordt bewaard als Persoonlijk Record (PR).
- 🎯 **G-Kracht Meter & Compacte Opnametimer (Rechts)**:
  - Live crosshair telemetrie dial (30 Hz) met laterale en longitudinale G-krachten en automatische noodvergrendeling (> 2.4G).
  - Compacte opnamestatus met knipperende REC-indicator, 30 FPS Dual-Cam badge en 1-klik noodknop (`🔒`).
- ⚙️ **Overzichtelijk Instellingenblad**: Alle extra functies (zoals HUD voorruit projectie, noodclips, rittengalerij, flitserafstand en telemetrie reset) zijn netjes weggestopt in een handig instellingentab.
- 🪞 **Voorruit HUD Spiegel Modus**: Tik op de `🪞 HUD` knop en leg je iPhone plat op je dashboard onder je voorruit voor een holografische reflectie.
- 📹 **Standaard 30 FPS Dual-Cam Opname**: Filmt gelijktijdig met de wegcamera (1080p @ 30 FPS) én de selfie/cabinecamera (720p @ 30 FPS) via `AVCaptureMultiCamSession` met directe `moov`-atom afsluiting.
- 🔁 **Rolling Loop Buffer**: Continu opnemen in 3-minuten segmenten met automatische opslagrecycling tot 10 GB.
- 📁 **In-App Galerij & Player**: Bekijk video thumbnails, wissel tussen weg- en cabinebeeld, of exporteer naar Foto's / AirDrop.
- ⚡ **Auto-Start bij Contact**: Start automatisch met opnemen zodra de iPhone op de autolader wordt aangesloten.

---

## 🛡️ AutoCam - Pure Parkeerbewaking (`AutoCam.ipa`)

Speciaal ontwikkeld voor wanneer de auto geparkeerd staat. 100% gefocust op surveillance met de look en feel van een professioneel camerasysteem:

- 🏢 **Professionele CCTV Surveillance UI**: Geen standaard prototype look, maar een industriële bewakingsinterface (geïnspireerd op UniFi Protect, Verkada en Axis).
- 🎯 **Tactische Viewfinder Reticles**: Subtiele optische hoekmarkeringen en cameraindicator (`CAM-01 • SURVEILLANCE`).
- ⏱️ **Live CCTV Timecode**: Realtime monospaced tijdstempel en live sensortelemetrie in de OSD-balk.
- 📐 **Tactische Guard Zone**: Blueprint-stijl perimeter met [P1]...[P4] doelwit-reticles en technische statusbadge.
- 🛡️ **Tactische Bewakingsconsole**: Prominente status- en inschakelschakelaar met een geordende, compacte 5-knoppenbalk.
- 🔋 **Extreme Accubesparing (Zonder Stroom)**: Schakelt automatisch naar 3 FPS detectiemodus met 100% OLED pitch-black scherm binnen 4 seconden na ontkoppelen van de lader.
- 🌙 **Geavanceerd Nachtzicht**: Ruisloze monochrome modus met verhoogde schaduwdetails.
- 📲 **Telegram Notificaties & Web Remote**: 1 video per bewegingsincident met persoons-/autoclassificatie.

---

## 🚀 Installatie via TrollStore

1. Ga op je iPhone XS (in Safari) naar de **[Releases](https://github.com/Deyksmits/Camera_xs/releases)** van deze repository.
2. Download `SmartDash.ipa` en/of `AutoCam.ipa`.
3. Open het gedownloade bestand in **TrollStore** en tik op **Install**.
4. De apps staan nu direct op je beginscherm en kunnen naast elkaar gebruikt worden!
