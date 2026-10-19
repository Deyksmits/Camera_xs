# 🚗 AutoCam Suite - Slimme Beveiliging & Dashcam voor iPhone XS (TrollStore)

Deze repository bevat **twee volwaardige, gespecialiseerde iOS apps** ontworpen om een iPhone XS optimaal te benutten met TrollStore:

1. 🏎️ **SmartDash**: Standalone 30 FPS Dual-Cam Dashcam met Flitsmeister & Waze cockpit dashboard, 0-100 km/u sprintmeter, voorruit HUD spiegelmodus en flitserradar.
2. 🛡️ **AutoCam**: 100% pure parkeerbewakingscamera met extreme accubesparing (3 FPS op batterij, OLED pitch-black), geavanceerd nachtzicht en Telegram notificaties.

---

## 🏎️ SmartDash - Dual-Cam Dashcam & Cockpit HUD (`SmartDash.ipa`)

Speciaal ontwikkeld voor tijdens het autorijden. Geen afleidend camerabeeld op het scherm, maar een hypermodern automotive dashboard in de stijl van Flitsmeister, Waze en Google Maps:

- 🪞 **Voorruit HUD Spiegel Modus**: Tik op de `🪞 HUD` knop en leg je iPhone plat op je dashboard onder je voorruit. Het scherm spiegelt horizontaal en schakelt naar maximale helderheid, waardoor de reflectie in je autoruit als een echte holografische Head-Up Display recht voor je ogen zweeft!
- ⚡ **0 - 100 km/u Sprint Telemetrie**: Meet automatisch je acceleratie vanuit stilstand naar 100 km/u met milliseconde-precisie. Behaald binnen 12 seconden? Dan toont SmartDash direct een felicitatiebanner met je tijd en slaat het je Persoonlijk Record (PR) op!
- 🚨 **Live Flitser & Trajectcontrole Radar (Flitsmeister / Waze stijl)**:
  - Offline database met alle bekende vaste flitspalen en trajectcontroles in Nederland (A1, A2, A4, A10, A12, A13, A16, A20, A58, provinciale wegen, stadsflitsers).
  - Dynamische naderingskaart met aftelbalk in meters en dubbele waarschuwingstoon bij te hard rijden.
  - Automatische online synchronisatie via OpenStreetMap Overpass API.
- 📹 **Standaard 30 FPS Dual-Cam Opname**: Filmt gelijktijdig met de wegcamera (1080p @ 30 FPS) én de selfie/cabinecamera (720p @ 30 FPS) via `AVCaptureMultiCamSession`. Bestanden worden direct netjes afgesloten met de `moov`-atom aan het begin, zodat ze altijd direct afspelen in iOS Foto's en QuickTime.
- 🎯 **G-Kracht Meter**: Live crosshair accelerometer (30 Hz) en automatische noodvergrendeling bij een plotselinge noodstop of botsing (> 2.4G).
- 🔁 **Rolling Loop Buffer**: Continu opnemen in 3-minuten segmenten met automatische opslagrecycling tot 10 GB.
- 📁 **In-App Galerij & Player**: Bekijk video thumbnails, wissel tussen weg- en cabinebeeld, of exporteer naar Foto's / AirDrop.
- ⚡ **Auto-Start bij Contact**: Start automatisch met opnemen zodra de iPhone op de autolader wordt aangesloten.

---

## 🛡️ AutoCam - Pure Parkeerbewaking (`AutoCam.ipa`)

Speciaal ontwikkeld voor wanneer de auto geparkeerd staat. 100% gefocust op surveillance met maximale batterijduur:

- 🔋 **Extreme Accubesparing (Zonder Stroom)**: Schakelt automatisch naar 3 FPS detectiemodus met 100% OLED pitch-black scherm binnen 4 seconden na ontkoppelen van de lader.
- 🎯 **Interactieve Bewakingszone**: Stel een 4-punts polygoon in rond de auto.
- 🌙 **Geavanceerd Nachtzicht**: Ruisloze monochrome modus met verhoogde schaduwdetails.
- 📲 **Telegram Notificaties & Web Remote**: 1 video per bewegingsincident met persoons-/autoclassificatie.

---

## 🚀 Installatie via TrollStore

1. Ga op je iPhone XS (in Safari) naar de **[Releases](https://github.com/Deyksmits/Camera_xs/releases)** van deze repository.
2. Download `SmartDash.ipa` en/of `AutoCam.ipa`.
3. Open het gedownloade bestand in **TrollStore** en tik op **Install**.
4. De apps staan nu direct op je beginscherm en kunnen naast elkaar gebruikt worden!
